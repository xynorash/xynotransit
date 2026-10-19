mod common;

use std::time::Duration;

use axum::http::StatusCode;
use common::*;
use http_body_util::BodyExt;
use serde_json::{json, Value};
use tower::ServiceExt;
use xynotransit_api::{auth::hash_token, listener};

fn token_of(link: &str) -> String {
    link.split("token=").nth(1).unwrap().to_string()
}

// ---------- health and auth plumbing ----------

#[tokio::test]
async fn health_is_open_and_checks_the_database() {
    let app = TestApp::new().await;
    let (s, v) = app.call("GET", "/api/health", None, None).await;
    assert_eq!(s, StatusCode::OK);
    // Deliberately improved: it also says what it checked (see tests/ops.rs for the 503).
    assert_eq!(v, json!({"ok": true, "db": "up"}));
}

#[tokio::test]
async fn everything_else_needs_a_signed_in_person() {
    let app = TestApp::new().await;
    let p = "00000000-0000-0000-0000-000000000001";
    let calls: Vec<(&str, String)> = vec![
        ("GET", "/api/me".into()),
        ("GET", "/api/catalog".into()),
        ("POST", "/api/periods/ensure".into()),
        ("PATCH", format!("/api/periods/{p}")),
        ("GET", format!("/api/periods/{p}/reports")),
        ("GET", format!("/api/periods/{p}/reports/{A_ANA}")),
        ("PUT", format!("/api/periods/{p}/reports/{A_ANA}")),
        ("GET", format!("/api/periods/{p}/deck")),
        ("POST", format!("/api/periods/{p}/deck")),
        ("POST", "/api/events/ticket".into()),
    ];
    for (m, uri) in calls {
        let (s, v) = app.call(m, &uri, None, Some(json!({}))).await;
        assert_eq!(s, StatusCode::UNAUTHORIZED, "{m} {uri}");
        assert!(v["error"].as_str().unwrap().contains("sign in"));
        let (s, _) = app.call(m, &uri, Some("not.a.jwt"), Some(json!({}))).await;
        assert_eq!(s, StatusCode::UNAUTHORIZED, "{m} {uri} bad token");
    }
}

#[tokio::test]
async fn unknown_paths_and_bad_json_use_the_error_shape() {
    let app = TestApp::new().await;
    let (s, v) = app.call("GET", "/api/nope", None, None).await;
    assert_eq!(s, StatusCode::NOT_FOUND);
    assert!(v["error"].is_string());
    let (s, bytes) = app
        .raw(
            "POST",
            "/api/auth/magic-link",
            None,
            Some(b"{not json".to_vec()),
        )
        .await;
    assert_eq!(s, StatusCode::BAD_REQUEST);
    let v: Value = serde_json::from_slice(&bytes).unwrap();
    assert_eq!(v["error"], "That request is not valid.");
    let (s, v) = app
        .call(
            "POST",
            "/api/auth/magic-link",
            None,
            Some(json!({"email": "nonsense"})),
        )
        .await;
    assert_eq!(s, StatusCode::BAD_REQUEST);
    assert_eq!(v["error"], "Enter a valid email address.");
}

#[tokio::test]
async fn large_bodies_are_refused() {
    let app = TestApp::new().await;
    let big = format!(r#"{{"email":"{}"}}"#, "a".repeat(300 * 1024));
    let (s, bytes) = app
        .raw("POST", "/api/auth/magic-link", None, Some(big.into_bytes()))
        .await;
    assert_eq!(s, StatusCode::PAYLOAD_TOO_LARGE);
    let v: Value = serde_json::from_slice(&bytes).unwrap();
    assert!(v["error"].is_string());
}

// ---------- magic link ----------

#[tokio::test]
async fn magic_link_unknown_and_inactive_emails_get_the_same_answer() {
    let app = TestApp::new().await;
    for email in ["nobody@example.org", "dan@example.org"] {
        let (s, v) = app
            .call(
                "POST",
                "/api/auth/magic-link",
                None,
                Some(json!({"email": email})),
            )
            .await;
        assert_eq!(s, StatusCode::ACCEPTED);
        assert_eq!(v, json!({}));
    }
    assert!(app.state.mailer.sent().is_empty());
    assert_eq!(app.count("login_token").await, 0);
}

#[tokio::test]
async fn magic_link_flow_is_single_use_and_stores_only_a_hash() {
    let app = TestApp::new().await;
    let (s, v) = app
        .call(
            "POST",
            "/api/auth/magic-link",
            None,
            Some(json!({"email": "  Ana@Example.ORG "})),
        )
        .await;
    assert_eq!((s, v), (StatusCode::ACCEPTED, json!({})));

    let sent = app.state.mailer.sent();
    assert_eq!(sent.len(), 1);
    assert_eq!(sent[0].to, "ana@example.org");
    assert!(sent[0]
        .link
        .starts_with("http://127.0.0.1:8080/auth/verify?token="));
    let token = token_of(&sent[0].link);

    // Only the SHA-256 is stored.
    let hash: Vec<u8> = sqlx::query_scalar("select token_hash from login_token")
        .fetch_one(&app.state.pool)
        .await
        .unwrap();
    assert_eq!(hash, hash_token(&token));
    assert_ne!(hash, token.as_bytes());

    let (s, v) = app
        .call(
            "POST",
            "/api/auth/verify",
            None,
            Some(json!({"token": token})),
        )
        .await;
    assert_eq!(s, StatusCode::OK);
    assert_eq!(v["user"]["person_id"], ANA);
    assert_eq!(v["user"]["role"], "contributor");
    assert_eq!(v["user"]["label"], "Ana Rakoto");
    assert!(v["expires_at"].as_str().unwrap().ends_with('Z'));
    assert!(v["access_token"].as_str().unwrap().split('.').count() == 3);

    let (s, v) = app
        .call(
            "POST",
            "/api/auth/verify",
            None,
            Some(json!({"token": token})),
        )
        .await;
    assert_eq!(s, StatusCode::UNAUTHORIZED);
    assert_eq!(
        v["error"],
        "This link has expired or was already used. Ask for a new one."
    );

    let (s, _) = app
        .call(
            "POST",
            "/api/auth/verify",
            None,
            Some(json!({"token": "made-up"})),
        )
        .await;
    assert_eq!(s, StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn concurrent_verify_lets_only_one_through() {
    let app = TestApp::new().await;
    app.call(
        "POST",
        "/api/auth/magic-link",
        None,
        Some(json!({"email": "ana@example.org"})),
    )
    .await;
    let token = token_of(&app.state.mailer.sent()[0].link);
    let calls = (0..6).map(|_| {
        app.call(
            "POST",
            "/api/auth/verify",
            None,
            Some(json!({"token": token})),
        )
    });
    let results = futures_util::future::join_all(calls).await;
    let ok = results.iter().filter(|r| r.0 == StatusCode::OK).count();
    assert_eq!(ok, 1);
}

#[tokio::test]
async fn expired_link_is_refused() {
    let app = TestApp::new().await;
    app.call(
        "POST",
        "/api/auth/magic-link",
        None,
        Some(json!({"email": "ana@example.org"})),
    )
    .await;
    let token = token_of(&app.state.mailer.sent()[0].link);
    // A fresh link lives 15 minutes.
    let mins: f64 = sqlx::query_scalar(
        "select extract(epoch from (expires_at - created_at))::float8 / 60 from login_token",
    )
    .fetch_one(&app.state.pool)
    .await
    .unwrap();
    assert!((mins - 15.0).abs() < 0.1, "{mins}");
    app.sql("update login_token set expires_at = now() - interval '1 minute'")
        .await;
    let (s, v) = app
        .call(
            "POST",
            "/api/auth/verify",
            None,
            Some(json!({"token": token})),
        )
        .await;
    assert_eq!(s, StatusCode::UNAUTHORIZED);
    assert!(v["error"].as_str().unwrap().contains("expired"));
}

#[tokio::test]
async fn sixth_link_in_an_hour_is_rate_limited() {
    let app = TestApp::new().await;
    for _ in 0..5 {
        let (s, _) = app
            .call(
                "POST",
                "/api/auth/magic-link",
                None,
                Some(json!({"email": "ana@example.org"})),
            )
            .await;
        assert_eq!(s, StatusCode::ACCEPTED);
    }
    let (s, v) = app
        .call(
            "POST",
            "/api/auth/magic-link",
            None,
            Some(json!({"email": "ana@example.org"})),
        )
        .await;
    assert_eq!(s, StatusCode::TOO_MANY_REQUESTS);
    assert_eq!(v["error"], "Too many links requested. Try again later.");
    assert_eq!(app.state.mailer.sent().len(), 5);
    // Someone else is not affected, and old rows fall out of the window.
    let (s, _) = app
        .call(
            "POST",
            "/api/auth/magic-link",
            None,
            Some(json!({"email": "ben@example.org"})),
        )
        .await;
    assert_eq!(s, StatusCode::ACCEPTED);
    app.sql(
        "update login_attempt set at = now() - interval '2 hours' where email = 'ana@example.org'",
    )
    .await;
    let (s, _) = app
        .call(
            "POST",
            "/api/auth/magic-link",
            None,
            Some(json!({"email": "ana@example.org"})),
        )
        .await;
    assert_eq!(s, StatusCode::ACCEPTED);
}

#[tokio::test]
async fn me_and_role_changes_take_effect_at_once() {
    let app = TestApp::new().await;
    let cora = app.login("cora@example.org").await;
    let (s, v) = app.call("GET", "/api/me", Some(&cora), None).await;
    assert_eq!(s, StatusCode::OK);
    assert_eq!(
        v,
        json!({"person_id": CORA, "role": "controller", "label": "Cora Boss"})
    );

    let period = app.ensure_period(&cora, "2026-02-01").await;
    let (s, _) = app
        .call(
            "PATCH",
            &format!("/api/periods/{period}"),
            Some(&cora),
            Some(json!({"meeting_date": "2026-05-12"})),
        )
        .await;
    assert_eq!(s, StatusCode::OK);

    // Demote: the same token now acts as a contributor.
    app.sql("update person set app_role = 'contributor' where id = '00000000-0000-0000-0000-0000000000a3'").await;
    let (_, v) = app.call("GET", "/api/me", Some(&cora), None).await;
    assert_eq!(v["role"], "contributor");
    let (s, v) = app
        .call(
            "PATCH",
            &format!("/api/periods/{period}"),
            Some(&cora),
            Some(json!({"meeting_date": null})),
        )
        .await;
    assert_eq!(s, StatusCode::FORBIDDEN);
    assert_eq!(v["error"], "Only the controller can do this.");
    let (s, _) = app
        .call(
            "POST",
            &format!("/api/periods/{period}/deck"),
            Some(&cora),
            None,
        )
        .await;
    assert_eq!(s, StatusCode::FORBIDDEN);

    // Deactivate: the token stops working.
    app.sql("update person set active = false where id = '00000000-0000-0000-0000-0000000000a3'")
        .await;
    let (s, _) = app.call("GET", "/api/me", Some(&cora), None).await;
    assert_eq!(s, StatusCode::UNAUTHORIZED);
}

// ---------- catalog and periods ----------

#[tokio::test]
async fn catalog_has_the_agreed_shape() {
    let app = TestApp::new().await;
    let t = app.login("ana@example.org").await;
    let (s, v) = app.call("GET", "/api/catalog", Some(&t), None).await;
    assert_eq!(s, StatusCode::OK);

    assert_eq!(
        v["teams"],
        json!([
            {"id": "1", "code": "tana", "name": "Tana", "sort": 1},
            {"id": "2", "code": "abe", "name": "Antsirabe", "sort": 2},
        ])
    );

    let persons = v["persons"].as_array().unwrap();
    assert_eq!(persons.len(), 3, "inactive person is left out");
    let ana = persons.iter().find(|p| p["id"] == ANA).unwrap();
    assert_eq!(ana["full_name"], "Ana Rakoto");
    assert_eq!(ana["email"], "ana@example.org");
    assert_eq!(ana["app_role"], "contributor");

    let codes: Vec<&str> = v["assignments"]
        .as_array()
        .unwrap()
        .iter()
        .map(|a| a["code"].as_str().unwrap())
        .collect();
    assert_eq!(codes, ["ben-export", "ana-import", "cora-ops"]);

    let a = &v["assignments"][1];
    assert_eq!(a["id"], A_ANA);
    assert_eq!(a["person_id"], ANA);
    assert_eq!(a["team_id"], "1");
    assert_eq!(a["role_title"], "Import");
    assert_eq!(a["sort"], 2);
    assert_eq!(
        a["metrics"],
        json!([
            {"id": M_FILES, "key": "files", "label": "Files", "series": 0},
            {"id": M_CALLS, "key": "calls", "label": "Calls", "series": 1},
        ])
    );
    assert_eq!(
        a["kpis"],
        json!([
            {"id": K_ONTIME, "sort": 1, "text": "On time"},
            {"id": K_NOERR, "sort": 2, "text": "No errors"},
        ])
    );
    assert_eq!(v["assignments"][2]["metrics"], json!([]));

    assert!(v.get("suggestions").is_none(), "note suggestions are gone");
    assert_eq!(a["active"], true);
    assert_eq!(
        persons.iter().find(|p| p["id"] == ANA).unwrap()["active"],
        true
    );
}

#[tokio::test]
async fn ensure_period_is_idempotent_and_normalises() {
    let app = TestApp::new().await;
    let t = app.login("ana@example.org").await;
    let (s, a) = app
        .call(
            "POST",
            "/api/periods/ensure",
            Some(&t),
            Some(json!({"start_month": "2026-02-17"})),
        )
        .await;
    assert_eq!(s, StatusCode::OK);
    assert_eq!(a["start_month"], "2026-02-01");
    assert_eq!(a["status"], "open");
    assert_eq!(a["meeting_date"], Value::Null);
    let (_, b) = app
        .call(
            "POST",
            "/api/periods/ensure",
            Some(&t),
            Some(json!({"start_month": "2026-02-01"})),
        )
        .await;
    assert_eq!(a["id"], b["id"]);
    assert_eq!(app.count("period").await, 1);

    let (s, v) = app
        .call(
            "POST",
            "/api/periods/ensure",
            Some(&t),
            Some(json!({"start_month": "soon"})),
        )
        .await;
    assert_eq!(s, StatusCode::BAD_REQUEST);
    assert!(v["error"].is_string());
}

#[tokio::test]
async fn meeting_date_can_be_set_and_cleared_by_the_controller_only() {
    let app = TestApp::new().await;
    let ana = app.login("ana@example.org").await;
    let cora = app.login("cora@example.org").await;
    let period = app.ensure_period(&ana, "2026-02-01").await;
    let uri = format!("/api/periods/{period}");

    let (s, v) = app
        .call(
            "PATCH",
            &uri,
            Some(&ana),
            Some(json!({"meeting_date": "2026-05-12"})),
        )
        .await;
    assert_eq!(
        (s, v["error"].as_str()),
        (
            StatusCode::FORBIDDEN,
            Some("Only the controller can do this.")
        )
    );

    let (s, v) = app
        .call(
            "PATCH",
            &uri,
            Some(&cora),
            Some(json!({"meeting_date": "2026-05-12"})),
        )
        .await;
    assert_eq!(s, StatusCode::OK);
    assert_eq!(v["meeting_date"], "2026-05-12");
    let (_, v) = app
        .call(
            "PATCH",
            &uri,
            Some(&cora),
            Some(json!({"meeting_date": null})),
        )
        .await;
    assert_eq!(v["meeting_date"], Value::Null);
    let (s, _) = app
        .call(
            "PATCH",
            &uri,
            Some(&cora),
            Some(json!({"meeting_date": "tomorrow"})),
        )
        .await;
    assert_eq!(s, StatusCode::BAD_REQUEST);
    let (s, _) = app
        .call(
            "PATCH",
            "/api/periods/00000000-0000-0000-0000-000000000009",
            Some(&cora),
            Some(json!({"meeting_date": null})),
        )
        .await;
    assert_eq!(s, StatusCode::NOT_FOUND);
}

// ---------- reports ----------

#[tokio::test]
async fn sending_a_report_happy_path() {
    let app = TestApp::new().await;
    let ana = app.login("ana@example.org").await;
    let cora = app.login("cora@example.org").await;
    let period = app.ensure_period(&ana, "2026-02-01").await;

    let (s, v) = app
        .call(
            "GET",
            &format!("/api/periods/{period}/reports/{A_ANA}"),
            Some(&ana),
            None,
        )
        .await;
    assert_eq!(s, StatusCode::NOT_FOUND);
    let (_, list) = app
        .call(
            "GET",
            &format!("/api/periods/{period}/reports"),
            Some(&cora),
            None,
        )
        .await;
    assert_eq!(list, json!([]));
    let _ = v;

    let (s, r) = app.put_report(&ana, &period, A_ANA, ana_report()).await;
    assert_eq!(s, StatusCode::OK, "{r}");
    assert_eq!(r["status"], "submitted");
    assert_eq!(r["period_id"], period);
    assert_eq!(r["assignment_id"], A_ANA);
    assert!(r["submitted_at"].is_string());
    assert_eq!(r["values"].as_array().unwrap().len(), 6);
    assert!(r["values"]
        .as_array()
        .unwrap()
        .contains(&json!({"metric_def_id": M_FILES, "month_offset": 2, "value": 12})));
    assert_eq!(r["kpis"].as_array().unwrap().len(), 2);
    assert!(r["kpis"]
        .as_array()
        .unwrap()
        .contains(&json!({"kpi_def_id": K_NOERR, "status": "partly", "comment": "two slips"})));
    assert_eq!(
        r["notes"],
        json!([
            {"kind": "well", "position": 1, "text": "First good thing"},
            {"kind": "well", "position": 2, "text": "Second good thing"},
            {"kind": "next", "position": 1, "text": "Hire one more"},
        ])
    );

    // The owner and the controller can read it; the controller can list all.
    for t in [&ana, &cora] {
        let (s, one) = app
            .call(
                "GET",
                &format!("/api/periods/{period}/reports/{A_ANA}"),
                Some(t),
                None,
            )
            .await;
        assert_eq!(s, StatusCode::OK);
        assert_eq!(one["id"], r["id"]);
    }
    let (_, list) = app
        .call(
            "GET",
            &format!("/api/periods/{period}/reports"),
            Some(&cora),
            None,
        )
        .await;
    assert_eq!(list.as_array().unwrap().len(), 1);
    let (s, _) = app
        .call(
            "GET",
            "/api/periods/00000000-0000-0000-0000-000000000009/reports",
            Some(&cora),
            None,
        )
        .await;
    assert_eq!(s, StatusCode::NOT_FOUND);
    let (s, _) = app
        .call("GET", "/api/periods/not-a-uuid/reports", Some(&cora), None)
        .await;
    assert_eq!(s, StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn sending_again_replaces_and_never_duplicates() {
    let app = TestApp::new().await;
    let ana = app.login("ana@example.org").await;
    let period = app.ensure_period(&ana, "2026-02-01").await;
    let (_, first) = app.put_report(&ana, &period, A_ANA, ana_report()).await;
    assert_eq!(
        (
            app.count("report").await,
            app.count("report_metric_value").await,
            app.count("report_kpi_result").await,
            app.count("report_note").await
        ),
        (1, 6, 2, 3)
    );

    let mut body = ana_report();
    body["values"][0]["value"] = json!(99);
    body["notes"] = json!([{"kind": "wrong", "position": 3, "text": "Only this"}]);
    body["kpis"][0]["status"] = json!("missed");
    let (s, second) = app.put_report(&ana, &period, A_ANA, body).await;
    assert_eq!(s, StatusCode::OK);
    assert_eq!(first["id"], second["id"]);
    assert_eq!(
        (
            app.count("report").await,
            app.count("report_metric_value").await,
            app.count("report_kpi_result").await,
            app.count("report_note").await
        ),
        (1, 6, 2, 1)
    );
    assert!(second["values"]
        .as_array()
        .unwrap()
        .contains(&json!({"metric_def_id": M_FILES, "month_offset": 0, "value": 99})));
    assert_eq!(
        second["notes"],
        json!([{"kind": "wrong", "position": 3, "text": "Only this"}])
    );
    assert_eq!(second["status"], "submitted");
}

#[tokio::test]
async fn every_validation_problem_is_said_in_plain_words() {
    let app = TestApp::new().await;
    let ana = app.login("ana@example.org").await;
    let period = app.ensure_period(&ana, "2026-02-01").await;

    async fn expect(app: &TestApp, t: &str, p: &str, body: Value, msg: &str) {
        let (s, v) = app.put_report(t, p, A_ANA, body).await;
        assert_eq!(s, StatusCode::BAD_REQUEST, "{v}");
        assert_eq!(v["error"], msg);
    }

    // Nothing sent.
    expect(
        &app,
        &ana,
        &period,
        json!({"values": [], "kpis": [], "notes": []}),
        "Enter your name.",
    )
    .await;
    let mut b = ana_report();
    b["reporter"]["country"] = json!("  ");
    expect(&app, &ana, &period, b, "Enter your country.").await;
    let mut b = ana_report();
    b["reporter"]["role"] = json!("r".repeat(81));
    expect(
        &app,
        &ana,
        &period,
        b,
        "Your role can be at most 80 characters.",
    )
    .await;
    let mut b = ana_report();
    b["values"] = json!([]);
    b["kpis"] = json!([]);
    expect(
        &app,
        &ana,
        &period,
        b,
        "Enter a number for \"Files\" in February.",
    )
    .await;

    // Second metric missing its third month (March start shows the real month name).
    let mut b = ana_report();
    b["values"].as_array_mut().unwrap().pop();
    expect(
        &app,
        &ana,
        &period,
        b,
        "Enter a number for \"Calls\" in April.",
    )
    .await;

    // Negative counts as missing.
    let mut b = ana_report();
    b["values"][1]["value"] = json!(-4);
    expect(
        &app,
        &ana,
        &period,
        b,
        "Enter a number for \"Files\" in March.",
    )
    .await;

    // Targets left.
    let mut b = ana_report();
    b["kpis"].as_array_mut().unwrap().pop();
    expect(
        &app,
        &ana,
        &period,
        b,
        "Answer all targets in step 3 (1 left).",
    )
    .await;
    let mut b = ana_report();
    b["kpis"] = json!([]);
    expect(
        &app,
        &ana,
        &period,
        b,
        "Answer all targets in step 3 (2 left).",
    )
    .await;

    // Notes.
    let mut b = ana_report();
    b["notes"] = json!([{"kind": "well", "position": 1, "text": "x".repeat(71)}]);
    expect(
        &app,
        &ana,
        &period,
        b,
        "A note can be at most 70 characters.",
    )
    .await;
    let mut b = ana_report();
    b["notes"] = json!((1..=4)
        .map(|i| json!({"kind": "next", "position": i, "text": "a"}))
        .collect::<Vec<_>>());
    expect(&app, &ana, &period, b, "Write at most 3 notes per box.").await;
    let mut b = ana_report();
    b["notes"] = json!([{"kind": "well", "position": 1, "text": "a"}, {"kind": "well", "position": 1, "text": "b"}]);
    expect(
        &app,
        &ana,
        &period,
        b,
        "Two notes in the same box have the same number.",
    )
    .await;
    let mut b = ana_report();
    b["notes"] = json!([{"kind": "well", "position": 0, "text": "a"}]);
    expect(&app, &ana, &period, b, "Notes are numbered 1 to 3.").await;
    let mut b = ana_report();
    b["notes"] = json!([{"kind": "well", "position": 1, "text": "   "}]);
    expect(&app, &ana, &period, b, "A note cannot be empty.").await;

    // Comment.
    let mut b = ana_report();
    b["kpis"][0]["comment"] = json!("c".repeat(201));
    expect(
        &app,
        &ana,
        &period,
        b,
        "A comment can be at most 200 characters.",
    )
    .await;

    // Ids from another seat.
    let mut b = ana_report();
    b["values"][0]["metric_def_id"] = json!(M_BOXES);
    expect(
        &app,
        &ana,
        &period,
        b,
        "One of the numbers does not belong to this report.",
    )
    .await;
    let mut b = ana_report();
    b["kpis"][0]["kpi_def_id"] = json!(K_SHIP);
    expect(
        &app,
        &ana,
        &period,
        b,
        "One of the targets does not belong to this report.",
    )
    .await;
    // A retired target does not belong either.
    let mut b = ana_report();
    b["kpis"][0]["kpi_def_id"] = json!("00000000-0000-0000-0000-0000000000c3");
    expect(
        &app,
        &ana,
        &period,
        b,
        "One of the targets does not belong to this report.",
    )
    .await;

    // Garbage shapes.
    let (s, _) = app
        .put_report(&ana, &period, A_ANA, json!({"values": "no"}))
        .await;
    assert_eq!(s, StatusCode::BAD_REQUEST);

    // Nothing was stored by any of the failures.
    assert_eq!(app.count("report").await, 0);

    // Boundaries are fine: 70 chars, 200 chars, three notes per kind.
    let mut b = ana_report();
    b["notes"] = json!([
        {"kind": "well", "position": 1, "text": "y".repeat(70)},
        {"kind": "well", "position": 2, "text": "y"},
        {"kind": "well", "position": 3, "text": "y"},
        {"kind": "wrong", "position": 1, "text": "y"},
        {"kind": "next", "position": 1, "text": "y"},
    ]);
    b["kpis"][0]["comment"] = json!("c".repeat(200));
    let (s, v) = app.put_report(&ana, &period, A_ANA, b).await;
    assert_eq!(s, StatusCode::OK, "{v}");
    // A value of zero is a real answer.
    assert!(v["values"]
        .as_array()
        .unwrap()
        .contains(&json!({"metric_def_id": M_CALLS, "month_offset": 0, "value": 0})));
}

#[tokio::test]
async fn validation_names_months_across_a_year_end() {
    let app = TestApp::new().await;
    let ana = app.login("ana@example.org").await;
    let period = app.ensure_period(&ana, "2026-11-01").await;
    let mut b = ana_report();
    b["values"].as_array_mut().unwrap().pop();
    let (s, v) = app.put_report(&ana, &period, A_ANA, b).await;
    assert_eq!(s, StatusCode::BAD_REQUEST);
    assert_eq!(v["error"], "Enter a number for \"Calls\" in January.");
}

#[tokio::test]
async fn contributors_can_only_send_their_own_report() {
    let app = TestApp::new().await;
    let ben = app.login("ben@example.org").await;
    let cora = app.login("cora@example.org").await;
    let period = app.ensure_period(&ben, "2026-02-01").await;

    let (s, v) = app.put_report(&ben, &period, A_ANA, ana_report()).await;
    assert_eq!(s, StatusCode::FORBIDDEN);
    assert_eq!(v["error"], "You can only send your own report.");
    assert_eq!(app.count("report").await, 0);

    let (s, _) = app.put_report(&ben, &period, A_BEN, ben_report()).await;
    assert_eq!(s, StatusCode::OK);
    // The controller may send for anyone.
    let (s, _) = app.put_report(&cora, &period, A_ANA, ana_report()).await;
    assert_eq!(s, StatusCode::OK);

    let (s, _) = app
        .put_report(
            &ben,
            &period,
            "00000000-0000-0000-0000-0000000000d4",
            ben_report(),
        )
        .await;
    assert_eq!(s, StatusCode::NOT_FOUND, "inactive seat");
    let (s, _) = app
        .put_report(
            &ben,
            "00000000-0000-0000-0000-000000000009",
            A_BEN,
            ben_report(),
        )
        .await;
    assert_eq!(s, StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn closed_period_blocks_contributors_but_not_the_controller() {
    let app = TestApp::new().await;
    let ana = app.login("ana@example.org").await;
    let cora = app.login("cora@example.org").await;
    let period = app.ensure_period(&ana, "2026-02-01").await;
    app.sql("update period set status = 'closed'").await;

    let (s, v) = app.put_report(&ana, &period, A_ANA, ana_report()).await;
    assert_eq!(s, StatusCode::FORBIDDEN);
    assert_eq!(v["error"], "This period is closed.");
    let (s, _) = app.put_report(&cora, &period, A_ANA, ana_report()).await;
    assert_eq!(s, StatusCode::OK);
}

// ---------- decks ----------

async fn fill_all(app: &TestApp, period: &str, cora: &str) {
    for (a, b) in [
        (A_ANA, ana_report()),
        (A_BEN, ben_report()),
        (A_CORA, cora_report()),
    ] {
        let (s, v) = app.put_report(cora, period, a, b).await;
        assert_eq!(s, StatusCode::OK, "{v}");
    }
}

#[tokio::test]
async fn controller_generates_the_deck_and_snapshots_follow_the_contract() {
    let app = TestApp::new().await;
    let ana = app.login("ana@example.org").await;
    let cora = app.login("cora@example.org").await;
    let period = app.ensure_period(&ana, "2026-11-01").await;
    let uri = format!("/api/periods/{period}/deck");

    let (s, v) = app.call("GET", &uri, Some(&cora), None).await;
    assert_eq!((s, v), (StatusCode::OK, Value::Null));

    app.put_report(&ana, &period, A_ANA, ana_report()).await;
    let (s, v) = app.call("POST", &uri, Some(&ana), None).await;
    assert_eq!(s, StatusCode::FORBIDDEN);
    assert_eq!(v["error"], "Only the controller can do this.");
    assert_eq!(app.count("deck_run").await, 0);

    // Only Ana has sent so far: 1 of 3 expected.
    let (s, deck) = app.call("POST", &uri, Some(&cora), None).await;
    assert_eq!(s, StatusCode::CREATED, "{deck}");
    assert_eq!(deck["expected_count"], 3);
    assert_eq!(deck["included_count"], 1);

    fill_all(&app, &period, &cora).await;
    let (s, deck) = app.call("POST", &uri, Some(&cora), None).await;
    assert_eq!(s, StatusCode::CREATED);
    assert_eq!(deck["period_id"], period);
    assert_eq!(
        (
            deck["expected_count"].clone(),
            deck["included_count"].clone()
        ),
        (json!(3), json!(3))
    );
    assert!(deck["generated_at"].is_string());

    let items = deck["items"].as_array().unwrap();
    let codes: Vec<&str> = items
        .iter()
        .map(|i| i["snapshot"]["assignmentCode"].as_str().unwrap())
        .collect();
    assert_eq!(codes, ["ben-export", "ana-import", "cora-ops"]);
    assert_eq!(
        items
            .iter()
            .map(|i| i["sort"].as_i64().unwrap())
            .collect::<Vec<_>>(),
        [1, 2, 3]
    );

    let ana_item = &items[1];
    let (_, rep) = app
        .call(
            "GET",
            &format!("/api/periods/{period}/reports/{A_ANA}"),
            Some(&ana),
            None,
        )
        .await;
    assert_eq!(ana_item["report_id"], rep["id"]);
    assert_eq!(
        ana_item["snapshot"],
        json!({
            "assignmentCode": "ana-import",
            "name": "Ana Rakoto",
            "role": "Import",
            "team": "Tana",
            "periodLabel": "Nov 2026 to Jan 2027",
            "months": [
                {"offset": 0, "year": 2026, "month": 11, "short": "Nov"},
                {"offset": 1, "year": 2026, "month": 12, "short": "Dec"},
                {"offset": 2, "year": 2027, "month": 1, "short": "Jan"},
            ],
            "metrics": [
                {"key": "files", "label": "Files", "series": 0, "values": [10, 11, 12]},
                {"key": "calls", "label": "Calls", "series": 1, "values": [0, 5, 6]},
            ],
            "targets": [
                {"text": "On time", "status": "met"},
                {"text": "No errors", "status": "partly"},
            ],
            "well": ["First good thing", "Second good thing"],
            "wrong": [],
            "next": ["Hire one more"],
        })
    );
    let cora_snap = &items[2]["snapshot"];
    assert_eq!(cora_snap["team"], "Antsirabe");
    assert_eq!(cora_snap["metrics"], json!([]));
    assert_eq!(cora_snap["wrong"], json!(["Too many meetings"]));

    // The latest deck is the one just made.
    let (_, latest) = app.call("GET", &uri, Some(&cora), None).await;
    assert_eq!(latest["id"], deck["id"]);
    assert_eq!(app.count("deck_run").await, 2);
}

#[tokio::test]
async fn decks_are_frozen_when_a_report_is_sent_again() {
    let app = TestApp::new().await;
    let cora = app.login("cora@example.org").await;
    let period = app.ensure_period(&cora, "2026-02-01").await;
    fill_all(&app, &period, &cora).await;
    let uri = format!("/api/periods/{period}/deck");
    let (_, old) = app.call("POST", &uri, Some(&cora), None).await;

    let mut b = ana_report();
    b["values"][0]["value"] = json!(777);
    b["notes"] = json!([]);
    app.put_report(&cora, &period, A_ANA, b).await;

    let (_, still_old) = app.call("GET", &uri, Some(&cora), None).await;
    assert_eq!(still_old, old);
    let files = &old["items"][1]["snapshot"]["metrics"][0]["values"];
    assert_eq!(files, &json!([10, 11, 12]));

    // A new deck sees the change; the old one stays in the table.
    let (_, new) = app.call("POST", &uri, Some(&cora), None).await;
    assert_eq!(
        new["items"][1]["snapshot"]["metrics"][0]["values"],
        json!([777, 11, 12])
    );
    assert_ne!(new["id"], old["id"]);
    let frozen: Value = sqlx::query_scalar(
        "select snapshot from deck_run_item where deck_run_id = $1::uuid and sort = 2",
    )
    .bind(old["id"].as_str().unwrap())
    .fetch_one(&app.state.pool)
    .await
    .unwrap();
    assert_eq!(frozen["metrics"][0]["values"], json!([10, 11, 12]));
}

// ---------- live events ----------

#[tokio::test]
async fn tickets_are_single_use_bound_to_a_person_and_expire() {
    let app = TestApp::new().await;
    let ana = app.login("cora@example.org").await;
    let period = app.ensure_period(&ana, "2026-02-01").await;

    let (s, v) = app
        .call("POST", "/api/events/ticket", Some(&ana), None)
        .await;
    assert_eq!(s, StatusCode::OK);
    let ticket = v["ticket"].as_str().unwrap().to_string();
    assert!(ticket.len() >= 40);
    assert_eq!(app.state.redeem_ticket("nope"), None);

    let uri = format!("/api/events?ticket={ticket}&period_id={period}");
    let res = app
        .router
        .clone()
        .oneshot(
            axum::http::Request::builder()
                .uri(&uri)
                .body(axum::body::Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    assert!(res.headers()["content-type"]
        .to_str()
        .unwrap()
        .starts_with("text/event-stream"));
    assert_eq!(res.headers()["x-accel-buffering"], "no");
    drop(res);

    // Second use fails.
    let (s, _) = app.call("GET", &uri, None, None).await;
    assert_eq!(s, StatusCode::UNAUTHORIZED);
    // No ticket, bad period.
    let (s, _) = app
        .call(
            "GET",
            &format!("/api/events?period_id={period}"),
            None,
            None,
        )
        .await;
    assert_eq!(s, StatusCode::UNAUTHORIZED);
    let (_, v) = app
        .call("POST", "/api/events/ticket", Some(&ana), None)
        .await;
    let (s, _) = app
        .call(
            "GET",
            &format!(
                "/api/events?ticket={}&period_id=zzz",
                v["ticket"].as_str().unwrap()
            ),
            None,
            None,
        )
        .await;
    assert_eq!(s, StatusCode::NOT_FOUND);

    // A deactivated person's ticket is refused.
    let (_, v) = app
        .call("POST", "/api/events/ticket", Some(&ana), None)
        .await;
    app.sql("update person set active = false where id = '00000000-0000-0000-0000-0000000000a3'")
        .await;
    let (s, _) = app
        .call(
            "GET",
            &format!(
                "/api/events?ticket={}&period_id={period}",
                v["ticket"].as_str().unwrap()
            ),
            None,
            None,
        )
        .await;
    assert_eq!(s, StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn tickets_expire() {
    let app = TestApp::with_ticket_ttl(Duration::from_millis(100)).await;
    let ana = app.login("cora@example.org").await;
    let period = app.ensure_period(&ana, "2026-02-01").await;
    let (_, v) = app
        .call("POST", "/api/events/ticket", Some(&ana), None)
        .await;
    tokio::time::sleep(Duration::from_millis(250)).await;
    let (s, _) = app
        .call(
            "GET",
            &format!(
                "/api/events?ticket={}&period_id={period}",
                v["ticket"].as_str().unwrap()
            ),
            None,
            None,
        )
        .await;
    assert_eq!(s, StatusCode::UNAUTHORIZED);
}

/// Read the stream until a data line for `kind` shows up.
async fn wait_for_event(body: &mut axum::body::Body, kind: &str, period: &str) -> bool {
    let deadline = tokio::time::Instant::now() + Duration::from_secs(8);
    let mut seen = String::new();
    while let Ok(Some(Ok(frame))) = tokio::time::timeout_at(deadline, body.frame()).await {
        if let Some(data) = frame.data_ref() {
            seen.push_str(&String::from_utf8_lossy(data));
            let want_kind = format!("\"kind\":\"{kind}\"");
            if seen
                .lines()
                .any(|l| l.starts_with("data: ") && l.contains(&want_kind) && l.contains(period))
            {
                return true;
            }
        }
    }
    false
}

#[tokio::test]
async fn an_open_stream_hears_about_report_and_deck_changes() {
    let app = TestApp::new().await;
    let _listener = listener::start(app.state.pool.clone(), app.state.events.clone()).await;
    let ana = app.login("ana@example.org").await;
    let cora = app.login("cora@example.org").await;
    let period = app.ensure_period(&ana, "2026-02-01").await;
    let other = app.ensure_period(&ana, "2026-05-01").await;

    let (_, v) = app
        .call("POST", "/api/events/ticket", Some(&cora), None)
        .await;
    let uri = format!(
        "/api/events?ticket={}&period_id={period}",
        v["ticket"].as_str().unwrap()
    );
    let res = app
        .router
        .clone()
        .oneshot(
            axum::http::Request::builder()
                .uri(uri)
                .body(axum::body::Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let mut body = res.into_body();

    // A change in another period must not show up; one in this period must.
    app.put_report(&ana, &other, A_ANA, ana_report()).await;
    app.put_report(&ana, &period, A_ANA, ana_report()).await;
    assert!(
        wait_for_event(&mut body, "reports", &period).await,
        "no reports event"
    );

    let (s, _) = app
        .call(
            "POST",
            &format!("/api/periods/{period}/deck"),
            Some(&cora),
            None,
        )
        .await;
    assert_eq!(s, StatusCode::CREATED);
    assert!(
        wait_for_event(&mut body, "deck", &period).await,
        "no deck event"
    );
}

#[tokio::test]
async fn the_listener_relays_database_notifications() {
    let app = TestApp::new().await;
    let _listener = listener::start(app.state.pool.clone(), app.state.events.clone()).await;
    let mut rx = app.state.events.subscribe();
    let ana = app.login("ana@example.org").await;
    let period = app.ensure_period(&ana, "2026-02-01").await;

    // Child tables resolve the period through the report.
    app.put_report(&ana, &period, A_ANA, ana_report()).await;
    let mut kinds = Vec::new();
    while let Ok(Ok(ev)) = tokio::time::timeout(Duration::from_secs(2), rx.recv()).await {
        assert_eq!(ev.period_id.to_string(), period);
        kinds.push(ev.kind);
        if !kinds.is_empty() {
            break;
        }
    }
    assert_eq!(kinds, ["reports"]);

    app.sql("update report_note set text = 'changed' where position = 1 and kind = 'next'")
        .await;
    let ev = tokio::time::timeout(Duration::from_secs(3), async {
        loop {
            let ev = rx.recv().await.unwrap();
            if ev.kind == "reports" {
                return ev;
            }
        }
    })
    .await
    .unwrap();
    assert_eq!(ev.period_id.to_string(), period);
}

// ---------- startup helpers ----------

#[tokio::test]
async fn bootstrap_controller_promotes_creates_and_activates() {
    let app = TestApp::new().await;
    let boot = xynotransit_api::bootstrap_controller;
    // Existing person: promoted once, then nothing to do.
    assert_eq!(
        boot(&app.state.pool, " ANA@example.org ", None)
            .await
            .unwrap(),
        1
    );
    assert_eq!(
        boot(&app.state.pool, "ana@example.org", None)
            .await
            .unwrap(),
        0
    );
    let ana = app.login("ana@example.org").await;
    let (_, v) = app.call("GET", "/api/me", Some(&ana), None).await;
    assert_eq!(v["role"], "controller");
    // Inactive person: activated and promoted.
    assert_eq!(
        boot(&app.state.pool, "dan@example.org", None)
            .await
            .unwrap(),
        1
    );
    let dan = app.login("dan@example.org").await;
    let (_, v) = app.call("GET", "/api/me", Some(&dan), None).await;
    assert_eq!(v["role"], "controller");
    // Unknown person: created with the name from the email, or the given name.
    assert_eq!(
        boot(&app.state.pool, "new.boss@example.org", None)
            .await
            .unwrap(),
        1
    );
    assert_eq!(
        boot(&app.state.pool, "new.boss@example.org", None)
            .await
            .unwrap(),
        0
    );
    let name: String =
        sqlx::query_scalar("select full_name from person where email = 'new.boss@example.org'")
            .fetch_one(&app.state.pool)
            .await
            .unwrap();
    assert_eq!(name, "New.boss");
    assert_eq!(
        boot(&app.state.pool, "Zed@example.org", Some("Zed Zed"))
            .await
            .unwrap(),
        1
    );
    let (n, r, a): (String, String, bool) = sqlx::query_as(
        "select full_name, app_role::text, active from person where email = 'zed@example.org'",
    )
    .fetch_one(&app.state.pool)
    .await
    .unwrap();
    assert_eq!((n.as_str(), r.as_str(), a), ("Zed Zed", "controller", true));
}

#[tokio::test]
async fn a_fresh_database_starts_empty_and_the_first_manager_builds_the_catalog() {
    let app = TestApp::empty().await;
    assert_eq!(app.count("team").await, 0);
    assert_eq!(app.count("person").await, 0);
    xynotransit_api::bootstrap_controller(&app.state.pool, "shalini@xynotransit.example", None)
        .await
        .unwrap();
    let t = app.login("shalini@xynotransit.example").await;
    let (s, v) = app.call("GET", "/api/catalog", Some(&t), None).await;
    assert_eq!(s, StatusCode::OK);
    assert_eq!(v["teams"], json!([]));
    assert_eq!(v["assignments"], json!([]));
    assert_eq!(v["persons"].as_array().unwrap().len(), 1);
    assert_eq!(v["persons"][0]["full_name"], "Shalini");
    assert_eq!(v["persons"][0]["app_role"], "controller");
    let (s, v) = app
        .call(
            "POST",
            "/api/teams",
            Some(&t),
            Some(json!({"name": "Tana"})),
        )
        .await;
    assert_eq!(s, StatusCode::CREATED, "{v}");
    assert_eq!(v["sort"], 1);
}

// ---------- role split ----------

#[tokio::test]
async fn contributors_are_kept_out_of_the_manager_endpoints() {
    let app = TestApp::new().await;
    let ana = app.login("ana@example.org").await;
    let cora = app.login("cora@example.org").await;
    let period = app.ensure_period(&ana, "2026-02-01").await;
    let msg = "Only the controller can do this.";

    for (m, uri) in [
        ("GET", format!("/api/periods/{period}/reports")),
        ("GET", format!("/api/periods/{period}/deck")),
        ("POST", "/api/events/ticket".to_string()),
    ] {
        let (s, v) = app.call(m, &uri, Some(&ana), None).await;
        assert_eq!(s, StatusCode::FORBIDDEN, "{m} {uri}");
        assert_eq!(v["error"], msg);
        let (s, _) = app.call(m, &uri, Some(&cora), None).await;
        assert_eq!(s, StatusCode::OK, "{m} {uri} as controller");
    }

    // A ticket made by a person who has since lost the role is refused.
    let (_, v) = app
        .call("POST", "/api/events/ticket", Some(&cora), None)
        .await;
    app.sql("update person set app_role = 'contributor' where id = '00000000-0000-0000-0000-0000000000a3'")
        .await;
    let (s, v) = app
        .call(
            "GET",
            &format!(
                "/api/events?ticket={}&period_id={period}",
                v["ticket"].as_str().unwrap()
            ),
            None,
            None,
        )
        .await;
    assert_eq!(s, StatusCode::FORBIDDEN);
    assert_eq!(v["error"], msg);
}

#[tokio::test]
async fn a_report_is_visible_to_its_owner_and_the_controller_only() {
    let app = TestApp::new().await;
    let ana = app.login("ana@example.org").await;
    let ben = app.login("ben@example.org").await;
    let cora = app.login("cora@example.org").await;
    let period = app.ensure_period(&ana, "2026-02-01").await;
    let (s, _) = app.put_report(&ana, &period, A_ANA, ana_report()).await;
    assert_eq!(s, StatusCode::OK);

    let uri = format!("/api/periods/{period}/reports/{A_ANA}");
    let (s, v) = app.call("GET", &uri, Some(&ben), None).await;
    assert_eq!(s, StatusCode::FORBIDDEN);
    assert_eq!(v["error"], "You can only see your own report.");
    for t in [&ana, &cora] {
        let (s, v) = app.call("GET", &uri, Some(t), None).await;
        assert_eq!(s, StatusCode::OK);
        assert_eq!(v["assignment_id"], A_ANA);
    }
    // A seat that is not yours reads the same, whether or not it exists.
    let (s, _) = app
        .call(
            "GET",
            &format!("/api/periods/{period}/reports/00000000-0000-0000-0000-0000000000ff"),
            Some(&ben),
            None,
        )
        .await;
    assert_eq!(s, StatusCode::FORBIDDEN);
}

#[tokio::test]
async fn catalog_hides_other_peoples_emails_from_contributors() {
    let app = TestApp::new().await;
    let ana = app.login("ana@example.org").await;
    let cora = app.login("cora@example.org").await;

    let (s, v) = app.call("GET", "/api/catalog", Some(&ana), None).await;
    assert_eq!(s, StatusCode::OK);
    let persons = v["persons"].as_array().unwrap();
    assert_eq!(persons.len(), 3);
    for p in persons {
        assert!(p["full_name"].is_string() && p["app_role"].is_string());
        if p["id"] == ANA {
            assert_eq!(p["email"], "ana@example.org");
        } else {
            assert!(p["email"].is_null(), "{p}");
        }
    }
    assert_eq!(v["teams"].as_array().unwrap().len(), 2);
    assert_eq!(v["assignments"].as_array().unwrap().len(), 3);
    assert_eq!(v["assignments"][1]["metrics"].as_array().unwrap().len(), 2);

    let (_, v) = app.call("GET", "/api/catalog", Some(&cora), None).await;
    assert!(v["persons"]
        .as_array()
        .unwrap()
        .iter()
        .all(|p| p["email"].is_string()));
}
