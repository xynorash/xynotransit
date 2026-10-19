mod common;

use axum::http::StatusCode;
use common::*;
use serde_json::{json, Value};

async fn post_link(app: &TestApp, email: &str) -> (StatusCode, Value) {
    app.call(
        "POST",
        "/api/auth/magic-link",
        None,
        Some(json!({"email": email})),
    )
    .await
}

#[tokio::test]
async fn put_without_reporter_is_refused_and_with_reporter_is_stored_trimmed() {
    let app = TestApp::new().await;
    let ana = app.login("ana@example.org").await;
    let p = app.ensure_period(&ana, "2026-02-01").await;

    let mut body = ana_report();
    body.as_object_mut().unwrap().remove("reporter");
    let (s, v) = app.put_report(&ana, &p, A_ANA, body).await;
    assert_eq!(s, StatusCode::BAD_REQUEST, "{v}");
    assert_eq!(v["error"], "Enter your name.");
    assert_eq!(app.count("report").await, 0);

    let mut body = ana_report();
    body["reporter"] =
        json!({"name": "  Ana R.  ", "country": " Madagascar", "role": "Import lead "});
    let (s, v) = app.put_report(&ana, &p, A_ANA, body).await;
    assert_eq!(s, StatusCode::OK, "{v}");
    let want = json!({"name": "Ana R.", "country": "Madagascar", "role": "Import lead"});
    assert_eq!(v["reporter"], want);
    let (s, v) = app
        .call(
            "GET",
            &format!("/api/periods/{p}/reports/{A_ANA}"),
            Some(&ana),
            None,
        )
        .await;
    assert_eq!(s, StatusCode::OK);
    assert_eq!(v["reporter"], want);

    // Sending again replaces the words.
    let mut body = ana_report();
    body["reporter"] = json!({"name": "Ana", "country": "Mali", "role": "Boss"});
    let (_, v) = app.put_report(&ana, &p, A_ANA, body).await;
    assert_eq!(v["reporter"]["country"], "Mali");
    assert_eq!(app.count("report").await, 1);
}

#[tokio::test]
async fn deck_uses_reporter_words_and_legacy_rows_use_the_profile() {
    let app = TestApp::new().await;
    let ana = app.login("ana@example.org").await;
    let ben = app.login("ben@example.org").await;
    let cora = app.login("cora@example.org").await;
    let p = app.ensure_period(&cora, "2026-02-01").await;

    let mut body = ana_report();
    body["reporter"] = json!({"name": "Ana R.", "country": "Madagascar", "role": "Import lead"});
    assert_eq!(
        app.put_report(&ana, &p, A_ANA, body).await.0,
        StatusCode::OK
    );
    assert_eq!(
        app.put_report(&ben, &p, A_BEN, ben_report()).await.0,
        StatusCode::OK
    );
    // Ben's row is a legacy one: no reporter words.
    app.sql(
        "update report set reporter_name = null, reporter_country = null, reporter_role = null
         where assignment_id = '00000000-0000-0000-0000-0000000000d2'",
    )
    .await;
    let (_, v) = app
        .call(
            "GET",
            &format!("/api/periods/{p}/reports/{A_BEN}"),
            Some(&ben),
            None,
        )
        .await;
    assert_eq!(v["reporter"], Value::Null);

    let (s, deck) = app
        .call("POST", &format!("/api/periods/{p}/deck"), Some(&cora), None)
        .await;
    assert_eq!(s, StatusCode::CREATED, "{deck}");
    let items = deck["items"].as_array().unwrap();
    assert_eq!(items.len(), 2);
    // Deck order: ben (Tana 1) then ana (Tana 2).
    let ben_snap = &items[0]["snapshot"];
    assert_eq!(ben_snap["name"], "Ben Rabe");
    assert_eq!(ben_snap["role"], "Export");
    assert_eq!(ben_snap["team"], "Tana");
    let ana_snap = &items[1]["snapshot"];
    assert_eq!(ana_snap["name"], "Ana R.");
    assert_eq!(ana_snap["role"], "Import lead");
    assert_eq!(ana_snap["team"], "Madagascar");
}

#[tokio::test]
async fn deck_with_zero_reports_is_cover_and_suggestions_only() {
    let app = TestApp::new().await;
    let cora = app.login("cora@example.org").await;
    let p = app.ensure_period(&cora, "2026-02-01").await;
    let (s, deck) = app
        .call("POST", &format!("/api/periods/{p}/deck"), Some(&cora), None)
        .await;
    assert_eq!(s, StatusCode::CREATED, "{deck}");
    assert_eq!(deck["items"], json!([]));
    assert_eq!(deck["included_count"], 0);
    assert_eq!(deck["expected_count"], 3);
    let (s, latest) = app
        .call("GET", &format!("/api/periods/{p}/deck"), Some(&cora), None)
        .await;
    assert_eq!(s, StatusCode::OK);
    assert_eq!(latest["id"], deck["id"]);
}

#[tokio::test]
async fn deck_with_some_reports_counts_expected_and_included() {
    let app = TestApp::new().await;
    let ana = app.login("ana@example.org").await;
    let cora = app.login("cora@example.org").await;
    let p = app.ensure_period(&cora, "2026-02-01").await;
    assert_eq!(
        app.put_report(&ana, &p, A_ANA, ana_report()).await.0,
        StatusCode::OK
    );
    let (s, deck) = app
        .call("POST", &format!("/api/periods/{p}/deck"), Some(&cora), None)
        .await;
    assert_eq!(s, StatusCode::CREATED, "{deck}");
    assert_eq!(deck["included_count"], 1);
    assert_eq!(deck["expected_count"], 3);
}

#[tokio::test]
async fn deck_text_is_readable_by_an_employee_but_only_the_controller_writes() {
    let app = TestApp::new().await;
    let ana = app.login("ana@example.org").await;
    let p = app.ensure_period(&ana, "2026-02-01").await;
    let uri = format!("/api/periods/{p}/deck-text");
    let (s, v) = app.call("GET", &uri, Some(&ana), None).await;
    assert_eq!(s, StatusCode::OK, "{v}");
    assert!(v["settings"].is_object());
    let (s, _) = app
        .call("PUT", &uri, Some(&ana), Some(json!({"settings": {}})))
        .await;
    assert_eq!(s, StatusCode::FORBIDDEN);
    let (s, _) = app.call("GET", &uri, None, None).await;
    assert_eq!(s, StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn rate_limit_is_identical_for_known_and_unknown_addresses() {
    let app = TestApp::new().await;
    for email in ["ana@example.org", "nobody@example.org"] {
        for i in 1..=5 {
            let (s, v) = post_link(&app, email).await;
            assert_eq!(s, StatusCode::ACCEPTED, "{email} #{i}");
            assert_eq!(v, json!({}));
        }
        let (s, v) = post_link(&app, &format!(" {} ", email.to_uppercase())).await;
        assert_eq!(s, StatusCode::TOO_MANY_REQUESTS, "{email}");
        assert_eq!(v["error"], "Too many links requested. Try again later.");
    }
    // Only the known address got mail and tokens.
    assert_eq!(app.state.mailer.sent().len(), 5);
    assert_eq!(app.count("login_token").await, 5);
    assert_eq!(app.count("login_attempt").await, 10);
    // Another address is not affected.
    assert_eq!(
        post_link(&app, "ben@example.org").await.0,
        StatusCode::ACCEPTED
    );
}
