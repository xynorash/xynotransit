//! One error type for every handler. The body is always {"error": "plain words"}.

use axum::{
    extract::{FromRequest, Request},
    http::StatusCode,
    response::{IntoResponse, Response},
    Json,
};
use serde::de::DeserializeOwned;
use serde_json::json;

#[derive(Debug)]
pub enum ApiError {
    BadRequest(String),
    Unauthorized(String),
    Forbidden(String),
    NotFound(String),
    Conflict(String),
    /// Message and the seconds until the caller may try again (sent as `Retry-After`).
    TooManyRequests(String, u64),
    TooLarge,
    MethodNotAllowed,
    UnsupportedMedia,
    Unavailable,
    /// Too many password hashes at once; try again in a moment.
    Busy,
    Internal,
}

impl ApiError {
    pub fn bad(msg: impl Into<String>) -> Self {
        ApiError::BadRequest(msg.into())
    }
    pub fn unauthorized(msg: impl Into<String>) -> Self {
        ApiError::Unauthorized(msg.into())
    }
    pub fn forbidden(msg: impl Into<String>) -> Self {
        ApiError::Forbidden(msg.into())
    }
    pub fn not_found(msg: impl Into<String>) -> Self {
        ApiError::NotFound(msg.into())
    }
}

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        let mut retry_after = None;
        let (status, msg) = match self {
            ApiError::BadRequest(m) => (StatusCode::BAD_REQUEST, m),
            ApiError::Unauthorized(m) => (StatusCode::UNAUTHORIZED, m),
            ApiError::Forbidden(m) => (StatusCode::FORBIDDEN, m),
            ApiError::NotFound(m) => (StatusCode::NOT_FOUND, m),
            ApiError::Conflict(m) => (StatusCode::CONFLICT, m),
            ApiError::TooManyRequests(m, secs) => {
                retry_after = Some(secs.max(1));
                (StatusCode::TOO_MANY_REQUESTS, m)
            }
            ApiError::TooLarge => (
                StatusCode::PAYLOAD_TOO_LARGE,
                "That request is too large.".to_string(),
            ),
            ApiError::MethodNotAllowed => (
                StatusCode::METHOD_NOT_ALLOWED,
                "That method is not allowed here.".to_string(),
            ),
            ApiError::UnsupportedMedia => (
                StatusCode::UNSUPPORTED_MEDIA_TYPE,
                "Send the request as JSON.".to_string(),
            ),
            ApiError::Unavailable => (
                StatusCode::SERVICE_UNAVAILABLE,
                "The service is not ready. Try again in a moment.".to_string(),
            ),
            ApiError::Busy => (
                StatusCode::SERVICE_UNAVAILABLE,
                crate::loginlimit::msg::BUSY.to_string(),
            ),
            ApiError::Internal => (
                StatusCode::INTERNAL_SERVER_ERROR,
                "Something went wrong on our side. Try again in a moment.".to_string(),
            ),
        };
        let mut res = (status, Json(json!({ "error": msg }))).into_response();
        if let Some(secs) = retry_after {
            res.headers_mut()
                .insert(axum::http::header::RETRY_AFTER, secs.into());
        }
        res
    }
}

/// Database details go to the log, never to the caller.
impl From<sqlx::Error> for ApiError {
    fn from(e: sqlx::Error) -> Self {
        tracing::error!(error = %e, "database error");
        ApiError::Internal
    }
}

impl From<crate::hashing::HashError> for ApiError {
    fn from(e: crate::hashing::HashError) -> Self {
        match e {
            crate::hashing::HashError::Busy => ApiError::Busy,
            crate::hashing::HashError::Failed => {
                tracing::error!("password hashing failed");
                ApiError::Internal
            }
        }
    }
}

/// JSON body extractor that answers with our error shape.
pub struct ApiJson<T>(pub T);

impl<S, T> FromRequest<S> for ApiJson<T>
where
    S: Send + Sync,
    T: DeserializeOwned,
{
    type Rejection = ApiError;

    async fn from_request(req: Request, state: &S) -> Result<Self, ApiError> {
        match Json::<T>::from_request(req, state).await {
            Ok(Json(v)) => Ok(ApiJson(v)),
            Err(rej) if rej.status() == StatusCode::PAYLOAD_TOO_LARGE => Err(ApiError::TooLarge),
            Err(rej) if rej.status() == StatusCode::UNSUPPORTED_MEDIA_TYPE => {
                Err(ApiError::UnsupportedMedia)
            }
            Err(_) => Err(ApiError::bad("That request is not valid.")),
        }
    }
}

/// Parse an id from the URL; anything that is not a UUID cannot exist.
pub fn parse_id(s: &str) -> Result<uuid::Uuid, ApiError> {
    uuid::Uuid::parse_str(s).map_err(|_| ApiError::not_found("Not found."))
}
