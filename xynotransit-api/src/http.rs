//! What every response and every log line has in common: a request id, safe headers, and an
//! error body that is always {"error": "plain words"}.

use std::{any::Any, time::Instant};

use axum::{
    extract::Request,
    http::{header, HeaderMap, HeaderName, HeaderValue, StatusCode},
    middleware::Next,
    response::{IntoResponse, Response},
};
use tower_http::{catch_panic::ResponseForPanic, set_header::SetResponseHeaderLayer};
use tracing::Instrument;
use uuid::Uuid;

use crate::error::ApiError;

pub const REQUEST_ID: HeaderName = HeaderName::from_static("x-request-id");

/// The id of the request being served, kept in the request extensions for handlers.
#[derive(Clone, Debug)]
pub struct RequestId(pub String);

/// A caller may send its own id (a proxy usually does). Accept only short plain ones,
/// anything else could be used to forge log lines.
fn clean_id(h: &HeaderMap) -> Option<String> {
    let v = h.get(&REQUEST_ID)?.to_str().ok()?;
    let ok = !v.is_empty()
        && v.len() <= 64
        && v.bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b'.'));
    ok.then(|| v.to_string())
}

/// Outermost layer: gives the request an id, answers with it, and writes ONE log line per request.
/// The query string is never logged (it carries event tickets). Health checks log at debug.
pub async fn request_context(mut req: Request, next: Next) -> Response {
    let id = clean_id(req.headers()).unwrap_or_else(|| Uuid::new_v4().simple().to_string());
    req.extensions_mut().insert(RequestId(id.clone()));
    let method = req.method().clone();
    let path = req.uri().path().to_string();
    let span = tracing::info_span!("request", request_id = %id);
    let start = Instant::now();
    let mut res = next.run(req).instrument(span.clone()).await;
    let ms = start.elapsed().as_millis() as u64;
    let status = res.status().as_u16();
    if let Ok(v) = HeaderValue::from_str(&id) {
        res.headers_mut().insert(REQUEST_ID, v);
    }
    let _guard = span.enter();
    if path == "/api/health" && status == 200 {
        tracing::debug!(%method, %path, status, ms, "request");
    } else if status >= 500 {
        tracing::error!(%method, %path, status, ms, "request");
    } else if status >= 400 {
        tracing::warn!(%method, %path, status, ms, "request");
    } else {
        tracing::info!(%method, %path, status, ms, "request");
    }
    res
}

fn plain_words(status: StatusCode) -> &'static str {
    match status {
        StatusCode::BAD_REQUEST | StatusCode::UNPROCESSABLE_ENTITY => "That request is not valid.",
        StatusCode::UNAUTHORIZED => "Please sign in.",
        StatusCode::FORBIDDEN => "You cannot do that.",
        StatusCode::NOT_FOUND => "Not found.",
        StatusCode::METHOD_NOT_ALLOWED => "That method is not allowed here.",
        StatusCode::REQUEST_TIMEOUT => "The request took too long. Try again.",
        StatusCode::PAYLOAD_TOO_LARGE => "That request is too large.",
        StatusCode::UNSUPPORTED_MEDIA_TYPE => "Send the request as JSON.",
        StatusCode::TOO_MANY_REQUESTS => "Too many requests. Try again later.",
        s if s.is_server_error() => "Something went wrong on our side. Try again in a moment.",
        _ => "That request could not be handled.",
    }
}

fn is_json(h: &HeaderMap) -> bool {
    h.get(header::CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .is_some_and(|v| v.starts_with("application/json"))
}

/// Any 4xx or 5xx that did not come from our own error type (a 405 from the router, a 408 from the
/// timeout, a 413 from the body limit, a bad query string) becomes the same JSON error.
pub async fn json_errors(req: Request, next: Next) -> Response {
    let res = next.run(req).await;
    let status = res.status();
    if (status.is_client_error() || status.is_server_error()) && !is_json(res.headers()) {
        let allow = res.headers().get(header::ALLOW).cloned();
        let mut out = (
            status,
            axum::Json(serde_json::json!({ "error": plain_words(status) })),
        )
            .into_response();
        if let Some(a) = allow {
            out.headers_mut().insert(header::ALLOW, a);
        }
        if status == StatusCode::TOO_MANY_REQUESTS {
            let wait = res
                .headers()
                .get(header::RETRY_AFTER)
                .cloned()
                .unwrap_or_else(|| header::HeaderValue::from_static("60"));
            out.headers_mut().insert(header::RETRY_AFTER, wait);
        }
        return out;
    }
    res
}

/// A panic in a handler becomes a 500 with the usual body; the panic text goes to the log only.
#[derive(Clone, Copy)]
pub struct PanicToJson;

impl ResponseForPanic for PanicToJson {
    type ResponseBody = axum::body::Body;

    fn response_for_panic(
        &mut self,
        err: Box<dyn Any + Send + 'static>,
    ) -> axum::http::Response<Self::ResponseBody> {
        let what = err
            .downcast_ref::<&str>()
            .map(|s| s.to_string())
            .or_else(|| err.downcast_ref::<String>().cloned())
            .unwrap_or_default();
        tracing::error!(panic = %what, "a handler panicked");
        ApiError::Internal.into_response()
    }
}

/// Headers that every API answer carries. The API only speaks JSON and event streams, so the page
/// policy is the strictest one, and nothing is cached by the browser or a proxy.
pub fn security_headers() -> [SetResponseHeaderLayer<HeaderValue>; 6] {
    let h = |name: &'static str, v: &'static str| {
        SetResponseHeaderLayer::overriding(
            HeaderName::from_static(name),
            HeaderValue::from_static(v),
        )
    };
    [
        h("x-content-type-options", "nosniff"),
        h("cache-control", "no-store"),
        h("referrer-policy", "no-referrer"),
        h("x-frame-options", "DENY"),
        h(
            "content-security-policy",
            "default-src 'none'; frame-ancestors 'none'",
        ),
        h("cross-origin-resource-policy", "same-origin"),
    ]
}
