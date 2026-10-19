//! Adversarial regression tests: each one pins a hole found in review.

mod common;

use axum::http::StatusCode;
use common::*;
use jsonwebtoken::{encode, Algorithm, EncodingKey, Header};
use serde_json::{json, Value};

fn with_value(mut body: Value, metric: &str, offset: i64, value: Value) -> Value {
    for v in body["values"].as_array_mut().unwrap() {
        if v["metric_def_id"] == metric && v["month_offset"] == offset {
            v["value"] = value.clone();
        }
    }
    body
}

fn forged(alg: Algorithm, secret: &str, sub: &str, role: &str) -> String {
    let exp = chrono::Utc::now().timestamp() + 3600;
    encode(
        &Header::new(alg),
        &json!({"sub": sub, "role": role, "iat": 0, "exp": exp}),
        &EncodingKey::from_secret(secret.as_bytes()),
    )
    .unwrap()
}

#[tokio::test]
async fn values_above_one_billion_are_refused() {
    let app = TestApp::new().await;
    let ana = app.login("ana@example.org").await;
    let p = app.ensure_period(&ana, "2026-02-01").await;
    let body = with_value(ana_report(), M_FILES, 0, json!(1_000_000_001i64));
    let (s, v) = app.put_report(&ana, &p, A_ANA, body).await;
    assert_eq!(s, StatusCode::BAD_REQUEST, "{v}");
    assert_eq!(app.count("report").await, 0);
    // The cap itself is fine.
    let body = with_value(ana_report(), M_FILES, 0, json!(1_000_000_000i64));
    let (s, v) = app.put_report(&ana, &p, A_ANA, body).await;
    assert_eq!(s, StatusCode::OK, "{v}");
}

#[tokio::test]
async fn nul_characters_are_a_400_not_a_500() {
    let app = TestApp::new().await;
    let ana = app.login("ana@example.org").await;
    let p = app.ensure_period(&ana, "2026-02-01").await;

    let mut body = ana_report();
    body["notes"][0]["text"] = json!("bad\u{0}note");
    let (s, v) = app.put_report(&ana, &p, A_ANA, body).await;
    assert_eq!(s, StatusCode::BAD_REQUEST, "{v}");

    let mut body = ana_report();
    body["kpis"][1]["comment"] = json!("bad\u{0}comment");
    let (s, v) = app.put_report(&ana, &p, A_ANA, body).await;
    assert_eq!(s, StatusCode::BAD_REQUEST, "{v}");

    let (s, _) = app
        .call(
            "POST",
            "/api/auth/magic-link",
            None,
            Some(json!({"email": "ana\u{0}@example.org"})),
        )
        .await;
    assert!(
        s == StatusCode::BAD_REQUEST || s == StatusCode::ACCEPTED,
        "got {s}"
    );
}

#[tokio::test]
async fn absurd_period_dates_are_refused() {
    let app = TestApp::new().await;
    let ana = app.login("ana@example.org").await;
    for d in ["0000-01-01", "0001-01-01", "9999-01-01", "262000-01-01"] {
        let (s, v) = app
            .call(
                "POST",
                "/api/periods/ensure",
                Some(&ana),
                Some(json!({"start_month": d})),
            )
            .await;
        assert_eq!(s, StatusCode::BAD_REQUEST, "{d}: {v}");
    }
    assert_eq!(app.count("period").await, 0);
    // Manager meeting dates get the same sanity check.
    let cora = app.login("cora@example.org").await;
    let p = app.ensure_period(&cora, "2026-02-01").await;
    let (s, v) = app
        .call(
            "PATCH",
            &format!("/api/periods/{p}"),
            Some(&cora),
            Some(json!({"meeting_date": "9999-01-01"})),
        )
        .await;
    assert_eq!(s, StatusCode::BAD_REQUEST, "{v}");
}

#[tokio::test]
async fn parallel_link_requests_cannot_beat_the_hourly_limit() {
    let app = TestApp::new().await;
    let mut tasks = Vec::new();
    for _ in 0..20 {
        let router = app.router.clone();
        tasks.push(tokio::spawn(async move {
            use tower::ServiceExt;
            let req = axum::http::Request::builder()
                .method("POST")
                .uri("/api/auth/magic-link")
                .header("content-type", "application/json")
                .body(axum::body::Body::from(r#"{"email":"ana@example.org"}"#))
                .unwrap();
            router.oneshot(req).await.unwrap().status()
        }));
    }
    for t in tasks {
        let _ = t.await.unwrap();
    }
    assert_eq!(app.count("login_token").await, 5);
    assert_eq!(app.state.mailer.sent().len(), 5);
}

#[tokio::test]
async fn email_casing_spaces_do_not_dodge_the_limit() {
    let app = TestApp::new().await;
    for e in [
        "ana@example.org",
        " ANA@example.org",
        "Ana@Example.ORG ",
        "ana@example.org",
        "\tana@EXAMPLE.org\n",
    ] {
        let (s, _) = app
            .call(
                "POST",
                "/api/auth/magic-link",
                None,
                Some(json!({"email": e})),
            )
            .await;
        assert_eq!(s, StatusCode::ACCEPTED, "{e:?}");
    }
    let (s, _) = app
        .call(
            "POST",
            "/api/auth/magic-link",
            None,
            Some(json!({"email": "ANA@example.org"})),
        )
        .await;
    assert_eq!(s, StatusCode::TOO_MANY_REQUESTS);
}

#[tokio::test]
async fn forged_and_stale_tokens_do_not_sign_anyone_in() {
    let app = TestApp::new().await;
    // Wrong secret, none-ish algs, other HMAC algs, garbage subject.
    let cases = vec![
        forged(Algorithm::HS256, "another-secret-another-secret-123456", ANA, "controller"),
        forged(Algorithm::HS384, SECRET, ANA, "contributor"),
        forged(Algorithm::HS512, SECRET, ANA, "contributor"),
        forged(Algorithm::HS256, SECRET, "not-a-uuid", "controller"),
        "eyJhbGciOiJub25lIiwidHlwIjoiSldUIn0.eyJzdWIiOiIwMDAwMDAwMC0wMDAwLTAwMDAtMDAwMC0wMDAwMDAwMDAwYTEiLCJyb2xlIjoiY29udHJvbGxlciIsImV4cCI6OTk5OTk5OTk5OX0.".into(),
    ];
    for t in cases {
        let (s, _) = app.call("GET", "/api/me", Some(&t), None).await;
        assert_eq!(s, StatusCode::UNAUTHORIZED, "{t}");
    }
    // Expired but correctly signed.
    let old = encode(
        &Header::new(Algorithm::HS256),
        &json!({"sub": ANA, "role": "contributor", "iat": 0, "exp": 1000}),
        &EncodingKey::from_secret(SECRET.as_bytes()),
    )
    .unwrap();
    let (s, _) = app.call("GET", "/api/me", Some(&old), None).await;
    assert_eq!(s, StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn the_role_claim_is_not_trusted_and_deactivated_people_are_out() {
    let app = TestApp::new().await;
    // A correctly signed token that claims manager for a contributor.
    let t = forged(Algorithm::HS256, SECRET, ANA, "controller");
    let (s, v) = app.call("GET", "/api/me", Some(&t), None).await;
    assert_eq!(s, StatusCode::OK);
    assert_eq!(v["role"], "contributor");
    let p = app.ensure_period(&t, "2026-02-01").await;
    let (s, _) = app
        .call("POST", &format!("/api/periods/{p}/deck"), Some(&t), None)
        .await;
    assert_eq!(s, StatusCode::FORBIDDEN);
    let (s, _) = app
        .call(
            "PATCH",
            &format!("/api/periods/{p}"),
            Some(&t),
            Some(json!({"meeting_date": "2026-03-01"})),
        )
        .await;
    assert_eq!(s, StatusCode::FORBIDDEN);

    app.sql("update person set active = false where email = 'ana@example.org'")
        .await;
    for (m, u) in [
        ("GET", "/api/me".to_string()),
        ("GET", "/api/catalog".to_string()),
        ("GET", format!("/api/periods/{p}/reports")),
        ("POST", "/api/events/ticket".to_string()),
    ] {
        let (s, _) = app.call(m, &u, Some(&t), None).await;
        assert_eq!(s, StatusCode::UNAUTHORIZED, "{u}");
    }
}

#[tokio::test]
async fn reports_cannot_cross_seats() {
    let app = TestApp::new().await;
    let ben = app.login("ben@example.org").await;
    let ana = app.login("ana@example.org").await;
    let p = app.ensure_period(&ben, "2026-02-01").await;

    // Ben writes to Ana's seat: no.
    let (s, _) = app.put_report(&ben, &p, A_ANA, ana_report()).await;
    assert_eq!(s, StatusCode::FORBIDDEN);
    // Ben writes his own seat with Ana's metric and target ids: no.
    let (s, _) = app.put_report(&ben, &p, A_BEN, ana_report()).await;
    assert_eq!(s, StatusCode::BAD_REQUEST);
    // Ben adds one foreign metric on top of a good report: no.
    let mut body = ben_report();
    body["values"]
        .as_array_mut()
        .unwrap()
        .push(json!({"metric_def_id": M_FILES, "month_offset": 0, "value": 1}));
    let (s, _) = app.put_report(&ben, &p, A_BEN, body).await;
    assert_eq!(s, StatusCode::BAD_REQUEST);
    // A retired metric or target id is foreign too.
    let mut body = ana_report();
    body["kpis"]
        .as_array_mut()
        .unwrap()
        .push(json!({"kpi_def_id": "00000000-0000-0000-0000-0000000000c3", "status": "met"}));
    let (s, _) = app.put_report(&ana, &p, A_ANA, body).await;
    assert_eq!(s, StatusCode::BAD_REQUEST);
    assert_eq!(app.count("report").await, 0);
    assert_eq!(app.count("report_metric_value").await, 0);
}

#[tokio::test]
async fn note_length_counts_characters_not_bytes() {
    let app = TestApp::new().await;
    let ana = app.login("ana@example.org").await;
    let p = app.ensure_period(&ana, "2026-02-01").await;

    let mut body = ana_report();
    body["notes"][0]["text"] = json!("é".repeat(70)); // 140 bytes
    let (s, v) = app.put_report(&ana, &p, A_ANA, body).await;
    assert_eq!(s, StatusCode::OK, "{v}");

    let mut body = ana_report();
    body["notes"][0]["text"] = json!("😀".repeat(71));
    let (s, _) = app.put_report(&ana, &p, A_ANA, body).await;
    assert_eq!(s, StatusCode::BAD_REQUEST);

    let mut body = ana_report();
    body["notes"][0]["text"] = json!(format!("  {}  ", "x".repeat(70)));
    let (s, _) = app.put_report(&ana, &p, A_ANA, body).await;
    assert_eq!(s, StatusCode::OK);
}

#[tokio::test]
async fn status_cannot_be_forced_from_the_body() {
    let app = TestApp::new().await;
    let ana = app.login("ana@example.org").await;
    let p = app.ensure_period(&ana, "2026-02-01").await;
    // An incomplete report with a claimed "submitted" status must not be stored.
    let (s, _) = app
        .put_report(
            &ana,
            &p,
            A_ANA,
            json!({"status": "submitted", "values": [], "kpis": [], "notes": []}),
        )
        .await;
    assert_eq!(s, StatusCode::BAD_REQUEST);
    assert_eq!(app.count("report").await, 0);
}
