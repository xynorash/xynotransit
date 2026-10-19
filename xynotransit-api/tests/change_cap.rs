//! Wrong CURRENT passwords on POST /api/auth/password are limited per person, from all addresses
//! together: 10 in 15 minutes. The 10th ends the person's sessions. These failures are kept apart
//! from the sign-in ones.

mod common;

use axum::http::StatusCode;
use common::*;
use serde_json::{json, Value};

const PW: &str = "purple bicycle rain";
const PW2: &str = "orange walrus piano";
const CAP_MSG: &str = "Too many password attempts. Try again later.";
const OUT_MSG: &str =
    "You were signed out for safety after too many wrong passwords. Sign in again.";

async fn change_from(
    app: &TestApp,
    tok: &str,
    current: &str,
    peer: &str,
) -> (StatusCode, Option<u64>, Value) {
    let (s, h, v) = app
        .call_from(
            "POST",
            "/api/auth/password",
            Some(tok),
            Some(json!({"current_password": current, "new_password": PW2})),
            peer,
            None,
        )
        .await;
    let ra = h
        .get("retry-after")
        .map(|x| x.to_str().unwrap().parse().unwrap());
    (s, ra, v)
}

async fn kinds(app: &TestApp, id: &str) -> Vec<String> {
    sqlx::query_scalar("select kind from password_audit where person_id = $1 order by id")
        .bind(uuid::Uuid::parse_str(id).unwrap())
        .fetch_all(&app.state.pool)
        .await
        .unwrap()
}

#[tokio::test]
async fn ten_failures_from_ten_addresses_end_the_sessions() {
    let app = TestApp::new().await;
    let tok = app.give_password(ANA, "ana", PW).await;
    app.sql("delete from login_failure").await;
    for i in 1..=9 {
        let peer = format!("198.51.100.{i}");
        let (s, ra, v) = change_from(&app, &tok, "wrong wrong wrong", &peer).await;
        assert_eq!((s, ra), (StatusCode::FORBIDDEN, None), "try {i}: {v}");
        assert_eq!(v["error"], "Your current password is not right.");
    }
    // The token still lives after nine.
    assert_eq!(
        app.call("GET", "/api/me", Some(&tok), None).await.0,
        StatusCode::OK
    );
    // The tenth ends the sessions and says so.
    let (s, _, v) = change_from(&app, &tok, "wrong wrong wrong", "198.51.100.10").await;
    assert_eq!(
        (s, v["error"].as_str()),
        (StatusCode::UNAUTHORIZED, Some(OUT_MSG))
    );
    assert_eq!(app.change_failures(ANA).await, 10);
    // The thief's token is dead, for every route.
    let (s, v) = app.call("GET", "/api/me", Some(&tok), None).await;
    assert_eq!(
        (s, v["error"].as_str()),
        (StatusCode::UNAUTHORIZED, Some("Please sign in again."))
    );
    let (s, _, _) = change_from(&app, &tok, PW, "198.51.100.11").await;
    assert_eq!(s, StatusCode::UNAUTHORIZED);
    // One audit row, kind change-lock.
    let k = kinds(&app, ANA).await;
    assert_eq!(k.iter().filter(|k| *k == "change-lock").count(), 1, "{k:?}");
    assert_eq!(k.last().map(String::as_str), Some("change-lock"));
    // The password is unchanged and the person signs in again: password, email link.
    let (s, v) = app.password_login("ana", PW).await;
    assert_eq!(s, StatusCode::OK, "{v}");
    let fresh = v["access_token"].as_str().unwrap().to_string();
    assert_eq!(
        app.call("GET", "/api/me", Some(&fresh), None).await.0,
        StatusCode::OK
    );
    let link = app.login("ana@example.org").await;
    assert_eq!(
        app.call("GET", "/api/me", Some(&link), None).await.0,
        StatusCode::OK
    );
    // Sign-in failures were never counted.
    assert_eq!(app.failures_of("ana").await, 0);
    // The new session is limited for the rest of the window, right password or not, with
    // Retry-After and the plain message.
    let (s, ra, v) = change_from(&app, &fresh, PW, "203.0.113.5").await;
    assert_eq!(
        (s, v["error"].as_str()),
        (StatusCode::TOO_MANY_REQUESTS, Some(CAP_MSG))
    );
    let ra = ra.expect("Retry-After");
    assert!((1..=900).contains(&ra) && ra >= 880, "{ra}");
    // The cap is per person: Ben is not affected.
    let ben = app.give_password(BEN, "ben", PW).await;
    let (s, _, v) = change_from(&app, &ben, PW, "203.0.113.5").await;
    assert_eq!(s, StatusCode::OK, "{v}");
}

#[tokio::test]
async fn failures_age_out_of_the_window_and_retry_after_counts_down() {
    let app = TestApp::new().await;
    let tok = app.give_password(ANA, "ana", PW).await;
    app.sql("delete from login_failure").await;
    // Ten failures, the oldest 14 minutes old: one more place frees in about a minute.
    for age in 5..=14 {
        app.add_change_failure(ANA, Some(&format!("198.51.100.{age}")), age)
            .await;
    }
    let (s, ra, v) = change_from(&app, &tok, PW, "203.0.113.9").await;
    assert_eq!(
        (s, v["error"].as_str()),
        (StatusCode::TOO_MANY_REQUESTS, Some(CAP_MSG))
    );
    let ra = ra.unwrap();
    assert!((55..=61).contains(&ra), "{ra}");
    // Refused tries are not counted again.
    assert_eq!(app.change_failures(ANA).await, 10);
    // Eleven failures: the place frees when the second oldest leaves, 2 minutes later.
    app.add_change_failure(ANA, Some("198.51.100.99"), 4).await;
    let (_, ra, _) = change_from(&app, &tok, PW, "203.0.113.9").await;
    let ra = ra.unwrap();
    assert!((115..=121).contains(&ra), "{ra}");
    // Failures older than 15 minutes do not count: nine fresh ones and old ones are fine.
    app.sql("delete from login_failure").await;
    for i in 0..9 {
        app.add_change_failure(ANA, Some(&format!("198.51.100.{i}")), 1)
            .await;
    }
    for i in 0..20 {
        app.add_change_failure(ANA, Some(&format!("192.0.2.{i}")), 16)
            .await;
    }
    let (s, _, v) = change_from(&app, &tok, PW, "203.0.113.9").await;
    assert_eq!(s, StatusCode::OK, "{v}");
}

#[tokio::test]
async fn sign_in_failures_of_outsiders_never_block_the_signed_in_person() {
    let app = TestApp::new().await;
    let tok = app.give_password(ANA, "ana", PW).await;
    app.sql("delete from login_failure").await;
    // An outsider lock on the name, the pair and the address, as heavy as can be.
    for i in 0..120 {
        app.add_failure("ana", Some(&format!("198.51.100.{}", i % 250)), 1)
            .await;
    }
    for _ in 0..40 {
        app.add_failure("ana", Some("203.0.113.9"), 1).await;
    }
    for _ in 0..40 {
        app.add_failure("someone.else", Some("203.0.113.9"), 1)
            .await;
    }
    // Wrong tries are answered as ever ...
    let (s, ra, v) = change_from(&app, &tok, "wrong wrong wrong", "203.0.113.9").await;
    assert_eq!((s, ra), (StatusCode::FORBIDDEN, None), "{v}");
    // ... and the right one works.
    let (s, _, v) = change_from(&app, &tok, PW, "203.0.113.9").await;
    assert_eq!(s, StatusCode::OK, "{v}");
}

#[tokio::test]
async fn change_failures_never_count_for_sign_in_locks() {
    let app = TestApp::new().await;
    let tok = app.give_password(ANA, "ana", PW).await;
    app.sql("delete from login_failure").await;
    for i in 0..4 {
        let (s, _, _) = change_from(&app, &tok, "wrong wrong wrong", "203.0.113.9").await;
        assert_eq!(s, StatusCode::FORBIDDEN, "{i}");
    }
    assert_eq!(app.failures_of("ana").await, 0);
    assert_eq!(app.pair_failures("ana", Some("203.0.113.9")).await, 0);
    let (s, _, v) = app
        .call_from(
            "POST",
            "/api/auth/login",
            None,
            Some(json!({"username": "ana", "password": "nope nope nope"})),
            "203.0.113.9",
            None,
        )
        .await;
    assert_eq!(s, StatusCode::UNAUTHORIZED, "{v}");
    // A right current password clears only that pair's change failures.
    let (s, _, v) = change_from(&app, &tok, PW, "203.0.113.9").await;
    assert_eq!(s, StatusCode::OK, "{v}");
    assert_eq!(app.change_failures(ANA).await, 0);
}

#[tokio::test]
async fn parallel_wrong_attempts_never_allow_an_eleventh_verification() {
    let app = TestApp::new().await;
    let tok = app.give_password(ANA, "ana", PW).await;
    app.sql("delete from login_failure").await;
    let mut set = tokio::task::JoinSet::new();
    for i in 0..40 {
        let router = app.router.clone();
        let tok = tok.clone();
        set.spawn(async move {
            use tower::ServiceExt;
            let mut req = axum::http::Request::builder()
                .method("POST")
                .uri("/api/auth/password")
                .header("content-type", "application/json")
                .header("authorization", format!("Bearer {tok}"))
                .body(axum::body::Body::from(
                    json!({"current_password": "wrong wrong wrong", "new_password": PW2})
                        .to_string(),
                ))
                .unwrap();
            let peer: std::net::SocketAddr = format!("198.51.100.{}:40000", 1 + i).parse().unwrap();
            req.extensions_mut()
                .insert(axum::extract::ConnectInfo(peer));
            router.oneshot(req).await.unwrap().status()
        });
    }
    let mut codes = vec![];
    while let Some(r) = set.join_next().await {
        codes.push(r.unwrap());
    }
    let n = |c: StatusCode| codes.iter().filter(|x| **x == c).count();
    // Ten verifications at most: each of them wrote its row first.
    assert_eq!(app.change_failures(ANA).await, 10, "{codes:?}");
    assert_eq!(n(StatusCode::TOO_MANY_REQUESTS), 30, "{codes:?}");
    // Only the 10th recorded try ends the sessions; the nine before it are plain wrong answers.
    assert_eq!(n(StatusCode::FORBIDDEN), 9, "{codes:?}");
    assert_eq!(n(StatusCode::UNAUTHORIZED), 1, "{codes:?}");
    // The sessions ended exactly once.
    let k = kinds(&app, ANA).await;
    assert_eq!(k.iter().filter(|k| *k == "change-lock").count(), 1, "{k:?}");
    assert_eq!(app.password_login("ana", PW).await.0, StatusCode::OK);
}

#[tokio::test]
async fn the_keys_are_hashed_and_the_rows_hold_no_names() {
    let app = TestApp::new().await;
    let tok = app.give_password(ANA, "ana", PW).await;
    app.sql("delete from login_failure").await;
    change_from(&app, &tok, "wrong wrong wrong", "203.0.113.9").await;
    let rows: Vec<(String, String)> =
        sqlx::query_as("select username_key, address_key from login_failure")
            .fetch_all(&app.state.pool)
            .await
            .unwrap();
    assert_eq!(rows.len(), 1);
    for k in [&rows[0].0, &rows[0].1] {
        assert_eq!(k.len(), 64);
        assert!(!k.contains(ANA) && !k.contains("203.0.113.9"));
    }
    // Neither key is the one the sign-in limits use.
    assert_ne!(rows[0].0, app.user_key("ana"));
    assert_ne!(rows[0].1, app.addr_key(Some("203.0.113.9")));
}
