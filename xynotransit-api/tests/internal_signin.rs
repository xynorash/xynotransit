//! Signing in without a real email: internal addresses, people without an email, one-time
//! sign-in links from a manager and from the server command.

mod common;

use axum::http::StatusCode;
use common::*;
use serde_json::{json, Value};
use xynotransit_api::{build_router, mail::Mailer, state::AppState};

const PERSONS: &str = "/api/persons";

fn token_of(url: &str) -> String {
    url.split("token=").nth(1).unwrap().to_string()
}

async fn verify(app: &TestApp, token: &str) -> (StatusCode, Value) {
    app.call(
        "POST",
        "/api/auth/verify",
        None,
        Some(json!({"token": token})),
    )
    .await
}

async fn new_person(app: &TestApp, boss: &str, name: &str, email: Option<&str>) -> Value {
    let mut body = json!({"full_name": name, "app_role": "contributor"});
    if let Some(e) = email {
        body["email"] = json!(e);
    }
    let (s, v) = app.call("POST", PERSONS, Some(boss), Some(body)).await;
    assert_eq!(s, StatusCode::CREATED, "{v}");
    v
}

async fn link_for(app: &TestApp, boss: &str, id: &str, body: Value) -> (StatusCode, Value) {
    app.call(
        "POST",
        &format!("{PERSONS}/{id}/sign-in-link"),
        Some(boss),
        Some(body),
    )
    .await
}

#[tokio::test]
async fn manager_adds_a_person_without_email_and_creates_a_link() {
    let app = TestApp::new().await;
    let boss = app.token_for(CORA, true);
    let p = new_person(&app, &boss, "Rosa Rakoto", None).await;
    assert_eq!(p["email"], "rosa.rakoto@xynotransit.internal");
    assert_eq!(p["full_name"], "Rosa Rakoto");
    assert_eq!(p["active"], true);
    assert_eq!(p["app_role"], "contributor");
    let id = p["id"].as_str().unwrap();

    let (s, v) = link_for(&app, &boss, id, json!({})).await;
    assert_eq!(s, StatusCode::CREATED, "{v}");
    assert_eq!(v["person_id"], id);
    let url = v["url"].as_str().unwrap();
    assert!(
        url.starts_with("http://127.0.0.1:8080/auth/verify?token="),
        "{url}"
    );
    let token = token_of(url);
    assert_eq!(token.len(), 43, "32 random bytes, url safe base64");
    // The default life is 24 hours and the stamp is RFC 3339 in UTC.
    let exp = chrono::DateTime::parse_from_rfc3339(v["expires_at"].as_str().unwrap()).unwrap();
    let secs = (exp.with_timezone(&chrono::Utc) - chrono::Utc::now()).num_seconds();
    assert!((24 * 3600 - 30..=24 * 3600 + 5).contains(&secs), "{secs}");
    assert!(v["expires_at"].as_str().unwrap().ends_with('Z'));
    assert_eq!(v.as_object().unwrap().len(), 3, "{v}");

    // Works exactly once and gives a session of that person.
    let (s, session) = verify(&app, &token).await;
    assert_eq!(s, StatusCode::OK, "{session}");
    assert_eq!(session["user"]["person_id"], id);
    assert_eq!(session["user"]["role"], "contributor");
    let at = session["access_token"].as_str().unwrap();
    let (s, me) = app.call("GET", "/api/me", Some(at), None).await;
    assert_eq!(s, StatusCode::OK);
    assert_eq!(me["person_id"], id);
    let (s, v) = verify(&app, &token).await;
    assert_eq!(s, StatusCode::UNAUTHORIZED, "{v}");
    // No mail was ever involved.
    assert!(app.state.mailer.sent().is_empty());
}

#[tokio::test]
async fn link_lifetimes_and_validation() {
    let app = TestApp::new().await;
    let boss = app.token_for(CORA, true);
    for (hours, want) in [(1, 3600), (168, 168 * 3600), (7, 7 * 3600)] {
        let (s, v) = link_for(&app, &boss, ANA, json!({"hours": hours})).await;
        assert_eq!(s, StatusCode::CREATED, "{v}");
        let exp = chrono::DateTime::parse_from_rfc3339(v["expires_at"].as_str().unwrap()).unwrap();
        let secs = (exp.with_timezone(&chrono::Utc) - chrono::Utc::now()).num_seconds();
        assert!((want - 30..=want + 5).contains(&secs), "{hours}: {secs}");
    }
    for bad in [
        json!({"hours": 0}),
        json!({"hours": 169}),
        json!({"hours": -1}),
        json!({"hours": 2.5}),
        json!({"hours": "24"}),
        json!({"hours": true}),
        json!({"hours": 99999999999999i64}),
    ] {
        let (s, v) = link_for(&app, &boss, ANA, bad.clone()).await;
        assert_eq!(s, StatusCode::BAD_REQUEST, "{bad}: {v}");
        assert_eq!(v["error"], "Choose a validity from 1 hour to 168 hours.");
    }
    // null means the default.
    let (s, _) = link_for(&app, &boss, ANA, json!({"hours": null})).await;
    assert_eq!(s, StatusCode::CREATED);
    // The bad ones made no audit row; the four good ones did.
    assert_eq!(app.count("sign_in_link_audit").await, 4);
}

#[tokio::test]
async fn a_second_link_does_not_revoke_the_first() {
    let app = TestApp::new().await;
    let boss = app.token_for(CORA, true);
    let (_, a) = link_for(&app, &boss, ANA, json!({})).await;
    let (_, b) = link_for(&app, &boss, ANA, json!({})).await;
    assert_ne!(a["url"], b["url"]);
    assert_eq!(
        verify(&app, &token_of(a["url"].as_str().unwrap())).await.0,
        StatusCode::OK
    );
    assert_eq!(
        verify(&app, &token_of(b["url"].as_str().unwrap())).await.0,
        StatusCode::OK
    );
}

#[tokio::test]
async fn expired_link_is_refused() {
    let app = TestApp::new().await;
    let boss = app.token_for(CORA, true);
    let (_, v) = link_for(&app, &boss, ANA, json!({"hours": 1})).await;
    app.sql("update login_token set expires_at = now() - interval '1 second'")
        .await;
    let (s, e) = verify(&app, &token_of(v["url"].as_str().unwrap())).await;
    assert_eq!(s, StatusCode::UNAUTHORIZED, "{e}");
    assert_eq!(
        e["error"],
        "This link has expired or was already used. Ask for a new one."
    );
}

#[tokio::test]
async fn who_may_ask_and_for_whom() {
    let app = TestApp::new().await;
    let boss = app.token_for(CORA, true);
    let ana = app.token_for(ANA, false);
    let (s, v) = link_for(&app, &ana, BEN, json!({})).await;
    assert_eq!(s, StatusCode::FORBIDDEN, "{v}");
    assert_eq!(v["error"], "Only the controller can do this.");
    let (s, _) = link_for(&app, &ana, ANA, json!({})).await;
    assert_eq!(s, StatusCode::FORBIDDEN, "not even for themselves");
    let (s, _) = app
        .call(
            "POST",
            &format!("{PERSONS}/{BEN}/sign-in-link"),
            None,
            Some(json!({})),
        )
        .await;
    assert_eq!(s, StatusCode::UNAUTHORIZED);
    // Switched off (Dan is inactive in the fixture).
    let (s, v) = link_for(
        &app,
        &boss,
        "00000000-0000-0000-0000-0000000000a4",
        json!({}),
    )
    .await;
    assert_eq!(s, StatusCode::CONFLICT, "{v}");
    assert_eq!(v["error"], "This person is switched off.");
    // Unknown, and not even a uuid.
    let (s, v) = link_for(
        &app,
        &boss,
        "00000000-0000-0000-0000-00000000ffff",
        json!({}),
    )
    .await;
    assert_eq!(s, StatusCode::NOT_FOUND, "{v}");
    let (s, _) = link_for(&app, &boss, "not-a-uuid", json!({})).await;
    assert_eq!(s, StatusCode::NOT_FOUND);
    // A manager may ask for another manager and for themselves.
    let (s, _) = link_for(&app, &boss, CORA, json!({})).await;
    assert_eq!(s, StatusCode::CREATED);
    // A person switched off after getting a link cannot use it.
    let (_, v) = link_for(&app, &boss, ANA, json!({})).await;
    app.call(
        "PATCH",
        &format!("{PERSONS}/{ANA}"),
        Some(&boss),
        Some(json!({"active": false})),
    )
    .await;
    let (s, _) = verify(&app, &token_of(v["url"].as_str().unwrap())).await;
    assert_eq!(s, StatusCode::UNAUTHORIZED);
    // Refusals created no link.
    assert_eq!(app.count("sign_in_link_audit").await, 2);
}

#[tokio::test]
async fn the_31st_link_in_an_hour_is_refused_per_manager() {
    let app = TestApp::new().await;
    let boss = app.token_for(CORA, true);
    for i in 0..30 {
        let (s, v) = link_for(&app, &boss, ANA, json!({"hours": 1})).await;
        assert_eq!(s, StatusCode::CREATED, "link {i}: {v}");
    }
    let (s, v) = link_for(&app, &boss, BEN, json!({})).await;
    assert_eq!(s, StatusCode::TOO_MANY_REQUESTS, "{v}");
    assert_eq!(
        v["error"],
        "Too many sign-in links created. Try again later."
    );
    assert_eq!(app.count("sign_in_link_audit").await, 30);
    // Another manager has their own count.
    app.sql("update person set app_role = 'controller' where id = '00000000-0000-0000-0000-0000000000a2'")
        .await;
    let ben = app.token_for(BEN, true);
    let (s, _) = link_for(&app, &ben, ANA, json!({})).await;
    assert_eq!(s, StatusCode::CREATED);
    // After an hour the window has moved on.
    app.sql("update sign_in_link_audit set issued_at = now() - interval '61 minutes', expires_at = now() - interval '1 minute' where issued_by = '00000000-0000-0000-0000-0000000000a3'")
        .await;
    let (s, _) = link_for(&app, &boss, ANA, json!({})).await;
    assert_eq!(s, StatusCode::CREATED);
}

#[tokio::test]
async fn parallel_requests_cannot_pass_the_limit() {
    let app = TestApp::new().await;
    let boss = app.token_for(CORA, true);
    let calls = (0..40).map(|_| link_for(&app, &boss, ANA, json!({"hours": 1})));
    let results = futures_util::future::join_all(calls).await;
    let ok = results
        .iter()
        .filter(|r| r.0 == StatusCode::CREATED)
        .count();
    let limited = results
        .iter()
        .filter(|r| r.0 == StatusCode::TOO_MANY_REQUESTS)
        .count();
    assert_eq!((ok, limited), (30, 10));
    assert_eq!(app.count("sign_in_link_audit").await, 30);
}

#[tokio::test]
#[allow(clippy::type_complexity)]
async fn audit_rows_exist_and_never_hold_a_token() {
    let app = TestApp::new().await;
    let boss = app.token_for(CORA, true);
    let (_, a) = link_for(&app, &boss, ANA, json!({"hours": 2})).await;
    let (_, b) = link_for(&app, &boss, BEN, json!({"hours": 5})).await;
    assert_eq!(app.count("sign_in_link_audit").await, 2);
    let rows: Vec<(
        uuid::Uuid,
        Option<uuid::Uuid>,
        chrono::DateTime<chrono::Utc>,
        chrono::DateTime<chrono::Utc>,
    )> = sqlx::query_as(
        "select person_id, issued_by, issued_at, expires_at from sign_in_link_audit order by id",
    )
    .fetch_all(&app.state.pool)
    .await
    .unwrap();
    assert_eq!(rows[0].0.to_string(), ANA);
    assert_eq!(rows[1].0.to_string(), BEN);
    assert_eq!(rows[0].1.unwrap().to_string(), CORA);
    assert_eq!((rows[0].3 - rows[0].2).num_hours(), 2);
    assert_eq!((rows[1].3 - rows[1].2).num_hours(), 5);
    assert_eq!(
        rows[0].3.to_rfc3339_opts(chrono::SecondsFormat::Secs, true),
        a["expires_at"].as_str().unwrap()
    );
    // Neither the token nor its hash is anywhere in the audit table, nor is the token stored
    // anywhere in the database in clear.
    let dump: String = sqlx::query_scalar(
        "select coalesce(string_agg(t::text, ' '), '') from sign_in_link_audit t",
    )
    .fetch_one(&app.state.pool)
    .await
    .unwrap();
    let columns: Vec<String> = sqlx::query_scalar(
        "select column_name::text from information_schema.columns where table_name = 'sign_in_link_audit'",
    )
    .fetch_all(&app.state.pool)
    .await
    .unwrap();
    assert!(
        !columns
            .iter()
            .any(|c| c.contains("token") || c.contains("hash")),
        "{columns:?}"
    );
    for v in [&a, &b] {
        let token = token_of(v["url"].as_str().unwrap());
        assert!(!dump.contains(&token));
        let hash = hex_of(&xynotransit_api::auth::hash_token(&token));
        assert!(!dump.contains(&hash));
        let n: i64 = sqlx::query_scalar(
            "select count(*) from login_token where encode(token_hash, 'hex') = $1",
        )
        .bind(&hash)
        .fetch_one(&app.state.pool)
        .await
        .unwrap();
        assert_eq!(n, 1, "only the hash is stored in login_token");
        let leaked: i64 = sqlx::query_scalar("select count(*) from login_token where encode(token_hash, 'escape') like '%' || $1 || '%'")
            .bind(&token)
            .fetch_one(&app.state.pool)
            .await
            .unwrap();
        assert_eq!(leaked, 0);
    }
}

fn hex_of(b: &[u8]) -> String {
    b.iter().map(|x| format!("{x:02x}")).collect()
}

#[tokio::test]
async fn people_without_email_get_unique_internal_addresses() {
    let app = TestApp::new().await;
    let boss = app.token_for(CORA, true);
    let cases = [
        ("Rosa Rakoto", "rosa.rakoto@xynotransit.internal"),
        ("rosa  RAKOTO", "rosa.rakoto2@xynotransit.internal"),
        ("Rosa Rakoto ", "rosa.rakoto3@xynotransit.internal"),
        ("Zoë Müller-Ñandú", "zoe.mullernandu@xynotransit.internal"),
        ("田中太郎", "user@xynotransit.internal"),
        ("王小明", "user2@xynotransit.internal"),
        ("Mireille N'Diaye", "mireille.ndiaye@xynotransit.internal"),
    ];
    for (name, want) in cases {
        let p = new_person(&app, &boss, name, None).await;
        assert_eq!(p["email"], want, "{name}");
    }
    // Blank and whitespace count as missing; null too.
    let p = new_person(&app, &boss, "Blank One", Some("   ")).await;
    assert_eq!(p["email"], "blank.one@xynotransit.internal");
    let (s, p) = app
        .call(
            "POST",
            PERSONS,
            Some(&boss),
            Some(json!({"full_name": "Null One", "email": null, "app_role": "controller"})),
        )
        .await;
    assert_eq!(s, StatusCode::CREATED, "{p}");
    assert_eq!(p["email"], "null.one@xynotransit.internal");
    assert_eq!(p["app_role"], "controller");
    // A very long name stays within 40 characters before the @, also with a number.
    let long = "Maximilian Bartholomew Montgomery Featherstonehaugh";
    let a = new_person(&app, &boss, long, None).await;
    let b = new_person(&app, &boss, long, None).await;
    for p in [&a, &b] {
        let e = p["email"].as_str().unwrap();
        assert!(e.split('@').next().unwrap().len() <= 40, "{e}");
    }
    assert_ne!(a["email"], b["email"]);
    assert!(b["email"].as_str().unwrap().contains("2@"));
    // A name that someone already took with a typed address.
    new_person(
        &app,
        &boss,
        "Typed",
        Some("lea.dupont@xynotransit.internal"),
    )
    .await;
    let p = new_person(&app, &boss, "Léa Dupont", None).await;
    assert_eq!(p["email"], "lea.dupont2@xynotransit.internal");
    // The catalog shows the address to a manager, as for everyone.
    let (_, cat) = app.call("GET", "/api/catalog", Some(&boss), None).await;
    assert!(cat["persons"]
        .as_array()
        .unwrap()
        .iter()
        .any(|p| p["email"] == "rosa.rakoto@xynotransit.internal"));
}

#[tokio::test]
async fn parallel_creation_without_email_never_collides() {
    let app = TestApp::new().await;
    let boss = app.token_for(CORA, true);
    let calls = (0..12).map(|_| {
        app.call(
            "POST",
            PERSONS,
            Some(&boss),
            Some(json!({"full_name": "Twin Name", "app_role": "contributor"})),
        )
    });
    let results = futures_util::future::join_all(calls).await;
    let mut emails: Vec<String> = results
        .iter()
        .map(|(s, v)| {
            assert_eq!(*s, StatusCode::CREATED, "{v}");
            v["email"].as_str().unwrap().to_string()
        })
        .collect();
    emails.sort();
    emails.dedup();
    assert_eq!(emails.len(), 12);
}

#[tokio::test]
async fn typed_email_rules_are_unchanged() {
    let app = TestApp::new().await;
    let boss = app.token_for(CORA, true);
    // An internal address typed by hand is accepted as typed (trimmed and lowercased as always).
    let p = new_person(
        &app,
        &boss,
        "Hand Typed",
        Some(" Odd.Name@Xynotransit.Internal "),
    )
    .await;
    assert_eq!(p["email"], "odd.name@xynotransit.internal");
    for bad in ["nope", "a@b", "a b@x.org", "x@@y.org"] {
        let (s, v) = app
            .call(
                "POST",
                PERSONS,
                Some(&boss),
                Some(json!({"full_name": "Bad", "email": bad, "app_role": "contributor"})),
            )
            .await;
        assert_eq!(s, StatusCode::BAD_REQUEST, "{bad}: {v}");
    }
    let (s, v) = app
        .call(
            "POST",
            PERSONS,
            Some(&boss),
            Some(
                json!({"full_name": "Twin", "email": "ana@example.org", "app_role": "contributor"}),
            ),
        )
        .await;
    assert_eq!(s, StatusCode::CONFLICT, "{v}");
    assert_eq!(v["error"], "That email is already used.");
    // Missing full_name or role is still refused.
    let (s, _) = app
        .call(
            "POST",
            PERSONS,
            Some(&boss),
            Some(json!({"app_role": "contributor"})),
        )
        .await;
    assert_eq!(
        s,
        StatusCode::UNPROCESSABLE_ENTITY
            .min(StatusCode::BAD_REQUEST)
            .max(StatusCode::BAD_REQUEST)
    );
    // Employees cannot create people, with or without an email.
    let ana = app.token_for(ANA, false);
    let (s, _) = app
        .call(
            "POST",
            PERSONS,
            Some(&ana),
            Some(json!({"full_name": "X Y", "app_role": "contributor"})),
        )
        .await;
    assert_eq!(s, StatusCode::FORBIDDEN);
}

#[tokio::test]
async fn first_configured_domain_is_used_and_others_are_internal_too() {
    let app = TestApp::new().await;
    let mut cfg = (*app.state.config).clone();
    cfg.internal_email_domains = vec!["corp.internal".into(), "field.local".into()];
    let state = AppState::new(app.state.pool.clone(), cfg, Mailer::capture());
    let router = build_router(state.clone());
    let boss = app.token_for(CORA, true);
    let call = |m: &'static str, uri: &'static str, tok: Option<String>, b: Value| {
        let router = router.clone();
        async move {
            use tower::ServiceExt;
            let mut r = axum::http::Request::builder()
                .method(m)
                .uri(uri)
                .header("content-type", "application/json");
            if let Some(t) = tok {
                r = r.header("authorization", format!("Bearer {t}"));
            }
            let res = router
                .oneshot(r.body(axum::body::Body::from(b.to_string())).unwrap())
                .await
                .unwrap();
            let s = res.status();
            let bytes = http_body_util::BodyExt::collect(res.into_body())
                .await
                .unwrap()
                .to_bytes();
            (
                s,
                serde_json::from_slice::<Value>(&bytes).unwrap_or(Value::Null),
            )
        }
    };
    let (s, p) = call(
        "POST",
        "/api/persons",
        Some(boss.clone()),
        json!({"full_name": "Jo Ann", "app_role": "contributor"}),
    )
    .await;
    assert_eq!(s, StatusCode::CREATED, "{p}");
    assert_eq!(p["email"], "jo.ann@corp.internal");
    let (s, p) = call(
        "POST",
        "/api/persons",
        Some(boss.clone()),
        json!({"full_name": "Pat", "email": "pat@field.local", "app_role": "contributor"}),
    )
    .await;
    assert_eq!(s, StatusCode::CREATED, "{p}");
    // Both domains send no mail; the old default domain is a normal one now.
    for e in [
        "jo.ann@corp.internal",
        "pat@field.local",
        "someone@xynotransit.internal",
    ] {
        let (s, _) = call("POST", "/api/auth/magic-link", None, json!({"email": e})).await;
        assert_eq!(s, StatusCode::ACCEPTED);
    }
    assert!(state.mailer.sent().is_empty(), "{:?}", state.mailer.sent());
    let (s, _) = call(
        "POST",
        "/api/auth/magic-link",
        None,
        json!({"email": "ana@example.org"}),
    )
    .await;
    assert_eq!(s, StatusCode::ACCEPTED);
    assert_eq!(state.mailer.sent().len(), 1);
}

#[tokio::test]
async fn internal_magic_link_request_sends_no_mail_and_answers_alike() {
    let app = TestApp::new().await;
    let boss = app.token_for(CORA, true);
    let p = new_person(&app, &boss, "Rosa Rakoto", None).await;
    let email = p["email"].as_str().unwrap();
    let (s, v) = app
        .call(
            "POST",
            "/api/auth/magic-link",
            None,
            Some(json!({"email": email})),
        )
        .await;
    assert_eq!((s, v), (StatusCode::ACCEPTED, json!({})));
    let (s, v) = app
        .call(
            "POST",
            "/api/auth/magic-link",
            None,
            Some(json!({"email": "NOBODY@Xynotransit.Internal"})),
        )
        .await;
    assert_eq!((s, v), (StatusCode::ACCEPTED, json!({})));
    assert!(app.state.mailer.sent().is_empty());
    // Still validated like any address.
    let (s, _) = app
        .call(
            "POST",
            "/api/auth/magic-link",
            None,
            Some(json!({"email": "no at sign.internal"})),
        )
        .await;
    assert_eq!(s, StatusCode::BAD_REQUEST);
    // A look-alike domain is a real domain: it gets mail.
    let (s, _) = app
        .call(
            "POST",
            "/api/auth/magic-link",
            None,
            Some(json!({"email": "ana@xynotransit.internal.example.org"})),
        )
        .await;
    assert_eq!(s, StatusCode::ACCEPTED);
}

#[tokio::test]
async fn rate_limit_is_the_same_for_internal_and_external_addresses() {
    let app = TestApp::new().await;
    let boss = app.token_for(CORA, true);
    let p = new_person(&app, &boss, "Rosa Rakoto", None).await;
    let known_internal = p["email"].as_str().unwrap().to_string();
    for email in [
        known_internal.as_str(),
        "ghost@xynotransit.internal",
        "ana@example.org",
        "ghost@example.org",
    ] {
        let mut seen = Vec::new();
        for _ in 0..7 {
            let (s, _) = app
                .call(
                    "POST",
                    "/api/auth/magic-link",
                    None,
                    Some(json!({"email": email})),
                )
                .await;
            seen.push(s.as_u16());
        }
        assert_eq!(seen, [202, 202, 202, 202, 202, 429, 429], "{email}");
        // Keyed by the string: another case of the same address shares the count.
        let (s, v) = app
            .call(
                "POST",
                "/api/auth/magic-link",
                None,
                Some(json!({"email": email.to_uppercase()})),
            )
            .await;
        assert_eq!(s, StatusCode::TOO_MANY_REQUESTS);
        assert_eq!(v["error"], "Too many links requested. Try again later.");
    }
    // Only the external known address produced mail.
    assert_eq!(app.state.mailer.sent().len(), 5);
    assert!(app
        .state
        .mailer
        .sent()
        .iter()
        .all(|m| m.to == "ana@example.org"));
}

#[tokio::test]
async fn internal_person_behaves_like_any_other_person() {
    let app = TestApp::new().await;
    let boss = app.token_for(CORA, true);
    let p = new_person(&app, &boss, "Rosa Rakoto", None).await;
    let id = p["id"].as_str().unwrap().to_string();
    let (_, v) = link_for(&app, &boss, &id, json!({})).await;
    let (_, session) = verify(&app, &token_of(v["url"].as_str().unwrap())).await;
    let t = session["access_token"].as_str().unwrap();
    // Employee rights only.
    let (s, _) = app
        .call(
            "POST",
            PERSONS,
            Some(t),
            Some(json!({"full_name": "X Y", "app_role": "contributor"})),
        )
        .await;
    assert_eq!(s, StatusCode::FORBIDDEN);
    let (s, _) = app.call("GET", "/api/catalog", Some(t), None).await;
    assert_eq!(s, StatusCode::OK);
    // Seats and rename work; the address stays as typed.
    let (s, v) = app
        .call(
            "PATCH",
            &format!("{PERSONS}/{id}"),
            Some(&boss),
            Some(json!({"full_name": "Rosa R."})),
        )
        .await;
    assert_eq!(s, StatusCode::OK, "{v}");
    assert_eq!(v["email"], "rosa.rakoto@xynotransit.internal");
    // Switched off: the token stops working at once.
    app.call(
        "PATCH",
        &format!("{PERSONS}/{id}"),
        Some(&boss),
        Some(json!({"active": false})),
    )
    .await;
    let (s, _) = app.call("GET", "/api/me", Some(t), None).await;
    assert_eq!(s, StatusCode::UNAUTHORIZED);
}

// ---------- the server command ----------

struct Run {
    code: i32,
    out: String,
    err: String,
}

async fn run_cli(app: &TestApp, args: &[&str], database_url: Option<&str>) -> Run {
    let args: Vec<String> = args.iter().map(|s| s.to_string()).collect();
    let url = database_url.map(str::to_string);
    let public = "https://reports.example.org/".to_string();
    let _ = app;
    tokio::task::spawn_blocking(move || {
        let mut cmd = std::process::Command::new(env!("CARGO_BIN_EXE_xynotransit-api"));
        cmd.arg("sign-in-link")
            .args(&args)
            .env_clear()
            .env("PUBLIC_URL", public);
        if let Some(u) = url {
            cmd.env("DATABASE_URL", u);
        }
        let o = cmd.output().unwrap();
        Run {
            code: o.status.code().unwrap(),
            out: String::from_utf8(o.stdout).unwrap(),
            err: String::from_utf8(o.stderr).unwrap(),
        }
    })
    .await
    .unwrap()
}

#[tokio::test]
async fn command_prints_only_the_url_and_the_link_works_once() {
    let app = TestApp::new().await;
    let db = app.state.config.database_url.clone();
    let r = run_cli(&app, &["Cora@Example.org", "--hours", "3"], Some(&db)).await;
    assert_eq!(r.code, 0, "{}", r.err);
    assert!(r.err.is_empty(), "{}", r.err);
    assert!(
        r.out.ends_with('\n') && r.out.matches('\n').count() == 1,
        "{:?}",
        r.out
    );
    let url = r.out.trim_end();
    assert!(
        url.starts_with("https://reports.example.org/auth/verify?token="),
        "{url}"
    );
    assert!(!url.contains(char::is_whitespace));
    let (s, session) = verify(&app, &token_of(url)).await;
    assert_eq!(s, StatusCode::OK, "{session}");
    assert_eq!(session["user"]["person_id"], CORA);
    assert_eq!(session["user"]["role"], "controller");
    assert_eq!(
        verify(&app, &token_of(url)).await.0,
        StatusCode::UNAUTHORIZED
    );
    // Audit row: no issuer, three hours.
    let (by, hours): (Option<uuid::Uuid>, i64) = sqlx::query_as(
        "select issued_by, extract(epoch from expires_at - issued_at)::bigint / 3600 from sign_in_link_audit",
    )
    .fetch_one(&app.state.pool)
    .await
    .unwrap();
    assert_eq!((by, hours), (None, 3));
    assert_eq!(app.count("sign_in_link_audit").await, 1);
    // Default is 24 hours.
    let r = run_cli(&app, &["ana@example.org"], Some(&db)).await;
    assert_eq!(r.code, 0, "{}", r.err);
    let h: i64 = sqlx::query_scalar(
        "select max(extract(epoch from expires_at - issued_at)::bigint / 3600) from sign_in_link_audit",
    )
    .fetch_one(&app.state.pool)
    .await
    .unwrap();
    assert_eq!(h, 24);
}

#[tokio::test]
async fn command_bootstraps_the_first_manager_without_mail() {
    let app = TestApp::empty().await;
    xynotransit_api::bootstrap_controller(&app.state.pool, "manager@xynotransit.internal", None)
        .await
        .unwrap();
    let db = app.state.config.database_url.clone();
    let r = run_cli(
        &app,
        &["manager@xynotransit.internal", "--hours=24"],
        Some(&db),
    )
    .await;
    assert_eq!(r.code, 0, "{}", r.err);
    let (s, session) = verify(&app, &token_of(r.out.trim())).await;
    assert_eq!(s, StatusCode::OK, "{session}");
    assert_eq!(session["user"]["role"], "controller");
    assert_eq!(session["user"]["label"], "Manager");
    assert!(app.state.mailer.sent().is_empty());
}

#[tokio::test]
async fn command_failures_have_exit_codes_and_plain_messages() {
    let app = TestApp::new().await;
    let db = app.state.config.database_url.clone();
    let r = run_cli(&app, &["nobody@example.org"], Some(&db)).await;
    assert_eq!((r.code, r.out.as_str()), (1, ""));
    assert_eq!(r.err.trim(), "No person has the email nobody@example.org.");
    let r = run_cli(&app, &["dan@example.org"], Some(&db)).await;
    assert_eq!((r.code, r.out.as_str()), (1, ""));
    assert_eq!(
        r.err.trim(),
        "The person with the email dan@example.org is switched off."
    );
    for args in [
        &[][..],
        &["ana@example.org", "--hours", "0"],
        &["ana@example.org", "--hours", "169"],
        &["ana@example.org", "--hours", "x"],
        &["ana@example.org", "--hours"],
        &["ana@example.org", "ben@example.org"],
        &["ana@example.org", "--bogus"],
    ] {
        let r = run_cli(&app, args, Some(&db)).await;
        assert_eq!((r.code, r.out.as_str()), (2, ""), "{args:?}");
        assert!(
            r.err.contains("Usage: xynotransit-api sign-in-link"),
            "{}",
            r.err
        );
    }
    let r = run_cli(&app, &["ana@example.org"], None).await;
    assert_eq!((r.code, r.out.as_str()), (1, ""));
    assert_eq!(r.err.trim(), "DATABASE_URL is not set.");
    let r = run_cli(
        &app,
        &["ana@example.org"],
        Some("postgres://x:y@127.0.0.1:1/none"),
    )
    .await;
    assert_eq!((r.code, r.out.as_str()), (1, ""));
    assert_eq!(
        r.err.trim(),
        "Could not reach the database. Check DATABASE_URL."
    );
    assert!(
        !r.err.contains("postgres://"),
        "no connection string in the message"
    );
    // None of the failures made a link.
    assert_eq!(app.count("sign_in_link_audit").await, 0);
    assert_eq!(app.count("login_token").await, 0);
}

#[tokio::test]
async fn migration_runs_twice_and_old_tokens_stay_valid() {
    let app = TestApp::new().await;
    let sql = std::fs::read_to_string(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../xynotransit-db/initdb/10-internal-signin.sql"
    ))
    .unwrap();
    let boss = app.token_for(CORA, true);
    let (_, v) = link_for(&app, &boss, ANA, json!({})).await;
    sqlx::raw_sql(&sql).execute(&app.state.pool).await.unwrap();
    sqlx::raw_sql(&sql).execute(&app.state.pool).await.unwrap();
    assert_eq!(app.count("sign_in_link_audit").await, 1);
    assert_eq!(
        verify(&app, &token_of(v["url"].as_str().unwrap())).await.0,
        StatusCode::OK
    );
    let n = app
        .scalar("select count(*) from schema_migration where file = '10-internal-signin.sql'")
        .await;
    assert_eq!(n, 1);
    // A manager who is deleted leaves the audit rows with no issuer.
    app.sql("insert into person (id, full_name, email, app_role) values ('00000000-0000-0000-0000-0000000000e1', 'Temp Boss', 'temp@example.org', 'controller')").await;
    let temp = app.token_for("00000000-0000-0000-0000-0000000000e1", true);
    assert_eq!(
        link_for(&app, &temp, ANA, json!({})).await.0,
        StatusCode::CREATED
    );
    app.sql("delete from person where id = '00000000-0000-0000-0000-0000000000e1'")
        .await;
    assert_eq!(
        app.scalar("select count(*) from sign_in_link_audit where issued_by is null")
            .await,
        1
    );
    // A person who is deleted takes their audit rows along.
    app.sql("delete from login_token").await;
    app.sql("insert into person (id, full_name, email) values ('00000000-0000-0000-0000-0000000000e2', 'Temp Two', 'two@example.org')").await;
    assert_eq!(
        link_for(
            &app,
            &boss,
            "00000000-0000-0000-0000-0000000000e2",
            json!({})
        )
        .await
        .0,
        StatusCode::CREATED
    );
    app.sql("delete from person where id = '00000000-0000-0000-0000-0000000000e2'")
        .await;
    assert_eq!(app.count("sign_in_link_audit").await, 2);
}
