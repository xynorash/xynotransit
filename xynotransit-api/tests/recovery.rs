//! Two fixes from the security review of password sign-in:
//!  * event tickets and open event streams follow the person (epoch, switch-off, role);
//!  * a fresh sign-in by link may choose a new password without the old one (recovery).

mod common;

use std::time::Duration;

use axum::http::StatusCode;
use common::*;
use http_body_util::BodyExt;
use serde_json::json;
use tower::ServiceExt;
use xynotransit_api::auth::Via;

const PW: &str = "purple bicycle rain";
const PW2: &str = "orange walrus piano";
const PW3: &str = "granite lantern meadow";

// ---------------------------------------------------------------------------------------------
// event tickets
// ---------------------------------------------------------------------------------------------

/// A second manager (Ben) who resets, removes or switches off Cora, the first.
async fn two_managers(app: &TestApp) -> (String, String) {
    app.sql(&format!(
        "update person set app_role = 'controller' where id = '{BEN}'"
    ))
    .await;
    let cora = app.give_password(CORA, "cora", PW).await;
    let ben = app.token_for(BEN, true);
    (cora, ben)
}

/// Ben (a manager) gives `id` the password `pw`, whatever state the person is in.
async fn reset_to(app: &TestApp, ben: &str, id: &str, username: &str, pw: &str) -> String {
    let (s, v) = app
        .call(
            "POST",
            &format!("/api/persons/{id}/password-reset"),
            Some(ben),
            Some(json!({})),
        )
        .await;
    assert_eq!(s, StatusCode::CREATED, "{v}");
    let temp = v["temporary_password"].as_str().unwrap().to_string();
    let (s, v) = app.password_login(username, &temp).await;
    assert_eq!(s, StatusCode::OK, "{v}");
    let tok = v["access_token"].as_str().unwrap().to_string();
    let (s, v) = change(
        app,
        &tok,
        json!({"current_password": temp, "new_password": pw}),
    )
    .await;
    assert_eq!(s, StatusCode::OK, "{v}");
    v["access_token"].as_str().unwrap().to_string()
}

async fn ticket(app: &TestApp, token: &str) -> String {
    let (s, v) = app
        .call("POST", "/api/events/ticket", Some(token), None)
        .await;
    assert_eq!(s, StatusCode::OK, "{v}");
    v["ticket"].as_str().unwrap().to_string()
}

async fn open(app: &TestApp, ticket: &str, period: &str) -> (StatusCode, axum::body::Body) {
    let res = app
        .router
        .clone()
        .oneshot(
            axum::http::Request::builder()
                .uri(format!("/api/events?ticket={ticket}&period_id={period}"))
                .body(axum::body::Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    (res.status(), res.into_body())
}

/// Does the stream end (the body gives None) within `within`?
async fn ends_within(body: &mut axum::body::Body, within: Duration) -> bool {
    let end = tokio::time::Instant::now() + within;
    loop {
        match tokio::time::timeout_at(end, body.frame()).await {
            Err(_) => return false,
            Ok(None) | Ok(Some(Err(_))) => return true,
            Ok(Some(Ok(_))) => {} // pings and events
        }
    }
}

#[tokio::test]
async fn a_ticket_made_before_a_password_change_opens_nothing() {
    let app = TestApp::new().await;
    let (cora, ben) = two_managers(&app).await;
    let p = app.ensure_period(&ben, "2026-02-01").await;

    // A ticket made now works (and only once).
    let t = ticket(&app, &cora).await;
    assert_eq!(open(&app, &t, &p).await.0, StatusCode::OK);
    assert_eq!(open(&app, &t, &p).await.0, StatusCode::UNAUTHORIZED);

    // Made before the person changes the password herself.
    let before_change = ticket(&app, &cora).await;
    let (s, v) = app
        .call(
            "POST",
            "/api/auth/password",
            Some(&cora),
            Some(json!({"current_password": PW, "new_password": PW2})),
        )
        .await;
    assert_eq!(s, StatusCode::OK, "{v}");
    let new = v["access_token"].as_str().unwrap().to_string();
    assert_eq!(
        open(&app, &before_change, &p).await.0,
        StatusCode::UNAUTHORIZED
    );
    // A ticket made after the change works.
    let after = ticket(&app, &new).await;
    assert_eq!(open(&app, &after, &p).await.0, StatusCode::OK);

    // Made before a manager resets the password (the person must then choose a new one).
    let before_reset = ticket(&app, &new).await;
    let (s, v) = app
        .call(
            "POST",
            &format!("/api/persons/{CORA}/password-reset"),
            Some(&ben),
            Some(json!({})),
        )
        .await;
    assert_eq!(s, StatusCode::CREATED, "{v}");
    assert_eq!(
        open(&app, &before_reset, &p).await.0,
        StatusCode::UNAUTHORIZED
    );

    // Made before a manager removes the password.
    let cora = reset_to(&app, &ben, CORA, "cora", PW3).await;
    let before_remove = ticket(&app, &cora).await;
    let (s, v) = app
        .call(
            "DELETE",
            &format!("/api/persons/{CORA}/password"),
            Some(&ben),
            None,
        )
        .await;
    assert_eq!(s, StatusCode::NO_CONTENT, "{v}");
    assert_eq!(
        open(&app, &before_remove, &p).await.0,
        StatusCode::UNAUTHORIZED
    );

    // Made before the person is switched off.
    let link = app.token_for_epoch(CORA, true, current_epoch(&app).await);
    let before_off = ticket(&app, &link).await;
    let (s, _) = app
        .call(
            "PATCH",
            &format!("/api/persons/{CORA}"),
            Some(&ben),
            Some(json!({"active": false})),
        )
        .await;
    assert_eq!(s, StatusCode::OK);
    assert_eq!(
        open(&app, &before_off, &p).await.0,
        StatusCode::UNAUTHORIZED
    );
}

async fn current_epoch(app: &TestApp) -> i32 {
    sqlx::query_scalar(&format!(
        "select session_epoch from person where id = '{CORA}'"
    ))
    .fetch_one(&app.state.pool)
    .await
    .unwrap()
}

#[tokio::test]
async fn an_open_stream_ends_when_the_person_changes() {
    let app = TestApp::with_stream_recheck(Duration::from_millis(150)).await;
    let (cora, ben) = two_managers(&app).await;
    let p = app.ensure_period(&ben, "2026-02-01").await;

    // Nothing changes: the stream stays open well past several checks.
    let t = ticket(&app, &cora).await;
    let (s, mut body) = open(&app, &t, &p).await;
    assert_eq!(s, StatusCode::OK);
    assert!(!ends_within(&mut body, Duration::from_millis(800)).await);

    // A manager resets the password: the open stream ends.
    let (s, _) = app
        .call(
            "POST",
            &format!("/api/persons/{CORA}/password-reset"),
            Some(&ben),
            Some(json!({})),
        )
        .await;
    assert_eq!(s, StatusCode::CREATED);
    assert!(
        ends_within(&mut body, Duration::from_secs(3)).await,
        "the stream stayed open after a reset"
    );

    // The same for a password change by the person, a removal, a demotion and a switch-off.
    type Change = (&'static str, &'static str);
    let changes: [Change; 3] = [
        ("remove", "password removed"),
        ("demote", "no longer a manager"),
        ("off", "switched off"),
    ];
    for (what, label) in changes {
        app.sql(&format!(
            "update person set active = true, app_role = 'controller', must_change_password = false where id = '{CORA}'"
        ))
        .await;
        let cora = reset_to(&app, &ben, CORA, "cora", PW2).await;
        let t = ticket(&app, &cora).await;
        let (s, mut body) = open(&app, &t, &p).await;
        assert_eq!(s, StatusCode::OK, "{label}");
        match what {
            "remove" => {
                let (s, _) = app
                    .call(
                        "DELETE",
                        &format!("/api/persons/{CORA}/password"),
                        Some(&ben),
                        None,
                    )
                    .await;
                assert_eq!(s, StatusCode::NO_CONTENT);
            }
            "demote" => {
                app.sql(&format!(
                    "update person set app_role = 'contributor' where id = '{CORA}'"
                ))
                .await
            }
            _ => {
                app.sql(&format!(
                    "update person set active = false where id = '{CORA}'"
                ))
                .await
            }
        }
        assert!(
            ends_within(&mut body, Duration::from_secs(3)).await,
            "{label}: the stream stayed open"
        );
    }

    // A change of password by the person herself ends her own stream too.
    app.sql(&format!(
        "update person set active = true, app_role = 'controller' where id = '{CORA}'"
    ))
    .await;
    let cora = reset_to(&app, &ben, CORA, "cora", PW3).await;
    let t = ticket(&app, &cora).await;
    let (_, mut body) = open(&app, &t, &p).await;
    let (s, _) = app
        .call(
            "POST",
            "/api/auth/password",
            Some(&cora),
            Some(json!({"current_password": PW3, "new_password": PW})),
        )
        .await;
    assert_eq!(s, StatusCode::OK);
    assert!(ends_within(&mut body, Duration::from_secs(3)).await);
}

// ---------------------------------------------------------------------------------------------
// recovery by link
// ---------------------------------------------------------------------------------------------

async fn me(app: &TestApp, token: &str) -> serde_json::Value {
    let (s, v) = app.call("GET", "/api/me", Some(token), None).await;
    assert_eq!(s, StatusCode::OK, "{v}");
    v
}

async fn change(
    app: &TestApp,
    token: &str,
    body: serde_json::Value,
) -> (StatusCode, serde_json::Value) {
    app.call("POST", "/api/auth/password", Some(token), Some(body))
        .await
}

/// The epoch ana's session claims right now.
async fn epoch_of(app: &TestApp, id: &str) -> i32 {
    sqlx::query_scalar(&format!(
        "select session_epoch from person where id = '{id}'"
    ))
    .fetch_one(&app.state.pool)
    .await
    .unwrap()
}

#[tokio::test]
async fn a_fresh_link_session_may_choose_a_new_password_without_the_old_one() {
    let app = TestApp::new().await;
    app.give_password(ANA, "ana", PW).await;
    // Ana forgot the password; a manager sends a link, she opens it.
    let link = app.login("ana@example.org").await;
    let m = me(&app, &link).await;
    assert_eq!(m["has_password"], true);
    assert_eq!(m["recent_link_session"], true);
    // No current password needed.
    let (s, v) = change(&app, &link, json!({"new_password": PW2})).await;
    assert_eq!(s, StatusCode::OK, "{v}");
    let after = v["access_token"].as_str().unwrap().to_string();
    // The old password is gone, the new one works, and the link session ended.
    assert_eq!(
        app.password_login("ana", PW).await.0,
        StatusCode::UNAUTHORIZED
    );
    assert_eq!(app.password_login("ana", PW2).await.0, StatusCode::OK);
    assert_eq!(
        app.call("GET", "/api/me", Some(&link), None).await.0,
        StatusCode::UNAUTHORIZED
    );
    // The new session is a password session: it needs the current password again.
    let m = me(&app, &after).await;
    assert_eq!(m["recent_link_session"], false);
    let (s, v) = change(&app, &after, json!({"new_password": PW3})).await;
    assert_eq!(
        (s, v["error"].as_str()),
        (
            StatusCode::BAD_REQUEST,
            Some("Enter your current password.")
        )
    );
    // The audit trail says how.
    let kinds: Vec<String> =
        sqlx::query_scalar("select kind from password_audit where person_id = $1 order by id")
            .bind(uuid::Uuid::parse_str(ANA).unwrap())
            .fetch_all(&app.state.pool)
            .await
            .unwrap();
    assert_eq!(kinds.last().map(String::as_str), Some("change-via-link"));
    assert_eq!(app.count("login_failure").await, 0);
}

#[tokio::test]
async fn the_link_rule_has_edges() {
    let app = TestApp::new().await;
    app.give_password(ANA, "ana", PW).await;
    let ep = epoch_of(&app, ANA).await;
    let tok = |via: Via, age: i64| app.token_via(ANA, false, ep, via, age);

    // 14 minutes old: still fresh. 16 minutes: not any more.
    let fresh = tok(Via::Link, 14);
    assert_eq!(me(&app, &fresh).await["recent_link_session"], true);
    let old = tok(Via::Link, 16);
    assert_eq!(me(&app, &old).await["recent_link_session"], false);
    let (s, v) = change(&app, &old, json!({"new_password": PW2})).await;
    assert_eq!(
        (s, v["error"].as_str()),
        (
            StatusCode::BAD_REQUEST,
            Some("Enter your current password.")
        )
    );
    // Old link sessions can still change it the normal way.
    let (s, v) = change(
        &app,
        &old,
        json!({"current_password": PW, "new_password": PW2}),
    )
    .await;
    assert_eq!(s, StatusCode::OK, "{v}");

    // A password session, however new, always needs the current password.
    let ep = epoch_of(&app, ANA).await;
    let pw_session = app.token_via(ANA, false, ep, Via::Password, 0);
    assert_eq!(me(&app, &pw_session).await["recent_link_session"], false);
    let (s, _) = change(&app, &pw_session, json!({"new_password": PW3})).await;
    assert_eq!(s, StatusCode::BAD_REQUEST);
    // A token from before the claim existed is a password session.
    let legacy = app.token_for_epoch(ANA, false, ep);
    let (s, _) = change(&app, &legacy, json!({"new_password": PW3})).await;
    assert_eq!(s, StatusCode::BAD_REQUEST);

    // The policy still applies to the new password.
    let ep = epoch_of(&app, ANA).await;
    let link = app.token_via(ANA, false, ep, Via::Link, 1);
    for weak in ["short", "1234567890", "ana@example.org"] {
        let (s, v) = change(&app, &link, json!({"new_password": weak})).await;
        assert_eq!(s, StatusCode::BAD_REQUEST, "{weak}: {v}");
    }
    // A wrong current password sent along is not looked at and counts for nothing: the link
    // already proved who it is, and this cannot be used to test guesses.
    assert_eq!(app.count("login_failure").await, 0);
    let (s, v) = change(
        &app,
        &link,
        json!({"current_password": "totally wrong one", "new_password": PW3}),
    )
    .await;
    assert_eq!(s, StatusCode::OK, "{v}");
    assert_eq!(app.count("login_failure").await, 0);
    assert_eq!(app.password_login("ana", PW3).await.0, StatusCode::OK);

    // Choosing the same password again through a link is not an oracle: it is simply allowed.
    let ep = epoch_of(&app, ANA).await;
    let link = app.token_via(ANA, false, ep, Via::Link, 0);
    let (s, _) = change(&app, &link, json!({"new_password": PW3})).await;
    assert_eq!(s, StatusCode::OK);
}

#[tokio::test]
async fn a_link_session_of_someone_without_a_password_and_after_a_reset() {
    let app = TestApp::new().await;
    // No password: the first password after a link, as before, with the old audit kind.
    let link = app.login("ben@example.org").await;
    let m = me(&app, &link).await;
    assert_eq!(
        (m["has_password"].clone(), m["recent_link_session"].clone()),
        (json!(false), json!(false))
    );
    let (s, v) = change(&app, &link, json!({"new_password": PW})).await;
    assert_eq!(s, StatusCode::OK, "{v}");
    let kind: String = sqlx::query_scalar(&format!(
        "select kind from password_audit where person_id = '{BEN}' order by id desc limit 1"
    ))
    .fetch_one(&app.state.pool)
    .await
    .unwrap();
    assert_eq!(kind, "change");

    // A manager resets the password: every older session, link sessions too, ends.
    let manager = app.token_for(CORA, true);
    let link = app.login("ben@example.org").await;
    let (s, v) = app
        .call(
            "POST",
            &format!("/api/persons/{BEN}/password-reset"),
            Some(&manager),
            Some(json!({})),
        )
        .await;
    assert_eq!(s, StatusCode::CREATED, "{v}");
    assert_eq!(
        app.call("GET", "/api/me", Some(&link), None).await.0,
        StatusCode::UNAUTHORIZED
    );
    // A link opened after the reset: the person is asked to choose a password, no old one needed.
    let link = app.login("ben@example.org").await;
    let m = me(&app, &link).await;
    assert_eq!(m["must_change_password"], true);
    let (s, v) = change(&app, &link, json!({"new_password": PW2})).await;
    assert_eq!(s, StatusCode::OK, "{v}");
    assert_eq!(app.password_login("ben", PW2).await.0, StatusCode::OK);
}
