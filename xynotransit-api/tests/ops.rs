//! Operations: request ids, logs, headers, error bodies, health, shutdown.

mod common;

use std::{
    io::Write,
    sync::{Arc, Mutex},
    time::Duration,
};

use axum::{
    body::Body,
    http::{Request, StatusCode},
};
use common::*;
use http_body_util::BodyExt;
use serde_json::{json, Value};
use tower::ServiceExt;

async fn full(
    app: &TestApp,
    method: &str,
    uri: &str,
    token: Option<&str>,
    ctype: Option<&str>,
    body: Vec<u8>,
) -> (StatusCode, axum::http::HeaderMap, Vec<u8>) {
    let mut b = Request::builder().method(method).uri(uri);
    if let Some(t) = token {
        b = b.header("authorization", format!("Bearer {t}"));
    }
    if let Some(c) = ctype {
        b = b.header("content-type", c);
    }
    let res = app
        .router
        .clone()
        .oneshot(b.body(Body::from(body)).unwrap())
        .await
        .unwrap();
    let (status, headers) = (res.status(), res.headers().clone());
    let bytes = res.into_body().collect().await.unwrap().to_bytes().to_vec();
    (status, headers, bytes)
}

fn error_of(bytes: &[u8]) -> String {
    let v: Value = serde_json::from_slice(bytes)
        .unwrap_or_else(|_| panic!("body is not JSON: {:?}", String::from_utf8_lossy(bytes)));
    assert_eq!(v.as_object().unwrap().len(), 1, "{v}");
    v["error"].as_str().expect("error is a string").to_string()
}

#[tokio::test]
async fn every_response_has_a_request_id_and_safe_headers() {
    let app = TestApp::new().await;
    for (m, u) in [
        ("GET", "/api/health"),
        ("GET", "/api/me"),
        ("GET", "/api/nope"),
        ("GET", "/elsewhere"),
        ("DELETE", "/api/health"),
    ] {
        let (_, h, _) = full(&app, m, u, None, None, vec![]).await;
        let id = h["x-request-id"].to_str().unwrap();
        assert_eq!(id.len(), 32, "{u}");
        assert_eq!(h["x-content-type-options"], "nosniff", "{u}");
        assert_eq!(h["cache-control"], "no-store", "{u}");
        assert_eq!(h["referrer-policy"], "no-referrer", "{u}");
        assert_eq!(h["x-frame-options"], "DENY", "{u}");
        assert!(h["content-security-policy"]
            .to_str()
            .unwrap()
            .contains("default-src 'none'"));
    }
    // Two requests, two ids.
    let (_, a, _) = full(&app, "GET", "/api/health", None, None, vec![]).await;
    let (_, b, _) = full(&app, "GET", "/api/health", None, None, vec![]).await;
    assert_ne!(a["x-request-id"], b["x-request-id"]);
}

#[tokio::test]
async fn a_caller_id_is_kept_only_when_it_is_plain() {
    let app = TestApp::new().await;
    for (sent, kept) in [
        ("trace-123_a.b", true),
        ("", false),
        ("has space", false),
        ("new\u{e9}", false),
        (&"x".repeat(65), false),
    ] {
        let Ok(value) = axum::http::HeaderValue::from_str(sent) else {
            continue;
        };
        let req = Request::builder()
            .uri("/api/health")
            .header("x-request-id", value)
            .body(Body::empty())
            .unwrap();
        let res = app.router.clone().oneshot(req).await.unwrap();
        let got = res.headers()["x-request-id"].to_str().unwrap().to_string();
        assert_eq!(got == sent, kept, "{sent:?} -> {got}");
    }
}

#[tokio::test]
async fn every_error_is_json_with_plain_words() {
    let app = TestApp::new().await;
    let t = app.login("cora@example.org").await;
    let json_ct = Some("application/json");
    type Case<'a> = (
        &'a str,
        &'a str,
        Option<&'a str>,
        Option<&'a str>,
        Vec<u8>,
        u16,
    );
    let cases: Vec<Case> = vec![
        // 404: unknown path, inside and outside /api, and an id that cannot exist.
        ("GET", "/api/nope", None, None, vec![], 404),
        ("GET", "/nope", None, None, vec![], 404),
        (
            "GET",
            "/api/periods/not-a-uuid/deck",
            Some(&t),
            None,
            vec![],
            404,
        ),
        // 405: wrong method on a known path.
        ("DELETE", "/api/health", None, None, vec![], 405),
        (
            "PUT",
            "/api/catalog",
            Some(&t),
            json_ct,
            b"{}".to_vec(),
            405,
        ),
        // 400: JSON that does not parse, or is the wrong shape.
        (
            "POST",
            "/api/auth/magic-link",
            None,
            json_ct,
            b"{oops".to_vec(),
            400,
        ),
        (
            "POST",
            "/api/auth/magic-link",
            None,
            json_ct,
            b"[]".to_vec(),
            400,
        ),
        (
            "POST",
            "/api/auth/magic-link",
            None,
            json_ct,
            b"{\"email\":5}".to_vec(),
            400,
        ),
        ("POST", "/api/auth/magic-link", None, json_ct, vec![], 400),
        (
            "POST",
            "/api/auth/magic-link",
            None,
            json_ct,
            vec![0xff, 0xfe],
            400,
        ),
        // 415: not JSON.
        (
            "POST",
            "/api/auth/magic-link",
            None,
            Some("text/plain"),
            b"{}".to_vec(),
            415,
        ),
        (
            "POST",
            "/api/auth/magic-link",
            None,
            None,
            b"{}".to_vec(),
            415,
        ),
        // 413: too large, with and without a content type.
        (
            "POST",
            "/api/auth/magic-link",
            None,
            json_ct,
            vec![b' '; 300 * 1024],
            413,
        ),
        (
            "POST",
            "/api/teams",
            Some(&t),
            json_ct,
            vec![b'1'; 300 * 1024],
            413,
        ),
        // 401 and 403.
        ("GET", "/api/me", None, None, vec![], 401),
        ("GET", "/api/me", Some("garbage"), None, vec![], 401),
        (
            "GET",
            "/api/summary?period_id=x",
            Some(&t),
            None,
            vec![],
            400,
        ),
        // Bad query strings.
        (
            "GET",
            "/api/summary?period_id=%ff%fe",
            Some(&t),
            None,
            vec![],
            400,
        ),
    ];
    for (m, u, tok, ct, body, want) in cases {
        let (s, h, bytes) = full(&app, m, u, tok, ct, body.clone()).await;
        assert_eq!(
            s.as_u16(),
            want,
            "{m} {u}: {}",
            String::from_utf8_lossy(&bytes)
        );
        let msg = error_of(&bytes);
        assert!(!msg.is_empty());
        assert!(
            h["content-type"]
                .to_str()
                .unwrap()
                .starts_with("application/json"),
            "{m} {u}"
        );
        for bad in [
            "panicked", "sql", "SELECT", "stack", "rust", "src/", "Error {",
        ] {
            assert!(!msg.contains(bad), "{m} {u}: {msg}");
        }
    }
    let (_, h, _) = full(&app, "DELETE", "/api/health", None, None, vec![]).await;
    assert!(h.contains_key("allow"), "405 keeps the Allow header");
}

#[tokio::test]
async fn health_says_503_when_the_database_is_gone() {
    let app = TestApp::new().await;
    let (s, _, bytes) = full(&app, "GET", "/api/health", None, None, vec![]).await;
    assert_eq!(s, StatusCode::OK);
    assert_eq!(
        serde_json::from_slice::<Value>(&bytes).unwrap(),
        json!({"ok": true, "db": "up"})
    );
    app.state.pool.close().await;
    let (s, h, bytes) = full(&app, "GET", "/api/health", None, None, vec![]).await;
    assert_eq!(s, StatusCode::SERVICE_UNAVAILABLE);
    let v: Value = serde_json::from_slice(&bytes).unwrap();
    assert_eq!(v["ok"], false);
    assert_eq!(v["db"], "down");
    assert!(!v["error"].as_str().unwrap().is_empty());
    assert!(!String::from_utf8_lossy(&bytes)
        .to_lowercase()
        .contains("pool"));
    assert!(h.contains_key("x-request-id"));
    // Other routes fail with the same plain 500, not a crash.
    let t = "x";
    let (s, _, bytes) = full(&app, "GET", "/api/me", Some(t), None, vec![]).await;
    assert!(s == StatusCode::UNAUTHORIZED || s == StatusCode::INTERNAL_SERVER_ERROR);
    error_of(&bytes);
}

#[tokio::test]
async fn a_panic_in_a_handler_is_a_plain_500() {
    use axum::{routing::get, Router};
    use tower_http::catch_panic::CatchPanicLayer;
    async fn boom() -> &'static str {
        panic!("secret internals: select * from person");
    }
    let app = Router::new()
        .route("/boom", get(boom))
        .layer(CatchPanicLayer::custom(xynotransit_api::http::PanicToJson));
    let res = app
        .oneshot(Request::builder().uri("/boom").body(Body::empty()).unwrap())
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::INTERNAL_SERVER_ERROR);
    let bytes = res.into_body().collect().await.unwrap().to_bytes();
    let msg = error_of(&bytes);
    assert!(!msg.contains("secret") && !msg.contains("select"));
}

#[derive(Clone, Default)]
struct Buf(Arc<Mutex<Vec<u8>>>);
impl Write for Buf {
    fn write(&mut self, b: &[u8]) -> std::io::Result<usize> {
        self.0.lock().unwrap().extend_from_slice(b);
        Ok(b.len())
    }
    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}
impl<'a> tracing_subscriber::fmt::MakeWriter<'a> for Buf {
    type Writer = Buf;
    fn make_writer(&'a self) -> Buf {
        self.clone()
    }
}

/// One log for the whole test binary (a scoped subscriber races with the other tests' threads).
fn shared_log() -> Buf {
    static LOG: std::sync::OnceLock<Buf> = std::sync::OnceLock::new();
    LOG.get_or_init(|| {
        let buf = Buf::default();
        let _ = tracing::subscriber::set_global_default(
            tracing_subscriber::fmt()
                .with_writer(buf.clone())
                .with_env_filter(tracing_subscriber::EnvFilter::new("xynotransit_api=debug"))
                .with_ansi(false)
                .finish(),
        );
        buf
    })
    .clone()
}

#[tokio::test]
async fn logs_have_request_ids_and_no_secrets() {
    let buf = shared_log();
    let app = TestApp::new().await;
    // Our own request id on every call, to find our lines among the other tests' lines.
    let mark = format!("logtest-{}", uuid::Uuid::new_v4().simple());
    let call = |method: &'static str, uri: String, token: Option<String>, body: Option<Value>| {
        let app = &app;
        let mark = mark.clone();
        async move {
            let mut b = Request::builder()
                .method(method)
                .uri(uri)
                .header("x-request-id", mark);
            if let Some(t) = token {
                b = b.header("authorization", format!("Bearer {t}"));
            }
            let req = match body {
                Some(v) => b
                    .header("content-type", "application/json")
                    .body(Body::from(serde_json::to_vec(&v).unwrap())),
                None => b.body(Body::empty()),
            }
            .unwrap();
            let res = app.router.clone().oneshot(req).await.unwrap();
            let status = res.status();
            let bytes = res.into_body().collect().await.unwrap().to_bytes();
            (
                status,
                serde_json::from_slice::<Value>(&bytes).unwrap_or(Value::Null),
            )
        }
    };

    let t = app.login("cora@example.org").await;
    let link = app.state.mailer.sent()[0].link.clone();
    let token = link.split("token=").nth(1).unwrap().to_string();
    let (_, v) = call("POST", "/api/events/ticket".into(), Some(t.clone()), None).await;
    let ticket = v["ticket"].as_str().unwrap().to_string();
    call(
        "GET",
        format!("/api/events?ticket={ticket}&period_id=x"),
        None,
        None,
    )
    .await;
    call(
        "POST",
        "/api/teams".into(),
        Some(t.clone()),
        Some(json!({"name": "Secret Team Name"})),
    )
    .await;
    call(
        "POST",
        "/api/auth/magic-link".into(),
        None,
        Some(json!({"email": "cora@example.org"})),
    )
    .await;
    call("GET", "/api/nope".into(), None, None).await;
    call("GET", "/api/health".into(), Some(t.clone()), None).await;

    let log = String::from_utf8(buf.0.lock().unwrap().clone()).unwrap();
    let mine: Vec<&str> = log.lines().filter(|l| l.contains(&mark)).collect();
    assert!(
        mine.len() >= 6,
        "expected a line per request:\n{}",
        mine.join("\n")
    );
    assert!(
        mine.iter()
            .all(|l| l.contains(&format!("request_id={mark}"))),
        "{mine:?}"
    );
    assert!(mine.iter().any(|l| l.contains("status=404")), "{mine:?}");
    assert!(
        mine.iter().any(|l| l.contains("path=/api/teams")),
        "{mine:?}"
    );
    // No query string, so no ticket; no body, so no email or link.
    for secret in [
        token.as_str(),
        ticket.as_str(),
        t.as_str(),
        "Secret Team Name",
        "token=",
        "cora@example.org",
        app.state.config.jwt_secret.as_str(),
    ] {
        assert!(!log.contains(secret), "log leaks {secret:?}");
    }
}

#[tokio::test]
async fn shutdown_lets_running_requests_finish_and_closes_event_streams() {
    let app = TestApp::new().await;
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    let (stop_tx, stop_rx) = tokio::sync::oneshot::channel::<()>();
    let server = tokio::spawn(xynotransit_api::serve(
        listener,
        app.state.clone(),
        async move {
            let _ = stop_rx.await;
        },
    ));
    let t = app.login("cora@example.org").await;
    let get = |path: String, token: String| async move {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        let mut s = tokio::net::TcpStream::connect(addr).await.unwrap();
        let req = format!(
            "GET {path} HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer {token}\r\nConnection: close\r\n\r\n"
        );
        s.write_all(req.as_bytes()).await.unwrap();
        let mut out = String::new();
        s.read_to_string(&mut out).await.unwrap();
        out
    };

    // An open event stream.
    let ticket = app
        .call("POST", "/api/events/ticket", Some(&t), None)
        .await
        .1["ticket"]
        .as_str()
        .unwrap()
        .to_string();
    let p = app.ensure_period(&t, "2026-02-01").await;
    let stream = tokio::spawn(get(
        format!("/api/events?ticket={ticket}&period_id={p}"),
        t.clone(),
    ));

    // A request that is slow because a table is locked.
    let mut lock = app.state.pool.begin().await.unwrap();
    sqlx::query("lock table team in access exclusive mode")
        .execute(&mut *lock)
        .await
        .unwrap();
    let slow = tokio::spawn(get("/api/catalog".into(), t.clone()));
    tokio::time::sleep(Duration::from_millis(400)).await;
    assert!(!slow.is_finished());

    stop_tx.send(()).unwrap();
    tokio::time::sleep(Duration::from_millis(400)).await;
    // The stream has been closed by the server, the slow request is still running.
    let stream_out = tokio::time::timeout(Duration::from_secs(3), stream)
        .await
        .expect("event stream must end on shutdown")
        .unwrap();
    assert!(stream_out.starts_with("HTTP/1.1 200"), "{stream_out}");
    assert!(!slow.is_finished());
    assert!(
        !server.is_finished(),
        "server waits for the running request"
    );

    // Let the request finish: it gets its full answer, then the server returns.
    lock.commit().await.unwrap();
    let out = tokio::time::timeout(Duration::from_secs(5), slow)
        .await
        .unwrap()
        .unwrap();
    assert!(out.starts_with("HTTP/1.1 200"), "{out}");
    assert!(out.contains("\"teams\""), "{out}");
    tokio::time::timeout(Duration::from_secs(5), server)
        .await
        .expect("server returns after the last request")
        .unwrap()
        .unwrap();
}
