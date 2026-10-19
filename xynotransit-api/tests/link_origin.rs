//! Where a sign-in link came from and whether it allows recovery (choosing a new password
//! without the current one). Email links do; manager and server links only with "recovery".

mod common;

use axum::http::StatusCode;
use common::*;
use serde_json::{json, Value};
use xynotransit_api::auth::Via;

const PW: &str = "purple bicycle rain";
const PW2: &str = "orange walrus piano";
const PW3: &str = "granite lantern meadow";

fn token_of(url: &str) -> String {
    url.split("token=").nth(1).unwrap().to_string()
}

async fn verify(app: &TestApp, url: &str) -> String {
    let (s, v) = app
        .call(
            "POST",
            "/api/auth/verify",
            None,
            Some(json!({"token": token_of(url)})),
        )
        .await;
    assert_eq!(s, StatusCode::OK, "{v}");
    v["access_token"].as_str().unwrap().to_string()
}

async fn admin_link(app: &TestApp, id: &str, body: Value) -> (StatusCode, Value) {
    let boss = app.token_for(CORA, true);
    app.call(
        "POST",
        &format!("/api/persons/{id}/sign-in-link"),
        Some(&boss),
        Some(body),
    )
    .await
}

async fn change(app: &TestApp, tok: &str, body: Value) -> (StatusCode, Value) {
    app.call("POST", "/api/auth/password", Some(tok), Some(body))
        .await
}

async fn me(app: &TestApp, tok: &str) -> Value {
    let (s, v) = app.call("GET", "/api/me", Some(tok), None).await;
    assert_eq!(s, StatusCode::OK, "{v}");
    v
}

async fn last_kind(app: &TestApp, id: &str) -> String {
    sqlx::query_scalar(
        "select kind from password_audit where person_id = $1 order by id desc limit 1",
    )
    .bind(uuid::Uuid::parse_str(id).unwrap())
    .fetch_one(&app.state.pool)
    .await
    .unwrap()
}

#[tokio::test]
async fn a_manager_link_without_recovery_needs_the_current_password() {
    let app = TestApp::new().await;
    app.give_password(ANA, "ana", PW).await;
    app.sql("delete from login_failure").await;
    for body in [
        json!({}),
        json!({"recovery": false}),
        json!({"recovery": null}),
    ] {
        let (s, v) = admin_link(&app, ANA, body).await;
        assert_eq!(s, StatusCode::CREATED, "{v}");
        assert_eq!(v["recovery"], false);
        let tok = verify(&app, v["url"].as_str().unwrap()).await;
        assert_eq!(me(&app, &tok).await["recent_link_session"], false);
        // Without the current password: asked for it, nothing counted.
        let (s, v) = change(&app, &tok, json!({"new_password": PW2})).await;
        assert_eq!(
            (s, v["error"].as_str()),
            (
                StatusCode::BAD_REQUEST,
                Some("Enter your current password.")
            )
        );
        // With a wrong one: 403 and a failure counted.
        let before = app.change_failures(ANA).await;
        let (s, v) = change(
            &app,
            &tok,
            json!({"current_password": "wrong wrong wrong", "new_password": PW2}),
        )
        .await;
        assert_eq!(
            (s, v["error"].as_str()),
            (
                StatusCode::FORBIDDEN,
                Some("Your current password is not right.")
            )
        );
        assert_eq!(app.change_failures(ANA).await, before + 1);
    }
    // Password unchanged. With the right current password it works like any session.
    assert_eq!(app.password_login("ana", PW).await.0, StatusCode::OK);
    let (_, v) = admin_link(&app, ANA, json!({})).await;
    let tok = verify(&app, v["url"].as_str().unwrap()).await;
    let (s, v) = change(
        &app,
        &tok,
        json!({"current_password": PW, "new_password": PW2}),
    )
    .await;
    assert_eq!(s, StatusCode::OK, "{v}");
    assert_eq!(last_kind(&app, ANA).await, "change");
    // The rows say what they are.
    let rows: Vec<(String, bool)> =
        sqlx::query_as("select origin, allow_recovery from login_token where person_id = $1")
            .bind(uuid::Uuid::parse_str(ANA).unwrap())
            .fetch_all(&app.state.pool)
            .await
            .unwrap();
    assert!(rows.iter().all(|r| r.0 == "admin" && !r.1), "{rows:?}");
    let (o, r): (String, bool) = sqlx::query_as(
        "select origin, recovery from sign_in_link_audit where person_id = $1 order by id desc limit 1",
    )
    .bind(uuid::Uuid::parse_str(ANA).unwrap())
    .fetch_one(&app.state.pool)
    .await
    .unwrap();
    assert_eq!((o.as_str(), r), ("admin", false));
}

#[tokio::test]
async fn a_manager_link_with_recovery_lets_the_person_choose_a_new_password() {
    let app = TestApp::new().await;
    app.give_password(ANA, "ana", PW).await;
    let (s, v) = admin_link(&app, ANA, json!({"recovery": true, "hours": 2})).await;
    assert_eq!(s, StatusCode::CREATED, "{v}");
    assert_eq!(v["recovery"], true);
    let tok = verify(&app, v["url"].as_str().unwrap()).await;
    assert_eq!(me(&app, &tok).await["recent_link_session"], true);
    let (s, v) = change(&app, &tok, json!({"new_password": PW2})).await;
    assert_eq!(s, StatusCode::OK, "{v}");
    assert_eq!(last_kind(&app, ANA).await, "change-via-link");
    assert_eq!(app.password_login("ana", PW2).await.0, StatusCode::OK);
    let (o, r, who): (String, bool, Option<uuid::Uuid>) = sqlx::query_as(
        "select origin, recovery, issued_by from sign_in_link_audit
         where person_id = $1 order by id desc limit 1",
    )
    .bind(uuid::Uuid::parse_str(ANA).unwrap())
    .fetch_one(&app.state.pool)
    .await
    .unwrap();
    assert_eq!((o.as_str(), r, who.is_some()), ("admin", true, true));
    let (o, r): (String, bool) = sqlx::query_as(
        "select origin, allow_recovery from login_token where person_id = $1
         order by expires_at desc limit 1",
    )
    .bind(uuid::Uuid::parse_str(ANA).unwrap())
    .fetch_one(&app.state.pool)
    .await
    .unwrap();
    assert_eq!((o.as_str(), r), ("admin", true));
}

#[tokio::test]
async fn recovery_only_applies_to_a_person_who_has_a_password() {
    let app = TestApp::new().await;
    // Ben has no password: the answer says false, the row too.
    let (s, v) = admin_link(&app, BEN, json!({"recovery": true})).await;
    assert_eq!(s, StatusCode::CREATED, "{v}");
    assert_eq!(v["recovery"], false);
    let rec: bool = sqlx::query_scalar(
        "select recovery from sign_in_link_audit where person_id = $1 order by id desc limit 1",
    )
    .bind(uuid::Uuid::parse_str(BEN).unwrap())
    .fetch_one(&app.state.pool)
    .await
    .unwrap();
    assert!(!rec);
    // A first password after any link needs no current one.
    let tok = verify(&app, v["url"].as_str().unwrap()).await;
    let m = me(&app, &tok).await;
    assert_eq!(
        (m["has_password"].clone(), m["recent_link_session"].clone()),
        (json!(false), json!(false))
    );
    let (s, v) = change(&app, &tok, json!({"new_password": PW})).await;
    assert_eq!(s, StatusCode::OK, "{v}");
    assert_eq!(last_kind(&app, BEN).await, "change");
    // Wrong types are refused in plain words.
    for bad in [json!("yes"), json!(1), json!([true]), json!({})] {
        let (s, v) = admin_link(&app, BEN, json!({"recovery": bad})).await;
        assert_eq!(
            (s, v["error"].as_str()),
            (
                StatusCode::BAD_REQUEST,
                Some("Recovery must be true or false.")
            )
        );
    }
}

#[tokio::test]
async fn an_email_link_keeps_recovery() {
    let app = TestApp::new().await;
    app.give_password(ANA, "ana", PW).await;
    let tok = app.login("ana@example.org").await;
    assert_eq!(me(&app, &tok).await["recent_link_session"], true);
    let (o, r): (String, bool) = sqlx::query_as(
        "select origin, allow_recovery from login_token where person_id = $1
         order by expires_at desc limit 1",
    )
    .bind(uuid::Uuid::parse_str(ANA).unwrap())
    .fetch_one(&app.state.pool)
    .await
    .unwrap();
    assert_eq!((o.as_str(), r), ("email", true));
    let (s, v) = change(&app, &tok, json!({"new_password": PW2})).await;
    assert_eq!(s, StatusCode::OK, "{v}");
    assert_eq!(last_kind(&app, ANA).await, "change-via-link");
}

#[tokio::test]
async fn the_server_command_links_with_and_without_the_flag() {
    let app = TestApp::new().await;
    app.give_password(ANA, "ana", PW).await;
    let make = |recovery: bool| {
        let app = &app;
        async move {
            xynotransit_api::signin::sign_in_link_for_email(
                &app.state.pool,
                "http://x.test",
                "ana@example.org",
                24,
                recovery,
            )
            .await
            .unwrap()
        }
    };
    // Without the flag: a plain link.
    let l = make(false).await;
    assert!(!l.recovery);
    let tok = verify(&app, &l.url).await;
    assert_eq!(me(&app, &tok).await["recent_link_session"], false);
    let (s, _) = change(&app, &tok, json!({"new_password": PW2})).await;
    assert_eq!(s, StatusCode::BAD_REQUEST);
    let (s, v) = change(
        &app,
        &tok,
        json!({"current_password": "wrong wrong wrong", "new_password": PW2}),
    )
    .await;
    assert_eq!(
        (s, v["error"].as_str()),
        (
            StatusCode::FORBIDDEN,
            Some("Your current password is not right.")
        )
    );
    // With the flag: recovery.
    let l = make(true).await;
    assert!(l.recovery);
    let tok = verify(&app, &l.url).await;
    assert_eq!(me(&app, &tok).await["recent_link_session"], true);
    let (s, v) = change(&app, &tok, json!({"new_password": PW3})).await;
    assert_eq!(s, StatusCode::OK, "{v}");
    let rows: Vec<(String, bool, Option<uuid::Uuid>)> = sqlx::query_as(
        "select origin, recovery, issued_by from sign_in_link_audit
         where person_id = $1 order by id",
    )
    .bind(uuid::Uuid::parse_str(ANA).unwrap())
    .fetch_all(&app.state.pool)
    .await
    .unwrap();
    assert_eq!(
        rows,
        vec![("cli".into(), false, None), ("cli".into(), true, None)]
    );
    let toks: Vec<(String, bool)> = sqlx::query_as(
        "select origin, allow_recovery from login_token where origin <> 'email' order by expires_at",
    )
    .fetch_all(&app.state.pool)
    .await
    .unwrap();
    assert_eq!(toks, vec![("cli".into(), false), ("cli".into(), true)]);
    // No recovery for a person without a password, flag or not.
    let l = xynotransit_api::signin::sign_in_link_for_email(
        &app.state.pool,
        "http://x.test",
        "ben@example.org",
        24,
        true,
    )
    .await
    .unwrap();
    assert!(!l.recovery);
}

#[tokio::test]
async fn the_session_claim_and_the_me_flag() {
    let app = TestApp::new().await;
    app.give_password(ANA, "ana", PW).await;
    let ep: i32 = sqlx::query_scalar("select session_epoch from person where id = $1")
        .bind(uuid::Uuid::parse_str(ANA).unwrap())
        .fetch_one(&app.state.pool)
        .await
        .unwrap();
    // link-plain is never a recovery session, however new.
    let plain = app.token_via(ANA, false, ep, Via::LinkPlain, 0);
    assert_eq!(me(&app, &plain).await["recent_link_session"], false);
    let (s, _) = change(&app, &plain, json!({"new_password": PW2})).await;
    assert_eq!(s, StatusCode::BAD_REQUEST);
    // link counts for 15 minutes only.
    assert_eq!(
        me(&app, &app.token_via(ANA, false, ep, Via::Link, 14)).await["recent_link_session"],
        true
    );
    assert_eq!(
        me(&app, &app.token_via(ANA, false, ep, Via::Link, 16)).await["recent_link_session"],
        false
    );
    // The claim reads "link-plain" in the token.
    let claims = plain.split('.').nth(1).unwrap();
    use base64::Engine;
    let bytes = base64::engine::general_purpose::URL_SAFE_NO_PAD
        .decode(claims)
        .unwrap();
    let c: Value = serde_json::from_slice(&bytes).unwrap();
    assert_eq!(c["via"], "link-plain");
}
