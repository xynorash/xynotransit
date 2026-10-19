//! Adversarial checks of the deck-text routes.
mod common;

use axum::http::StatusCode;
use common::TestApp;
use serde_json::{json, Value};

fn uri(p: &str) -> String {
    format!("/api/periods/{p}/deck-text")
}

#[tokio::test]
async fn bad_bodies_never_500_and_values_are_never_expanded() {
    let app = TestApp::new().await;
    let cora = app.login("cora@example.org").await;
    let p = app.ensure_period(&cora, "2026-02-01").await;

    for settings in [
        json!(null),
        json!([]),
        json!("x"),
        json!({"title": null}),
        json!({"title": ["a"]}),
        json!({"title": {"a": "b"}}),
        json!({"title": true}),
        json!({"title": 1.5}),
        json!({"__proto__": "x"}),
        json!({"title": "ok", "Title": "x"}),
    ] {
        let (s, v) = app
            .call(
                "PUT",
                &uri(&p),
                Some(&cora),
                Some(json!({"settings": settings})),
            )
            .await;
        assert_eq!(s, StatusCode::BAD_REQUEST, "{settings} -> {v}");
        assert!(v["error"].is_string());
    }
    for raw in [
        &b"{"[..],
        b"",
        b"null",
        b"{\"settings\":{\"title\":\"a\"},\"x\":1}",
    ] {
        let (s, _) = app
            .raw("PUT", &uri(&p), Some(&cora), Some(raw.to_vec()))
            .await;
        assert!(s == StatusCode::BAD_REQUEST || s == StatusCode::OK, "{s}");
    }
    // Too large: refused with 413 and nothing stored.
    let big = json!({"settings": {"title": "x".repeat(300 * 1024)}});
    let (s, _) = app.call("PUT", &uri(&p), Some(&cora), Some(big)).await;
    assert_eq!(s, StatusCode::PAYLOAD_TOO_LARGE);
    // A big but legal-size body with a very long unknown key is a 400, not a 500.
    let key = "k".repeat(200 * 1024);
    let (s, _) = app
        .call(
            "PUT",
            &uri(&p),
            Some(&cora),
            Some(json!({"settings": {key: "x"}})),
        )
        .await;
    assert_eq!(s, StatusCode::BAD_REQUEST);

    // HTML, quotes and braces come back verbatim as JSON text; {period} is not expanded.
    let evil = "<script>alert(1)</script> \"q\" \\ {period} {{period}} {title";
    let (s, v) = app
        .call(
            "PUT",
            &uri(&p),
            Some(&cora),
            Some(json!({"settings": {"title": evil, "subtitle": "{period}"}})),
        )
        .await;
    assert_eq!(s, StatusCode::OK, "{v}");
    let (_, g) = app.call("GET", &uri(&p), Some(&cora), None).await;
    assert_eq!(g["settings"]["title"], evil);
    assert_eq!(g["settings"]["subtitle"], "{period}");
    let (_, d) = app
        .call("POST", &format!("/api/periods/{p}/deck"), Some(&cora), None)
        .await;
    assert_eq!(d["texts"]["title"], evil);
}

#[tokio::test]
async fn multiline_field_stores_plain_line_feeds() {
    let app = TestApp::new().await;
    let cora = app.login("cora@example.org").await;
    let p = app.ensure_period(&cora, "2026-02-01").await;
    let (s, v) = app
        .call(
            "PUT",
            &uri(&p),
            Some(&cora),
            Some(json!({"settings": {"suggestionsBody": "a\r\nb\rc\nd"}})),
        )
        .await;
    assert_eq!(s, StatusCode::OK, "{v}");
    assert_eq!(v["settings"]["suggestionsBody"], "a\nb\nc\nd");
    // Counted after normalising: 400 characters with CRLF breaks fit.
    let body = format!("{}\r\n{}", "x".repeat(199), "y".repeat(200));
    let (s, v) = app
        .call(
            "PUT",
            &uri(&p),
            Some(&cora),
            Some(json!({"settings": {"suggestionsBody": body}})),
        )
        .await;
    assert_eq!(s, StatusCode::OK, "{v}");
}

#[tokio::test]
async fn deactivated_and_demoted_managers_and_forged_tokens_are_out() {
    let app = TestApp::new().await;
    let cora = app.login("cora@example.org").await;
    let p = app.ensure_period(&cora, "2026-02-01").await;
    let (s, _) = app.call("GET", &uri(&p), Some(&cora), None).await;
    assert_eq!(s, StatusCode::OK);
    for t in ["garbage", "", "a.b.c"] {
        for m in ["GET", "PUT"] {
            let (s, _) = app
                .call(m, &uri(&p), Some(t), Some(json!({"settings": {}})))
                .await;
            assert_eq!(s, StatusCode::UNAUTHORIZED, "{m} {t}");
        }
    }
    app.sql("update person set app_role = 'contributor' where email = 'cora@example.org'")
        .await;
    for m in ["GET", "PUT"] {
        let (s, _) = app
            .call(m, &uri(&p), Some(&cora), Some(json!({"settings": {}})))
            .await;
        // Reading is open to every active person; writing is the manager's.
        let want = if m == "GET" {
            StatusCode::OK
        } else {
            StatusCode::FORBIDDEN
        };
        assert_eq!(s, want, "demoted {m}");
    }
    app.sql("update person set app_role = 'controller', active = false where email = 'cora@example.org'")
        .await;
    for m in ["GET", "PUT"] {
        let (s, _) = app
            .call(m, &uri(&p), Some(&cora), Some(json!({"settings": {}})))
            .await;
        assert_eq!(s, StatusCode::UNAUTHORIZED, "deactivated {m}");
    }
    assert_eq!(app.count("deck_text").await, 0);
}

#[tokio::test]
async fn concurrent_puts_leave_one_whole_object() {
    let app = TestApp::new().await;
    let cora = app.login("cora@example.org").await;
    let p = app.ensure_period(&cora, "2026-02-01").await;
    let mut hs = Vec::new();
    for i in 0..12 {
        let router = app.router.clone();
        let (cora, p) = (cora.clone(), p.clone());
        hs.push(tokio::spawn(async move {
            use axum::{body::Body, http::Request};
            use tower::ServiceExt;
            let body = json!({"settings": {"title": format!("T{i}"), "footer": format!("F{i}")}});
            let req = Request::builder()
                .method("PUT")
                .uri(uri(&p))
                .header("authorization", format!("Bearer {cora}"))
                .header("content-type", "application/json")
                .body(Body::from(serde_json::to_vec(&body).unwrap()))
                .unwrap();
            router.oneshot(req).await.unwrap().status()
        }));
    }
    for h in hs {
        assert_eq!(h.await.unwrap(), StatusCode::OK);
    }
    assert_eq!(app.count("deck_text").await, 1);
    let (_, g) = app.call("GET", &uri(&p), Some(&cora), None).await;
    let t = g["settings"]["title"].as_str().unwrap().replace('T', "");
    let f = g["settings"]["footer"].as_str().unwrap().replace('F', "");
    assert_eq!(t, f, "title and footer must come from the same PUT: {g}");
}

#[tokio::test]
async fn deleted_middle_period_falls_back_to_the_next_earlier_words() {
    let app = TestApp::new().await;
    let cora = app.login("cora@example.org").await;
    let feb = app.ensure_period(&cora, "2026-02-01").await;
    let may = app.ensure_period(&cora, "2026-05-01").await;
    let aug = app.ensure_period(&cora, "2026-08-01").await;
    for (p, t) in [(&feb, "Feb words"), (&may, "May words")] {
        app.call(
            "PUT",
            &uri(p),
            Some(&cora),
            Some(json!({"settings": {"title": t}})),
        )
        .await;
    }
    let (_, g) = app.call("GET", &uri(&aug), Some(&cora), None).await;
    assert_eq!(g["settings"]["title"], "May words");
    app.sql(&format!("delete from period where id = '{may}'"))
        .await;
    let (s, g) = app.call("GET", &uri(&aug), Some(&cora), None).await;
    assert_eq!(s, StatusCode::OK, "{g}");
    assert_eq!(g["settings"]["title"], "Feb words");
    assert_eq!(g["inherited_from"], "Feb to Apr 2026");
    assert_eq!(app.count("deck_text").await, 1);
    let (s, _) = app.call("GET", &uri(&may), Some(&cora), None).await;
    assert_eq!(s, StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn a_deck_generated_during_puts_gets_one_consistent_set() {
    let app = TestApp::new().await;
    let cora = app.login("cora@example.org").await;
    let p = app.ensure_period(&cora, "2026-02-01").await;
    use axum::{body::Body, http::Request};
    use tower::ServiceExt;
    let mk = |method: &'static str, uri: String, body: Option<Value>, tok: String| {
        let router = app.router.clone();
        tokio::spawn(async move {
            let mut b = Request::builder()
                .method(method)
                .uri(uri)
                .header("authorization", format!("Bearer {tok}"));
            let req = match body {
                Some(v) => {
                    b = b.header("content-type", "application/json");
                    b.body(Body::from(serde_json::to_vec(&v).unwrap())).unwrap()
                }
                None => b.body(Body::empty()).unwrap(),
            };
            router.oneshot(req).await.unwrap().status()
        })
    };
    let mut hs = Vec::new();
    for i in 0..10 {
        hs.push(mk(
            "PUT",
            uri(&p),
            Some(json!({"settings": {"title": format!("T{i}"), "footer": format!("F{i}")}})),
            cora.clone(),
        ));
        hs.push(mk(
            "POST",
            format!("/api/periods/{p}/deck"),
            None,
            cora.clone(),
        ));
    }
    for h in hs {
        let s = h.await.unwrap();
        assert!(s == StatusCode::OK || s == StatusCode::CREATED, "{s}");
    }
    let rows: Vec<(Value,)> = sqlx::query_as("select texts from deck_run")
        .fetch_all(&app.state.pool)
        .await
        .unwrap();
    assert_eq!(rows.len(), 10);
    for (t,) in rows {
        let ti = t["title"].as_str().unwrap();
        let fo = t["footer"].as_str().unwrap();
        if ti.starts_with('T') && ti.len() <= 3 {
            assert_eq!(&ti[1..], &fo[1..], "mixed words: {t}");
        }
    }
}
