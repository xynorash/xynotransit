//! The trusted front door (PROXY_AUTH_KEY): a Netlify style proxy that proves itself with a
//! shared key and tells us the visitor's address. Everything else must stay as it was.

mod common;

use std::{
    io::Write,
    sync::{Arc, Mutex},
};

use axum::{
    body::Body,
    extract::ConnectInfo,
    http::{HeaderMap, Request, StatusCode},
};
use common::*;
use http_body_util::BodyExt;
use serde_json::{json, Value};
use tower::ServiceExt;
use xynotransit_api::{
    config::Config,
    loginlimit::{constant_time_eq, front_door_addr},
};

const PW: &str = "purple bicycle rain";
const KEY: &str = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
/// The proxy's own egress address, the same for every visitor.
const NETLIFY: &str = "198.51.100.9";
const V1: &str = "203.0.113.21";
const V2: &str = "203.0.113.22";
const TOO_MANY: &str = "Too many sign-in attempts. Try again later.";

fn env() -> [(&'static str, &'static str); 1] {
    [("PROXY_AUTH_KEY", KEY)]
}

/// A login from `peer` with any extra headers.
async fn login(
    app: &TestApp,
    who: &str,
    password: &str,
    peer: &str,
    headers: &[(&str, &str)],
) -> (StatusCode, String) {
    let mut b = Request::builder()
        .method("POST")
        .uri("/api/auth/login")
        .header("content-type", "application/json");
    for (k, v) in headers {
        b = b.header(*k, *v);
    }
    let mut req = b
        .body(Body::from(
            json!({"username": who, "password": password}).to_string(),
        ))
        .unwrap();
    let addr: std::net::SocketAddr = format!("{peer}:40000").parse().unwrap();
    req.extensions_mut().insert(ConnectInfo(addr));
    let res = app.router.clone().oneshot(req).await.unwrap();
    let s = res.status();
    let body = res.into_body().collect().await.unwrap().to_bytes();
    (s, String::from_utf8_lossy(&body).into_owned())
}

fn door(ip: &str) -> Vec<(&'static str, String)> {
    vec![
        ("x-xt-proxy-key", KEY.to_string()),
        ("x-nf-client-connection-ip", ip.to_string()),
    ]
}

async fn bad(app: &TestApp, who: &str, peer: &str, h: &[(&'static str, String)]) -> StatusCode {
    let h: Vec<(&str, &str)> = h.iter().map(|(k, v)| (*k, v.as_str())).collect();
    login(app, who, "definitely not it", peer, &h).await.0
}

async fn rows_for(app: &TestApp, addr: &str) -> i64 {
    sqlx::query_scalar("select count(*) from login_failure where address_key = $1")
        .bind(app.state.limit_keys.address(Some(addr)))
        .fetch_one(&app.state.pool)
        .await
        .unwrap()
}

#[test]
fn constant_time_compare_is_correct() {
    assert!(constant_time_eq(b"abc", b"abc"));
    assert!(constant_time_eq(b"", b""));
    assert!(!constant_time_eq(b"abc", b"abd"));
    assert!(!constant_time_eq(b"abc", b"abcd"));
    assert!(!constant_time_eq(b"abcd", b"abc"));
    assert!(!constant_time_eq(b"", b"a"));
}

fn cfg(pairs: &[(&str, &str)]) -> Result<Config, String> {
    let m: Vec<(String, String)> = pairs
        .iter()
        .map(|(k, v)| (k.to_string(), v.to_string()))
        .collect();
    Config::from_lookup(|k| {
        m.iter()
            .find(|(n, _)| n == k)
            .map(|(_, v)| v.clone())
            .or(match k {
                "DATABASE_URL" => Some("postgres://x".into()),
                "JWT_SECRET" => Some(SECRET.into()),
                _ => None,
            })
    })
}

#[test]
fn config_unset_short_defaults_and_hidden_in_debug() {
    assert!(cfg(&[]).unwrap().proxy_auth.is_none());
    assert!(cfg(&[("PROXY_AUTH_KEY", "  ")])
        .unwrap()
        .proxy_auth
        .is_none());
    let e = cfg(&[("PROXY_AUTH_KEY", "short")]).unwrap_err();
    assert!(!e.contains("short"), "{e}");
    let c = cfg(&[("PROXY_AUTH_KEY", KEY)]).unwrap();
    let p = c.proxy_auth.as_ref().unwrap();
    assert_eq!(p.key_header, "x-xt-proxy-key");
    assert_eq!(p.client_header, "x-nf-client-connection-ip");
    assert!(!format!("{c:?}").contains(KEY));
    let c = cfg(&[
        ("PROXY_AUTH_KEY", KEY),
        ("PROXY_AUTH_HEADER", "X-Other-Key"),
        ("PROXY_CLIENT_HEADER", "X-Real"),
    ])
    .unwrap();
    assert_eq!(c.proxy_auth.as_ref().unwrap().key_header, "x-other-key");
    assert!(cfg(&[("PROXY_AUTH_KEY", KEY), ("PROXY_AUTH_HEADER", "bad name")]).is_err());
    assert!(cfg(&[
        ("PROXY_AUTH_KEY", KEY),
        ("PROXY_AUTH_HEADER", "x-a"),
        ("PROXY_CLIENT_HEADER", "x-a")
    ])
    .is_err());
}

#[test]
fn front_door_addr_rules() {
    let c = cfg(&[("PROXY_AUTH_KEY", KEY)]).unwrap();
    let p = c.proxy_auth.as_ref();
    let h = |pairs: &[(&str, &str)]| {
        let mut m = HeaderMap::new();
        for (k, v) in pairs {
            m.append(
                axum::http::HeaderName::from_bytes(k.as_bytes()).unwrap(),
                v.parse().unwrap(),
            );
        }
        m
    };
    let ok = [("x-xt-proxy-key", KEY), ("x-nf-client-connection-ip", V1)];
    assert_eq!(front_door_addr(p, &h(&ok)).as_deref(), Some(V1));
    assert_eq!(front_door_addr(None, &h(&ok)), None);
    assert_eq!(
        front_door_addr(p, &h(&[("x-nf-client-connection-ip", V1)])),
        None
    );
    assert_eq!(
        front_door_addr(
            p,
            &h(&[
                ("x-xt-proxy-key", "nope"),
                ("x-nf-client-connection-ip", V1)
            ])
        ),
        None
    );
    // Garbage, a private address and doubled headers are all refused.
    for ip in ["not an ip", "10.0.0.5", "", "1.2.3.4, 5.6.7.8"] {
        assert_eq!(
            front_door_addr(
                p,
                &h(&[("x-xt-proxy-key", KEY), ("x-nf-client-connection-ip", ip)])
            ),
            None,
            "{ip}"
        );
    }
    assert_eq!(
        front_door_addr(
            p,
            &h(&[
                ("x-xt-proxy-key", KEY),
                ("x-nf-client-connection-ip", V1),
                ("x-nf-client-connection-ip", V2)
            ])
        ),
        None
    );
    assert_eq!(
        front_door_addr(
            p,
            &h(&[
                ("x-xt-proxy-key", KEY),
                ("x-xt-proxy-key", KEY),
                ("x-nf-client-connection-ip", V1)
            ])
        ),
        None
    );
    // IPv6 counts per /64 like everywhere else.
    assert_eq!(
        front_door_addr(
            p,
            &h(&[
                ("x-xt-proxy-key", KEY),
                ("x-nf-client-connection-ip", "2001:db8:1:2:3:4:5:6")
            ])
        )
        .as_deref(),
        Some("2001:db8:1:2::/64")
    );
}

#[tokio::test]
async fn two_visitors_behind_one_proxy_have_independent_lockouts() {
    let app = TestApp::with_env(&env()).await;
    app.give_password(ANA, "ana", PW).await;
    app.sql("delete from login_failure").await;
    for i in 0..5 {
        assert_eq!(
            bad(&app, "ana", NETLIFY, &door(V1)).await,
            StatusCode::UNAUTHORIZED,
            "try {i}"
        );
    }
    // Visitor 1 is locked, even with the right password.
    let (s, body) = login(
        &app,
        "ana",
        PW,
        NETLIFY,
        &[("x-xt-proxy-key", KEY), ("x-nf-client-connection-ip", V1)],
    )
    .await;
    assert_eq!(s, StatusCode::TOO_MANY_REQUESTS);
    assert!(body.contains(TOO_MANY));
    // Visitor 2 behind the same proxy address is not.
    let (s, body) = login(
        &app,
        "ana",
        PW,
        NETLIFY,
        &[("x-xt-proxy-key", KEY), ("x-nf-client-connection-ip", V2)],
    )
    .await;
    assert_eq!(s, StatusCode::OK, "{body}");
    // The counters are under the visitor's address, never the proxy's.
    assert_eq!(app.pair_failures("ana", Some(V1)).await, 5);
    assert_eq!(app.pair_failures("ana", Some(V2)).await, 0);
    assert_eq!(rows_for(&app, NETLIFY).await, 0);
}

#[tokio::test]
async fn the_address_and_trusted_address_use_the_visitor_too() {
    let app = TestApp::with_env(&env()).await;
    app.give_password(ANA, "ana", PW).await;
    app.sql("delete from login_failure").await;
    app.sql("delete from login_success").await;
    // 30 failures from one visitor lock the address counter for that visitor only.
    for n in 0..30 {
        let user = format!("nobody{n}");
        assert_eq!(
            bad(&app, &user, NETLIFY, &door(V1)).await,
            StatusCode::UNAUTHORIZED
        );
    }
    assert_eq!(rows_for(&app, V1).await, 30);
    assert_eq!(
        bad(&app, "ana", NETLIFY, &door(V1)).await,
        StatusCode::TOO_MANY_REQUESTS
    );
    let h = door(V2);
    let h: Vec<(&str, &str)> = h.iter().map(|(k, v)| (*k, v.as_str())).collect();
    assert_eq!(login(&app, "ana", PW, NETLIFY, &h).await.0, StatusCode::OK);
    // The success is remembered for visitor 2's address, not for the proxy's.
    let n: i64 = sqlx::query_scalar("select count(*) from login_success where address_key = $1")
        .bind(app.state.limit_keys.address(Some(V2)))
        .fetch_one(&app.state.pool)
        .await
        .unwrap();
    assert_eq!(n, 1);
    let n: i64 = sqlx::query_scalar("select count(*) from login_success where address_key = $1")
        .bind(app.state.limit_keys.address(Some(NETLIFY)))
        .fetch_one(&app.state.pool)
        .await
        .unwrap();
    assert_eq!(n, 0);
}

#[tokio::test]
async fn wrong_missing_or_unset_key_means_the_headers_are_ignored() {
    // Key set. NO key header: the request did not come through the front door, so both headers
    // mean nothing and the peer is counted. A key header that is not exactly one correct value
    // (wrong, nearly right, doubled) is refused: never answered from the proxy's address.
    let app = TestApp::with_env(&env()).await;
    app.give_password(ANA, "ana", PW).await;
    app.sql("delete from login_failure").await;
    let missing = vec![("x-nf-client-connection-ip", V1.to_string())];
    bad(&app, "ana", NETLIFY, &missing).await;
    assert_eq!(app.pair_failures("ana", Some(NETLIFY)).await, 1);
    assert_eq!(rows_for(&app, V1).await, 0);
    let key = ("x-xt-proxy-key", KEY);
    let wrong = "f".repeat(64);
    let almost = &KEY[..63];
    let bad_keys: Vec<Vec<(&str, &str)>> = vec![
        vec![
            ("x-xt-proxy-key", wrong.as_str()),
            ("x-nf-client-connection-ip", V1),
        ],
        vec![
            ("x-xt-proxy-key", almost),
            ("x-nf-client-connection-ip", V1),
        ],
        vec![key, key, ("x-nf-client-connection-ip", V1)],
        vec![
            key,
            ("x-xt-proxy-key", "not-the-key"),
            ("x-nf-client-connection-ip", V1),
        ],
        vec![
            ("x-xt-proxy-key", "not-the-key"),
            key,
            ("x-nf-client-connection-ip", V1),
        ],
    ];
    for h in &bad_keys {
        let (st, body) = login(&app, "ana", "definitely not it", NETLIFY, h).await;
        assert_eq!(st, StatusCode::BAD_REQUEST, "{h:?} {body}");
    }
    // Refused before any counting: only the one unvouched try above exists.
    assert_eq!(app.pair_failures("ana", Some(NETLIFY)).await, 1);
    assert_eq!(rows_for(&app, V1).await, 0);
    // A forged header cannot poison somebody else, and the real visitor still gets in.
    let h = door(V2);
    let h: Vec<(&str, &str)> = h.iter().map(|(k, v)| (*k, v.as_str())).collect();
    assert_eq!(login(&app, "ana", PW, NETLIFY, &h).await.0, StatusCode::OK);
    // Nor can it dodge a lockout: with no key the proxy address is counted whatever the header says.
    for _ in 0..4 {
        bad(&app, "ana", NETLIFY, &missing).await;
    }
    let (s, _) = login(
        &app,
        "ana",
        PW,
        NETLIFY,
        &[("x-nf-client-connection-ip", "203.0.113.99")],
    )
    .await;
    assert_eq!(s, StatusCode::TOO_MANY_REQUESTS);

    // Key unset: both headers mean nothing at all.
    let app = TestApp::new().await;
    app.give_password(ANA, "ana", PW).await;
    app.sql("delete from login_failure").await;
    for _ in 0..5 {
        bad(&app, "ana", NETLIFY, &door(V1)).await;
    }
    assert_eq!(app.pair_failures("ana", Some(NETLIFY)).await, 5);
    assert_eq!(rows_for(&app, V1).await, 0);
    assert_eq!(
        bad(&app, "ana", NETLIFY, &door(V2)).await,
        StatusCode::TOO_MANY_REQUESTS
    );
}

#[tokio::test]
async fn a_vouched_request_without_exactly_one_public_address_is_refused() {
    // Netlify hands a visitor's own copy of the client header on to us next to its own, so the
    // API sees two values. Falling back to the proxy's address would let a visitor spread
    // guesses over the proxy's servers: with the key present the request is refused instead.
    let app = TestApp::with_env(&env()).await;
    app.give_password(ANA, "ana", PW).await;
    app.sql("delete from login_failure").await;
    let key = ("x-xt-proxy-key", KEY);
    let cases: Vec<Vec<(&str, &str)>> = vec![
        vec![key, ("x-nf-client-connection-ip", "garbage")],
        vec![key, ("x-nf-client-connection-ip", "10.1.2.3")],
        vec![key, ("x-nf-client-connection-ip", "1.1.1.1, 2.2.2.2")],
        vec![key, ("x-nf-client-connection-ip", "")],
        // The forged copy next to the real one.
        vec![
            key,
            ("x-nf-client-connection-ip", "198.51.100.9"),
            ("x-nf-client-connection-ip", V2),
        ],
        // No client header at all.
        vec![key],
    ];
    for h in cases {
        let (st, body) = login(&app, "ana", "definitely not it", NETLIFY, &h).await;
        assert_eq!(st, StatusCode::BAD_REQUEST, "{h:?} {body}");
        assert!(!body.contains(KEY));
    }
    // Refused before any counting: nothing was written for anyone.
    assert_eq!(app.pair_failures("ana", Some(NETLIFY)).await, 0);
    assert_eq!(rows_for(&app, V2).await, 0);
    // A duplicated or wrong key header is refused too, whatever the client header says.
    for h in [
        vec![key, key, ("x-nf-client-connection-ip", V2)],
        vec![
            ("x-xt-proxy-key", "not-the-key"),
            ("x-nf-client-connection-ip", "garbage"),
        ],
    ] {
        assert_eq!(
            login(&app, "ana", "definitely not it", NETLIFY, &h).await.0,
            StatusCode::BAD_REQUEST
        );
    }
    assert_eq!(app.pair_failures("ana", Some(NETLIFY)).await, 0);
    // And a good request still works, with one single public address.
    let (st, _) = login(
        &app,
        "ana",
        PW,
        NETLIFY,
        &[key, ("x-nf-client-connection-ip", V2)],
    )
    .await;
    assert_eq!(st, StatusCode::OK);
}

#[tokio::test]
async fn through_a_private_proxy_chain_the_visitor_header_still_wins() {
    // The real shape: Netlify -> Caddy -> nginx -> API. The peer is private and X-Forwarded-For
    // holds Netlify's egress address.
    let app = TestApp::with_env(&env()).await;
    app.give_password(ANA, "ana", PW).await;
    app.sql("delete from login_failure").await;
    let mut h = door(V1);
    h.push(("x-forwarded-for", NETLIFY.to_string()));
    bad(&app, "ana", "172.18.0.5", &h).await;
    assert_eq!(app.pair_failures("ana", Some(V1)).await, 1);
    assert_eq!(app.pair_failures("ana", Some(NETLIFY)).await, 0);
}

#[tokio::test]
async fn the_wrong_current_password_counters_use_the_visitor_too() {
    let app = TestApp::with_env(&env()).await;
    let tok = app.give_password(ANA, "ana", PW).await;
    app.sql("delete from login_failure").await;
    let mut req = Request::builder()
        .method("POST")
        .uri("/api/auth/password")
        .header("content-type", "application/json")
        .header("authorization", format!("Bearer {tok}"))
        .header("x-xt-proxy-key", KEY)
        .header("x-nf-client-connection-ip", V1)
        .body(Body::from(
            json!({"current_password": "wrong wrong wrong", "new_password": "orange walrus piano"})
                .to_string(),
        ))
        .unwrap();
    req.extensions_mut().insert(ConnectInfo(
        "198.51.100.9:40000"
            .parse::<std::net::SocketAddr>()
            .unwrap(),
    ));
    let res = app.router.clone().oneshot(req).await.unwrap();
    assert_eq!(res.status(), StatusCode::FORBIDDEN);
    assert_eq!(app.change_pair_failures(ANA, Some(V1)).await, 1);
    assert_eq!(app.change_pair_failures(ANA, Some(NETLIFY)).await, 0);
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

#[tokio::test]
async fn the_key_never_appears_in_answers_or_logs() {
    let buf = Buf::default();
    let _ = tracing::subscriber::set_global_default(
        tracing_subscriber::fmt()
            .with_writer(buf.clone())
            .with_env_filter(tracing_subscriber::EnvFilter::new("debug"))
            .with_ansi(false)
            .finish(),
    );
    let app = TestApp::with_env(&env()).await;
    app.give_password(ANA, "ana", PW).await;
    let mut seen = String::new();
    // Right key, wrong key, garbage client header, a locked pair, an unknown user.
    let wrong = "e".repeat(64);
    let cases: Vec<Vec<(&str, &str)>> = vec![
        vec![("x-xt-proxy-key", KEY), ("x-nf-client-connection-ip", V1)],
        vec![
            ("x-xt-proxy-key", &wrong),
            ("x-nf-client-connection-ip", V1),
        ],
        vec![
            ("x-xt-proxy-key", KEY),
            ("x-nf-client-connection-ip", "garbage"),
        ],
    ];
    for h in &cases {
        for _ in 0..6 {
            let (s, body) = login(&app, "ana", "definitely not it", NETLIFY, h).await;
            assert!(s.is_client_error(), "{s}");
            seen.push_str(&body);
        }
    }
    let (_, body) = login(&app, "ghost", "x", NETLIFY, &cases[0]).await;
    seen.push_str(&body);
    assert!(!seen.contains(KEY) && !seen.contains(&wrong));
    let logs = String::from_utf8_lossy(&buf.0.lock().unwrap()).into_owned();
    assert!(!logs.contains(KEY), "the key is in the log");
    assert!(!logs.contains(&wrong), "a sent key is in the log");
    // And the config never prints it.
    assert!(!format!("{:?}", app.state.config).contains(KEY));
    let _: Value = json!(null);
}

/// A key holder must still not be able to name an address that no visitor can have.
#[test]
fn front_door_refuses_addresses_no_visitor_can_have() {
    let c = cfg(&[("PROXY_AUTH_KEY", KEY)]).unwrap();
    let p = c.proxy_auth.as_ref();
    let one = |ip: &str| {
        let mut m = HeaderMap::new();
        m.append("x-xt-proxy-key", KEY.parse().unwrap());
        m.append("x-nf-client-connection-ip", ip.parse().unwrap());
        front_door_addr(p, &m)
    };
    for ip in [
        "0.0.0.0",
        "255.255.255.255",
        "224.0.0.1",
        "::",
        "ff02::1",
        "::1",
        "::ffff:10.0.0.1",
        "::ffff:0.0.0.0",
        "fe80::1",
        "fd00::1",
    ] {
        assert_eq!(one(ip), None, "{ip}");
    }
    // A mapped public address counts as the plain IPv4 one.
    assert_eq!(one("::ffff:203.0.113.21").as_deref(), Some(V1));
}
