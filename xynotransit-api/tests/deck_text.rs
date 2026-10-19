mod common;

use axum::http::StatusCode;
use common::TestApp;
use serde_json::{json, Value};

fn defaults() -> Value {
    let v: Value = serde_json::from_str(include_str!("fixtures/deck_text_defaults.json")).unwrap();
    let mut m = serde_json::Map::new();
    for f in v["fields"].as_array().unwrap() {
        m.insert(f["key"].as_str().unwrap().into(), f["default"].clone());
    }
    Value::Object(m)
}

fn uri(p: &str) -> String {
    format!("/api/periods/{p}/deck-text")
}

#[tokio::test]
async fn everyone_reads_only_the_controller_writes_and_unknown_periods_are_404() {
    let app = TestApp::new().await;
    let ana = app.login("ana@example.org").await;
    let cora = app.login("cora@example.org").await;
    let p = app.ensure_period(&ana, "2026-02-01").await;

    // An employee reads the words (live preview) but cannot change them.
    let (s, v) = app.call("GET", &uri(&p), Some(&ana), None).await;
    assert_eq!(s, StatusCode::OK, "{v}");
    assert_eq!(v["inherited_from"], "defaults");

    for method in ["GET", "PUT"] {
        let body = (method == "PUT").then(|| json!({"settings": {}}));
        if method == "PUT" {
            let (s, v) = app.call(method, &uri(&p), Some(&ana), body.clone()).await;
            assert_eq!(s, StatusCode::FORBIDDEN);
            assert_eq!(v["error"], "Only the controller can do this.");
        }
        let (s, _) = app.call(method, &uri(&p), None, body.clone()).await;
        assert_eq!(s, StatusCode::UNAUTHORIZED);
        let missing = uri("00000000-0000-0000-0000-00000000ffff");
        let (s, v) = app.call(method, &missing, Some(&cora), body.clone()).await;
        assert_eq!(s, StatusCode::NOT_FOUND, "{v}");
        let (s, _) = app.call(method, &uri("nope"), Some(&cora), body).await;
        assert_eq!(s, StatusCode::NOT_FOUND);
    }
    let (s, _) = app
        .call("POST", &format!("/api/periods/{p}/deck"), Some(&ana), None)
        .await;
    assert_eq!(s, StatusCode::FORBIDDEN);
}

#[tokio::test]
async fn defaults_then_put_then_inheritance_across_three_periods() {
    let app = TestApp::new().await;
    let cora = app.login("cora@example.org").await;
    let feb = app.ensure_period(&cora, "2026-02-01").await;
    let may = app.ensure_period(&cora, "2026-05-01").await;
    let aug = app.ensure_period(&cora, "2026-08-01").await;
    let jan = app.ensure_period(&cora, "2026-01-01").await;

    let (s, v) = app.call("GET", &uri(&feb), Some(&cora), None).await;
    assert_eq!(s, StatusCode::OK);
    assert_eq!(v["settings"], defaults());
    assert_eq!(v["inherited_from"], "defaults");
    assert!(v["updated_at"].is_null());

    // Feb gets its own words; a partial object takes defaults for the rest and is trimmed.
    let (s, v) = app
        .call(
            "PUT",
            &uri(&feb),
            Some(&cora),
            Some(json!({"settings": {"title": "  February Review  ", "dateText": "Soon"}})),
        )
        .await;
    assert_eq!(s, StatusCode::OK, "{v}");
    assert_eq!(v["settings"]["title"], "February Review");
    assert_eq!(v["settings"]["dateText"], "Soon");
    assert_eq!(v["settings"]["footer"], defaults()["footer"]);
    assert!(v["inherited_from"].is_null());
    assert!(v["updated_at"].is_string());
    assert_eq!(app.count("deck_text").await, 1);

    // May and Aug inherit Feb. Jan (earlier) still has the defaults.
    for p in [&may, &aug] {
        let (_, v) = app.call("GET", &uri(p), Some(&cora), None).await;
        assert_eq!(v["settings"]["title"], "February Review");
        assert_eq!(v["inherited_from"], "Feb to Apr 2026");
        assert!(v["updated_at"].is_null());
    }
    let (_, v) = app.call("GET", &uri(&jan), Some(&cora), None).await;
    assert_eq!(v["settings"], defaults());
    assert_eq!(v["inherited_from"], "defaults");

    // May writes its own; Aug now inherits May (the latest earlier), May reports no inheritance.
    app.call(
        "PUT",
        &uri(&may),
        Some(&cora),
        Some(json!({"settings": {"title": "May Review"}})),
    )
    .await;
    let (_, v) = app.call("GET", &uri(&aug), Some(&cora), None).await;
    assert_eq!(v["settings"]["title"], "May Review");
    assert_eq!(v["inherited_from"], "May to Jul 2026");
    let (_, v) = app.call("GET", &uri(&may), Some(&cora), None).await;
    assert!(v["inherited_from"].is_null());
    // Feb is not touched by a later period's words.
    let (_, v) = app.call("GET", &uri(&feb), Some(&cora), None).await;
    assert_eq!(v["settings"]["title"], "February Review");

    // A second PUT replaces the whole object (missing keys go back to defaults).
    let (_, v) = app
        .call(
            "PUT",
            &uri(&feb),
            Some(&cora),
            Some(json!({"settings": {"footer": "F {period}"}})),
        )
        .await;
    assert_eq!(v["settings"]["title"], defaults()["title"]);
    assert_eq!(v["settings"]["footer"], "F {period}");
    assert_eq!(app.count("deck_text").await, 2);
}

#[tokio::test]
async fn validation_messages_over_http() {
    let app = TestApp::new().await;
    let cora = app.login("cora@example.org").await;
    let p = app.ensure_period(&cora, "2026-02-01").await;
    let long = "x".repeat(81);
    let cases = [
        (json!({"title": "   "}), "Meeting title cannot be empty."),
        (
            json!({"title": long}),
            "Meeting title can be at most 80 characters.",
        ),
        (
            json!({"title": "{name}"}),
            "{name} cannot be used in Meeting title. It allows {period}.",
        ),
        (
            json!({"orgName": "{org}"}),
            "{org} cannot be used in Organisation name. It allows no placeholders.",
        ),
        (
            json!({"kpiBadge": "{met} {team}"}),
            "{team} cannot be used in KPI slide, badge. It allows {met}, {total}.",
        ),
        (
            json!({"title": "a\u{200b}b"}),
            "Use plain text in Meeting title.",
        ),
        (json!({"title": "a\nb"}), "Use plain text in Meeting title."),
        (json!({"title": 5}), "Meeting title must be text."),
        (json!({"bogus": "x"}), "bogus is not a text setting."),
    ];
    for (settings, want) in cases {
        let (s, v) = app
            .call(
                "PUT",
                &uri(&p),
                Some(&cora),
                Some(json!({"settings": settings})),
            )
            .await;
        assert_eq!(s, StatusCode::BAD_REQUEST, "{settings}");
        assert_eq!(v["error"], want);
    }
    // Empty is fine where allowed; unicode counts characters.
    let ok = json!({"settings": {
        "dateText": "", "suggestionsBody": "", "title": "é".repeat(80),
    }});
    let (s, v) = app.call("PUT", &uri(&p), Some(&cora), Some(ok)).await;
    assert_eq!(s, StatusCode::OK, "{v}");
    // Not an object / no settings.
    for body in [json!({}), json!({"settings": 3}), json!([1])] {
        let (s, _) = app.call("PUT", &uri(&p), Some(&cora), Some(body)).await;
        assert_eq!(s, StatusCode::BAD_REQUEST);
    }
    assert_eq!(app.count("deck_text").await, 1);
}

#[tokio::test]
async fn decks_freeze_their_words_and_old_decks_keep_them() {
    let app = TestApp::new().await;
    let cora = app.login("cora@example.org").await;
    let p = app.ensure_period(&cora, "2026-02-01").await;
    let later = app.ensure_period(&cora, "2026-05-01").await;
    let deck_uri = format!("/api/periods/{p}/deck");

    // First deck: defaults.
    let (s, d1) = app.call("POST", &deck_uri, Some(&cora), None).await;
    assert_eq!(s, StatusCode::CREATED, "{d1}");
    assert_eq!(d1["texts"], defaults());

    let put = |title: &str| json!({"settings": {"title": title, "suggestionsBody": "Ideas later"}});
    app.call("PUT", &uri(&p), Some(&cora), Some(put("Second words")))
        .await;
    let (_, d2) = app.call("POST", &deck_uri, Some(&cora), None).await;
    assert_eq!(d2["texts"]["title"], "Second words");
    assert_eq!(d2["texts"]["suggestionsBody"], "Ideas later");

    app.call("PUT", &uri(&p), Some(&cora), Some(put("Third words")))
        .await;
    // The latest deck is still the second, with its own words.
    let (_, latest) = app.call("GET", &deck_uri, Some(&cora), None).await;
    assert_eq!(latest["id"], d2["id"]);
    assert_eq!(latest["texts"]["title"], "Second words");
    // The very first deck, read from the table, still has the defaults.
    let first: Value = sqlx::query_scalar("select texts from deck_run where id = $1::uuid")
        .bind(d1["id"].as_str().unwrap())
        .fetch_one(&app.state.pool)
        .await
        .unwrap();
    assert_eq!(first, defaults());

    // A later period with no words of its own freezes the inherited ones.
    let (_, d3) = app
        .call(
            "POST",
            &format!("/api/periods/{later}/deck"),
            Some(&cora),
            None,
        )
        .await;
    assert_eq!(d3["texts"]["title"], "Third words");

    // Old decks made before the feature have '{}' and read as the defaults. Decks are frozen
    // (06-integrity.sql), so the test plays the part of the old database with the trigger off.
    app.sql("alter table deck_run disable trigger deck_run_frozen")
        .await;
    sqlx::query("update deck_run set texts = '{}'::jsonb where id = $1::uuid")
        .bind(d2["id"].as_str().unwrap())
        .execute(&app.state.pool)
        .await
        .unwrap();
    let (_, latest) = app.call("GET", &deck_uri, Some(&cora), None).await;
    assert_eq!(latest["id"], d2["id"]);
    assert_eq!(latest["texts"], defaults());
}
