//! Regression tests from the security review of the dynamic catalog surface.

mod common;

use axum::http::StatusCode;
use common::*;
use serde_json::{json, Value};

async fn boss(app: &TestApp) -> String {
    app.login("cora@example.org").await
}

#[tokio::test]
async fn invisible_and_direction_characters_are_refused_in_every_typed_name() {
    let app = TestApp::new().await;
    let t = boss(&app).await;
    for bad in [
        "\u{200B}",
        "Fi\u{200B}les",
        "Fi\u{200E}les",
        "x\u{202E}txt",
        "a\u{FEFF}",
        "a\u{2028}b",
        "a\u{00AD}b",
        "a\u{2066}b",
    ] {
        let (s, v) = app
            .call("POST", "/api/teams", Some(&t), Some(json!({"name": bad})))
            .await;
        assert_eq!(s, StatusCode::BAD_REQUEST, "team {bad:?}: {v}");
        let (s, v) = app
            .call(
                "POST",
                "/api/persons",
                Some(&t),
                Some(json!({"full_name": bad, "email": "z@x.org", "app_role": "contributor"})),
            )
            .await;
        assert_eq!(s, StatusCode::BAD_REQUEST, "person {bad:?}: {v}");
        let (s, v) = app
            .call(
                "PUT",
                &format!("/api/assignments/{A_ANA}/definitions"),
                Some(&t),
                Some(json!({"metrics": [{"label": bad}], "kpis": [{"text": bad}]})),
            )
            .await;
        assert_eq!(s, StatusCode::BAD_REQUEST, "defs {bad:?}: {v}");
        let (s, _) = app
            .call(
                "POST",
                "/api/persons",
                Some(&t),
                Some(json!({"full_name": "Z", "email": format!("z{bad}@x.org"), "app_role": "contributor"})),
            )
            .await;
        assert_eq!(s, StatusCode::BAD_REQUEST, "email {bad:?}");
    }
    assert_eq!(app.count("team").await, 2);
}

#[tokio::test]
async fn emails_with_address_syntax_characters_are_refused() {
    let app = TestApp::new().await;
    let t = boss(&app).await;
    for bad in [
        "<z@x.org>",
        "a,b@x.org",
        "\"z\"@x.org",
        "z@x.org;w@y.org",
        "a(b)@x.org",
        "a\\b@x.org",
    ] {
        let (s, v) = app
            .call(
                "POST",
                "/api/persons",
                Some(&t),
                Some(json!({"full_name": "Z", "email": bad, "app_role": "contributor"})),
            )
            .await;
        assert_eq!(s, StatusCode::BAD_REQUEST, "{bad}: {v}");
    }
}

#[tokio::test]
async fn two_creates_with_one_email_have_exactly_one_winner() {
    let app = TestApp::new().await;
    let t = boss(&app).await;
    let mk = |e: &'static str| {
        app.call(
            "POST",
            "/api/persons",
            Some(&t),
            Some(json!({"full_name": "Z", "email": e, "app_role": "contributor"})),
        )
    };
    let (a, b, c, d) = tokio::join!(
        mk("race@x.org"),
        mk(" RACE@x.org"),
        mk("race@X.org"),
        mk("Race@x.ORG ")
    );
    let codes: Vec<u16> = [a, b, c, d].iter().map(|r| r.0.as_u16()).collect();
    assert_eq!(codes.iter().filter(|c| **c == 201).count(), 1, "{codes:?}");
    assert_eq!(codes.iter().filter(|c| **c == 409).count(), 3, "{codes:?}");
}

#[tokio::test]
async fn managers_demoting_each_other_at_once_leave_one() {
    let app = TestApp::new().await;
    let t = boss(&app).await;
    let (s, _) = app
        .call(
            "PATCH",
            &format!("/api/persons/{ANA}"),
            Some(&t),
            Some(json!({"app_role": "controller"})),
        )
        .await;
    assert_eq!(s, StatusCode::OK);
    let ana = app.login("ana@example.org").await;
    for _ in 0..5 {
        let (ucora, uana) = (
            format!("/api/persons/{CORA}"),
            format!("/api/persons/{ANA}"),
        );
        let (x, y) = tokio::join!(
            app.call("PATCH", &ucora, Some(&ana), Some(json!({"active": false}))),
            app.call(
                "PATCH",
                &uana,
                Some(&t),
                Some(json!({"app_role": "contributor"}))
            )
        );
        assert_ne!(x.0, StatusCode::INTERNAL_SERVER_ERROR);
        assert_ne!(y.0, StatusCode::INTERNAL_SERVER_ERROR);
        let n = app
            .scalar("select count(*) from person where active and app_role = 'controller'")
            .await;
        assert!(n >= 1, "no manager left");
        app.sql("update person set active = true, app_role = 'controller' where id in ('00000000-0000-0000-0000-0000000000a3','00000000-0000-0000-0000-0000000000a1')").await;
    }
}

#[tokio::test]
async fn parallel_reorders_of_one_seat_never_fail_with_500() {
    let app = TestApp::new().await;
    let t = boss(&app).await;
    let (s, v) = app
        .call(
            "PUT",
            &format!("/api/assignments/{A_ANA}/definitions"),
            Some(&t),
            Some(json!({"metrics": [{"label": "A"}, {"label": "B"}, {"label": "C"}], "kpis": []})),
        )
        .await;
    assert_eq!(s, StatusCode::OK, "{v}");
    let ids: Vec<Value> = v["metrics"]
        .as_array()
        .unwrap()
        .iter()
        .map(|m| m["id"].clone())
        .collect();
    let order = |o: [usize; 3]| json!({"metrics": o.iter().map(|i| json!({"id": ids[*i], "label": format!("L{i}")})).collect::<Vec<_>>(), "kpis": []});
    let uri = format!("/api/assignments/{A_ANA}/definitions");
    let (a, b, c) = tokio::join!(
        app.call("PUT", &uri, Some(&t), Some(order([2, 1, 0]))),
        app.call("PUT", &uri, Some(&t), Some(order([1, 2, 0]))),
        app.call("PUT", &uri, Some(&t), Some(order([0, 2, 1])))
    );
    for r in [a, b, c] {
        assert_eq!(r.0, StatusCode::OK, "{}", r.1);
    }
}

#[tokio::test]
async fn team_names_differing_only_in_case_cannot_race_in() {
    let app = TestApp::new().await;
    let t = boss(&app).await;
    let mut ids = vec![];
    for n in ["Q1", "Q2", "Q3", "Q4"] {
        let (_, v) = app
            .call("POST", "/api/teams", Some(&t), Some(json!({"name": n})))
            .await;
        ids.push(v["id"].as_str().unwrap().to_string());
    }
    let uris: Vec<String> = ids.iter().map(|i| format!("/api/teams/{i}")).collect();
    let rn =
        |i: usize, n: &'static str| app.call("PATCH", &uris[i], Some(&t), Some(json!({"name": n})));
    let (a, b, c, d) = tokio::join!(rn(0, "Same"), rn(1, "SAME"), rn(2, "same"), rn(3, "sAmE"));
    let ok = [a, b, c, d]
        .iter()
        .filter(|r| r.0 == StatusCode::OK)
        .count();
    assert_eq!(ok, 1);
}

#[tokio::test]
async fn deleting_a_team_while_a_seat_is_added_is_never_a_500() {
    let app = TestApp::new().await;
    let t = boss(&app).await;
    for _ in 0..5 {
        let (_, v) = app
            .call("POST", "/api/teams", Some(&t), Some(json!({"name": "Tmp"})))
            .await;
        let id = v["id"].as_str().unwrap().to_string();
        let uri = format!("/api/teams/{id}");
        let (d, c) = tokio::join!(
            app.call("DELETE", &uri, Some(&t), None),
            app.call(
                "POST",
                "/api/assignments",
                Some(&t),
                Some(json!({"person_id": ANA, "team_id": id, "role_title": "Tmp seat"}))
            )
        );
        assert_ne!(d.0, StatusCode::INTERNAL_SERVER_ERROR, "{}", d.1);
        assert_ne!(c.0, StatusCode::INTERNAL_SERVER_ERROR, "{}", c.1);
        app.sql("delete from assignment where role_title = 'Tmp seat'")
            .await;
        app.sql("delete from team where name = 'Tmp'").await;
    }
}

#[tokio::test]
async fn huge_bodies_are_refused_and_expired_tokens_are_out() {
    let app = TestApp::new().await;
    let t = boss(&app).await;
    let big = json!({"name": "x".repeat(300 * 1024)});
    let (s, _) = app.call("POST", "/api/teams", Some(&t), Some(big)).await;
    assert_eq!(s, StatusCode::PAYLOAD_TOO_LARGE);

    let exp = jsonwebtoken::encode(
        &jsonwebtoken::Header::default(),
        &json!({"sub": CORA, "role": "controller", "iat": 0, "exp": chrono::Utc::now().timestamp() - 3600}),
        &jsonwebtoken::EncodingKey::from_secret(SECRET.as_bytes()),
    )
    .unwrap();
    let (s, _) = app
        .call(
            "GET",
            "/api/catalog?include_inactive=true",
            Some(&exp),
            None,
        )
        .await;
    assert_eq!(s, StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn bootstrap_email_case_does_not_create_a_twin() {
    let app = TestApp::new().await;
    app.sql("update person set email = 'Cora@Example.org', active = false where id = '00000000-0000-0000-0000-0000000000a3'").await;
    let n = xynotransit_api::bootstrap_controller(&app.state.pool, " CORA@example.ORG ", None)
        .await
        .unwrap();
    assert_eq!(n, 1);
    assert_eq!(
        app.scalar("select count(*) from person where lower(email) = 'cora@example.org'")
            .await,
        1
    );
    assert_eq!(
        app.scalar("select count(*) from person where active and app_role = 'controller' and id = '00000000-0000-0000-0000-0000000000a3'").await,
        1
    );
}
