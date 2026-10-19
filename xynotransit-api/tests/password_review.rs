//! Found in the security review of password sign-in: each test failed before its fix.

mod common;

use axum::http::StatusCode;
use common::*;
use serde_json::json;

const PW: &str = "purple bicycle rain";

/// A NUL character cannot be stored by Postgres. It used to reach the database as part of the
/// sign-in key and answer 500; it is just a wrong username (and a wrong password) like any other.
#[tokio::test]
async fn a_nul_character_in_the_username_or_password_is_a_plain_401() {
    let app = TestApp::new().await;
    app.give_password(ANA, "ana", PW).await;
    for (u, p) in [
        ("an\u{0}a", PW),
        ("\u{0}", PW),
        ("ana", "pass\u{0}word value"),
        ("ana\u{0}", PW),
    ] {
        let (s, v) = app.password_login(u, p).await;
        assert_eq!(s, StatusCode::UNAUTHORIZED, "{u:?} {p:?} {v}");
        assert_eq!(v["error"], "Username or password is wrong.");
    }
    // "an\0a" must not be read as "ana".
    assert_eq!(app.password_login("ana", PW).await.0, StatusCode::OK);
}

/// A Mac types "é" as e + accent, other systems as one letter. NIST asks for NFKC so the same
/// typed password works on every device.
#[tokio::test]
async fn the_same_typed_password_works_in_composed_and_decomposed_form() {
    let app = TestApp::new().await;
    let decomposed = "cafe\u{301} au lait chaud";
    let composed = "caf\u{e9} au lait chaud";
    app.give_password(ANA, "ana", decomposed).await;
    assert_eq!(app.password_login("ana", composed).await.0, StatusCode::OK);
    assert_eq!(
        app.password_login("ana", decomposed).await.0,
        StatusCode::OK
    );
    // Full-width letters fold to plain ones too (compatibility forms).
    app.give_password(BEN, "ben", "ＡＢＣ　ｘｙｚ　１２３")
        .await;
    assert_eq!(
        app.password_login("ben", "ABC xyz 123").await.0,
        StatusCode::OK
    );
    // A password that is only long because of combining marks is judged after folding.
    let long_raw = "e\u{301}".repeat(35) + &"e\u{300}".repeat(35); // 140 scalars, 70 after folding
    app.give_password(ANA, "ana", &long_raw).await;
    assert_eq!(
        app.password_login("ana", &("\u{e9}".repeat(35) + &"\u{e8}".repeat(35)))
            .await
            .0,
        StatusCode::OK
    );
}

/// Switching someone off and on again must not bring their old sessions back to life.
#[tokio::test]
async fn switching_a_person_off_and_on_ends_their_old_sessions() {
    let app = TestApp::new().await;
    let old = app.give_password(ANA, "ana", PW).await;
    let mgr = app.token_for(CORA, true);
    for active in [false, true] {
        let (s, v) = app
            .call(
                "PATCH",
                &format!("/api/persons/{ANA}"),
                Some(&mgr),
                Some(json!({ "active": active })),
            )
            .await;
        assert_eq!(s, StatusCode::OK, "{v}");
    }
    assert_eq!(
        app.call("GET", "/api/me", Some(&old), None).await.0,
        StatusCode::UNAUTHORIZED
    );
    // The password itself still works: they sign in again.
    assert_eq!(app.password_login("ana", PW).await.0, StatusCode::OK);
}

/// A ticket made before the manager had to choose a new password opens nothing afterwards.
#[tokio::test]
async fn an_event_ticket_does_not_work_for_someone_who_must_change_the_password() {
    let app = TestApp::new().await;
    let t = app.token_for(CORA, true);
    let (s, v) = app.call("POST", "/api/events/ticket", Some(&t), None).await;
    assert_eq!(s, StatusCode::OK);
    let ticket = v["ticket"].as_str().unwrap().to_string();
    app.sql(&format!(
        "update person set must_change_password = true where id = '{CORA}'"
    ))
    .await;
    let p = app
        .ensure_period(&app.token_for(BEN, true), "2026-02-01")
        .await;
    // An open stream never ends, so a good answer shows up as a timeout.
    let answer = tokio::time::timeout(
        std::time::Duration::from_secs(3),
        app.call(
            "GET",
            &format!("/api/events?ticket={ticket}&period_id={p}"),
            None,
            None,
        ),
    )
    .await;
    match answer {
        Ok((s, _)) => assert_eq!(s, StatusCode::UNAUTHORIZED),
        Err(_) => panic!("the stream was opened"),
    }
}
