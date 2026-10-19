//! Usernames and passwords: sign in, change, reset, remove, the limits, the sessions, the audit
//! trail, the migration and the server command. Argon2 runs with cheap parameters here
//! (PASSWORD_HASH_* in tests/common), except in the tests that say otherwise.

mod common;

use std::{
    io::Write,
    process::{Command, Stdio},
    sync::{Arc, Mutex, OnceLock},
};

use axum::http::StatusCode;
use common::*;
use rand::{rngs::StdRng, Rng, SeedableRng};
use serde_json::{json, Value};
use sqlx::{postgres::PgPoolOptions, Connection, PgConnection};
use xynotransit_api::{build_router, hashing::Hasher};

const DAN: &str = "00000000-0000-0000-0000-0000000000a4";
const PW: &str = "purple bicycle rain";
const PW2: &str = "orange walrus piano";

fn bearer(v: &Value) -> String {
    v["access_token"].as_str().unwrap().to_string()
}

async fn status_of(
    app: &TestApp,
    method: &str,
    uri: &str,
    tok: &str,
    body: Option<Value>,
) -> (StatusCode, Value) {
    app.call(method, uri, Some(tok), body).await
}

// ---------------------------------------------------------------------------------------------
// sign in
// ---------------------------------------------------------------------------------------------

#[tokio::test]
async fn people_have_usernames_and_no_password_to_begin_with() {
    let app = TestApp::new().await;
    let u: Vec<(String, String)> =
        sqlx::query_as("select email, username from person order by email")
            .fetch_all(&app.state.pool)
            .await
            .unwrap();
    assert_eq!(
        u,
        vec![
            ("ana@example.org".into(), "ana".into()),
            ("ben@example.org".into(), "ben".into()),
            ("cora@example.org".into(), "cora".into()),
            ("dan@example.org".into(), "dan".into()),
        ]
    );
    assert_eq!(
        app.scalar("select count(*) from person where password_hash is not null")
            .await,
        0
    );
    let (s, v) = app.password_login("ana", PW).await;
    assert_eq!(
        (s, v["error"].as_str()),
        (
            StatusCode::UNAUTHORIZED,
            Some("Username or password is wrong.")
        )
    );
}

#[tokio::test]
async fn login_works_and_every_failure_looks_the_same() {
    let app = TestApp::new().await;
    app.give_password(ANA, "ana", PW).await;
    app.sql(&format!(
        "update person set active = true where id = '{DAN}'"
    ))
    .await;
    app.give_password(DAN, "dan", PW).await;
    // Dan is switched off after he got his password.
    app.sql(&format!(
        "update person set active = false where id = '{DAN}'"
    ))
    .await;
    app.give_password_hash_only(BEN, "ben", "never used").await;

    let (s, v) = app.password_login("ana", PW).await;
    assert_eq!(s, StatusCode::OK, "{v}");
    assert_eq!(
        v["user"],
        json!({"person_id": ANA, "role": "contributor", "label": "Ana Rakoto"})
    );
    assert_eq!(v["must_change_password"], false);
    assert_eq!(v["has_password"], true);
    assert!(v["expires_at"].as_str().unwrap().ends_with('Z'));
    let tok = bearer(&v);
    let (s, me) = app.call("GET", "/api/me", Some(&tok), None).await;
    assert_eq!(s, StatusCode::OK);
    assert_eq!(me["username"], "ana");
    assert_eq!(me["has_password"], true);
    assert_eq!(me["must_change_password"], false);
    // Case of the name does not matter, spaces around it neither; the password is exact.
    assert_eq!(app.password_login("  ANA ", PW).await.0, StatusCode::OK);
    assert_eq!(
        app.password_login("ana", &PW.to_uppercase()).await.0,
        StatusCode::UNAUTHORIZED
    );
    assert_eq!(
        app.password_login("ana", &format!("{PW} ")).await.0,
        StatusCode::UNAUTHORIZED
    );

    let want = json!({"error": "Username or password is wrong."});
    for (who, pw) in [
        ("ana", "wrong password here"), // wrong password
        ("nobody.here", PW),            // unknown name
        ("dan", PW),                    // switched off
        ("ben", "never used"),          // hmm: ben has a hash but for another password text
        ("cora", PW),                   // no password at all
        ("", ""),
        ("ana", &"x".repeat(5000)), // far too long to be a password
        (&"u".repeat(5000), PW),
    ] {
        let (s, v) = app.password_login(who, pw).await;
        if who == "ben" {
            // The hash exists and the typed text is its password: that one is allowed in.
            assert_eq!(s, StatusCode::OK);
            continue;
        }
        assert_eq!((s, &v), (StatusCode::UNAUTHORIZED, &want), "{who:?}");
    }
    // Bad request shapes are plain 400s.
    for body in [
        json!({}),
        json!({"username": "ana"}),
        json!({"username": 1, "password": 2}),
        json!([]),
    ] {
        let (s, v) = app.call("POST", "/api/auth/login", None, Some(body)).await;
        assert_eq!(s, StatusCode::BAD_REQUEST, "{v}");
    }
}

impl TestApp {
    /// Store a hash for a person directly (no policy, no must-change), for tests of the login.
    async fn give_password_hash_only(&self, person_id: &str, _username: &str, password: &str) {
        let hash = self.state.hasher.hash(password).await.unwrap();
        sqlx::query("update person set password_hash = $2 where id = $1::uuid")
            .bind(person_id)
            .bind(hash)
            .execute(&self.state.pool)
            .await
            .unwrap();
    }
}

#[tokio::test]
async fn the_link_answer_says_whether_there_is_a_password() {
    let app = TestApp::new().await;
    let link = |email: &'static str| {
        let app = &app;
        async move {
            let before = app.state.mailer.sent().len();
            app.call(
                "POST",
                "/api/auth/magic-link",
                None,
                Some(json!({"email": email})),
            )
            .await;
            let sent = app.state.mailer.sent();
            let token = sent[before]
                .link
                .split("token=")
                .nth(1)
                .unwrap()
                .to_string();
            app.call(
                "POST",
                "/api/auth/verify",
                None,
                Some(json!({"token": token})),
            )
            .await
        }
    };
    let (s, v) = link("ana@example.org").await;
    assert_eq!(s, StatusCode::OK);
    assert_eq!(
        (&v["has_password"], &v["must_change_password"]),
        (&json!(false), &json!(false))
    );
    app.give_password(ANA, "ana", PW).await;
    let (_, v) = link("ana@example.org").await;
    assert_eq!(
        (&v["has_password"], &v["must_change_password"]),
        (&json!(true), &json!(false))
    );
    // The link still works for someone with a temporary password; the gate still applies.
    let m = app.token_for(CORA, true);
    app.call(
        "POST",
        &format!("/api/persons/{ANA}/password-reset"),
        Some(&m),
        Some(json!({})),
    )
    .await;
    let (_, v) = link("ana@example.org").await;
    assert_eq!(
        (&v["has_password"], &v["must_change_password"]),
        (&json!(true), &json!(true))
    );
    let (s, _) = app
        .call("GET", "/api/catalog", Some(&bearer(&v)), None)
        .await;
    assert_eq!(s, StatusCode::FORBIDDEN);
}

// ---------------------------------------------------------------------------------------------
// limits
//
// Public addresses used below: A = 203.0.113.7 (the attacker), B = 203.0.113.8 (the person),
// both as the socket peer. The tests in tests/common write rows with the same keys the API uses.
// ---------------------------------------------------------------------------------------------

const A: &str = "203.0.113.7";
const B: &str = "203.0.113.8";
const TOO_MANY: &str = "Too many sign-in attempts. Try again later.";

async fn try_login(
    app: &TestApp,
    who: &str,
    password: &str,
    peer: &str,
    xff: Option<&str>,
) -> (StatusCode, Option<u64>, Value) {
    let (s, h, v) = app
        .call_from(
            "POST",
            "/api/auth/login",
            None,
            Some(json!({"username": who, "password": password})),
            peer,
            xff,
        )
        .await;
    let ra = h
        .get("retry-after")
        .map(|v| v.to_str().unwrap().parse().unwrap());
    (s, ra, v)
}

async fn fail_from(app: &TestApp, who: &str, peer: &str) -> (StatusCode, Option<u64>, Value) {
    try_login(app, who, "definitely not it", peer, None).await
}

/// A wrong try with no socket at all: the address is unknown.
async fn fail(app: &TestApp, who: &str) -> (StatusCode, Option<u64>, Value) {
    let (s, v) = app.password_login(who, "definitely not it").await;
    (s, None, v)
}

async fn many_logins(app: &TestApp, who: &str, peer: Option<&str>, n: usize) -> Vec<StatusCode> {
    let mut set = tokio::task::JoinSet::new();
    for _ in 0..n {
        let router = app.router.clone();
        let body = json!({"username": who, "password": "not the one"}).to_string();
        let peer = peer.map(|p| {
            format!("{p}:40000")
                .parse::<std::net::SocketAddr>()
                .unwrap()
        });
        set.spawn(async move {
            use tower::ServiceExt;
            let mut req = axum::http::Request::builder()
                .method("POST")
                .uri("/api/auth/login")
                .header("content-type", "application/json")
                .body(axum::body::Body::from(body))
                .unwrap();
            if let Some(p) = peer {
                req.extensions_mut().insert(axum::extract::ConnectInfo(p));
            }
            router.oneshot(req).await.unwrap().status()
        });
    }
    let mut codes = vec![];
    while let Some(r) = set.join_next().await {
        codes.push(r.unwrap());
    }
    codes
}

#[tokio::test]
async fn five_failures_lock_only_that_pair() {
    let app = TestApp::new().await;
    app.give_password(ANA, "ana", PW).await;
    app.give_password(BEN, "ben", PW).await;
    app.sql("delete from login_failure").await;
    for i in 0..5 {
        let (s, ra, v) = fail_from(&app, "ana", A).await;
        assert_eq!((s, ra), (StatusCode::UNAUTHORIZED, None), "try {i}: {v}");
    }
    let (s, ra, v) = fail_from(&app, "Ana", A).await;
    assert_eq!(s, StatusCode::TOO_MANY_REQUESTS);
    assert_eq!(v, json!({ "error": TOO_MANY }));
    let ra = ra.unwrap();
    assert!((890..=900).contains(&ra), "{ra}");
    // Even the right password is refused for that pair, and refusals are not counted again.
    assert_eq!(
        try_login(&app, "ana", PW, A, None).await.0,
        StatusCode::TOO_MANY_REQUESTS
    );
    assert_eq!(app.pair_failures("ana", Some(A)).await, 5);
    // Another name from the same address is not locked by the pair (and its success changes
    // nothing for ana).
    assert_eq!(try_login(&app, "ben", PW, A, None).await.0, StatusCode::OK);
    assert_eq!(
        fail_from(&app, "ana", A).await.0,
        StatusCode::TOO_MANY_REQUESTS
    );
    // The lock ends when the old failures leave the 15 minute window.
    app.sql("update login_failure set at = now() - interval '16 minutes'")
        .await;
    let (s, _, v) = try_login(&app, "ana", PW, A, None).await;
    assert_eq!(s, StatusCode::OK, "{v}");
}

#[tokio::test]
async fn an_attacker_at_address_a_cannot_lock_out_the_person_at_address_b() {
    let app = TestApp::new().await;
    app.give_password(CORA, "cora", PW).await;
    app.sql("delete from login_failure").await;
    // The attacker hits the manager's name until the pair is locked, and keeps hitting.
    for _ in 0..5 {
        assert_eq!(fail_from(&app, "cora", A).await.0, StatusCode::UNAUTHORIZED);
    }
    for _ in 0..3 {
        assert_eq!(
            fail_from(&app, "cora", A).await.0,
            StatusCode::TOO_MANY_REQUESTS
        );
    }
    // The person, from another address, signs in with the right password at once.
    let (s, ra, v) = try_login(&app, "cora", PW, B, None).await;
    assert_eq!((s, ra), (StatusCode::OK, None), "{v}");
    // ... also behind our own proxies (private peer, the client in X-Forwarded-For) ...
    assert_eq!(
        try_login(&app, "cora", PW, "172.18.0.3", Some("203.0.113.99"))
            .await
            .0,
        StatusCode::OK
    );
    // ... and a wrong try there is a plain 401, the person's own pair has room.
    assert_eq!(fail_from(&app, "cora", B).await.0, StatusCode::UNAUTHORIZED);
    // The attacker's address still has its pair locked, right password or not.
    assert_eq!(
        try_login(&app, "cora", PW, A, None).await.0,
        StatusCode::TOO_MANY_REQUESTS
    );
    // The attacker cannot borrow a made-up client address either: a public peer is the client.
    assert_eq!(
        try_login(&app, "cora", PW, A, Some(B)).await.0,
        StatusCode::TOO_MANY_REQUESTS
    );
    // Behind the proxy the attacker's true address (right-most public hop) is still the one that
    // counts, whatever is written to the left of it.
    assert_eq!(
        try_login(
            &app,
            "cora",
            PW,
            "172.18.0.3",
            Some("203.0.113.8, 203.0.113.7")
        )
        .await
        .0,
        StatusCode::TOO_MANY_REQUESTS
    );
}

#[tokio::test]
async fn unknown_names_behave_exactly_like_known_ones() {
    let app = TestApp::new().await;
    let mut unknown = vec![];
    for _ in 0..7 {
        let (s, ra, v) = fail_from(&app, "No.Such.Person", A).await;
        unknown.push((s, ra.is_some(), v));
    }
    let mut known = vec![];
    for _ in 0..7 {
        let (s, ra, v) = fail_from(&app, "cora", A).await;
        known.push((s, ra.is_some(), v));
    }
    assert_eq!(unknown, known);
    assert_eq!(unknown[4].0, StatusCode::UNAUTHORIZED);
    assert_eq!(unknown[5].0, StatusCode::TOO_MANY_REQUESTS);
    assert_eq!(unknown[5].2, json!({ "error": TOO_MANY }));
    // Case and spaces share one counter.
    assert_eq!(
        fail_from(&app, "  no.such.PERSON ", A).await.0,
        StatusCode::TOO_MANY_REQUESTS
    );
    // The same with no determinable address (the shared 'unknown' pair).
    let mut u2 = vec![];
    let mut k2 = vec![];
    for _ in 0..7 {
        let (s, _, v) = fail(&app, "ghost.user").await;
        u2.push((s, v));
        let (s, _, v) = fail(&app, "ben").await;
        k2.push((s, v));
    }
    assert_eq!(u2, k2);
    assert_eq!(u2[5].0, StatusCode::TOO_MANY_REQUESTS);
    // Even the answer to the right password is the same 429 for a known and an unknown name.
    let (s1, _, b1) = try_login(&app, "cora", PW, A, None).await;
    let (s2, _, b2) = try_login(&app, "no.such.person", PW, A, None).await;
    assert_eq!((s1, b1), (s2, b2));
}

#[tokio::test]
async fn success_clears_that_pair_only() {
    let app = TestApp::new().await;
    app.give_password(ANA, "ana", PW).await;
    app.sql("delete from login_failure").await;
    for _ in 0..4 {
        fail_from(&app, "ana", A).await;
        fail_from(&app, "ana", B).await;
        fail_from(&app, "ben", A).await;
    }
    assert_eq!(try_login(&app, "ana", PW, A, None).await.0, StatusCode::OK);
    assert_eq!(app.pair_failures("ana", Some(A)).await, 0);
    assert_eq!(app.pair_failures("ana", Some(B)).await, 4);
    assert_eq!(app.pair_failures("ben", Some(A)).await, 4);
}

#[tokio::test]
async fn retry_after_is_right_for_each_case() {
    let app = TestApp::new().await;
    // Pair: seven failures, ages in minutes. The lock lifts when only four are left in the
    // window, that is when the third oldest (9 minutes) is 15 minutes old: 6 minutes from now.
    for age in [14, 12, 9, 5, 3, 2, 1] {
        app.add_failure("ana", Some(A), age).await;
    }
    let (s, ra, _) = fail_from(&app, "ana", A).await;
    assert_eq!(s, StatusCode::TOO_MANY_REQUESTS);
    assert!((358..=361).contains(&ra.unwrap()), "{ra:?}");
    // Exactly five: the oldest one decides.
    app.sql("delete from login_failure").await;
    for age in [13, 10, 7, 4, 1] {
        app.add_failure("ana", Some(A), age).await;
    }
    let (s, ra, _) = fail_from(&app, "ana", A).await;
    assert_eq!(s, StatusCode::TOO_MANY_REQUESTS);
    assert!((118..=121).contains(&ra.unwrap()), "{ra:?}");

    // Address cap: 31 failures of many names, the first 2 minutes old: the 2nd place frees when
    // the second oldest (ages 12 and 11 are the two oldest) is out: 15 - 11 = 4 minutes.
    app.sql("delete from login_failure").await;
    app.add_failure("n0", Some(A), 12).await;
    app.add_failure("n1", Some(A), 11).await;
    for i in 2..31 {
        app.add_failure(&format!("n{i}"), Some(A), 1).await;
    }
    let (s, ra, _) = fail_from(&app, "fresh.name", A).await;
    assert_eq!(s, StatusCode::TOO_MANY_REQUESTS);
    assert!((238..=241).contains(&ra.unwrap()), "{ra:?}");

    // Backstop: 103 failures of one name from other addresses; four must expire to get below
    // 100: the fourth oldest decides (ages 14, 13, 10, then a 1 minute old one): 14 minutes.
    app.sql("delete from login_failure").await;
    for (i, age) in [14, 13, 10].iter().enumerate() {
        app.add_failure("ana", Some(&format!("198.51.100.{i}")), *age)
            .await;
    }
    for i in 0..100 {
        app.add_failure("ana", Some(&format!("198.51.101.{}", i % 50)), 1)
            .await;
    }
    let (s, ra, _) = fail_from(&app, "ana", "203.0.113.50").await;
    assert_eq!(s, StatusCode::TOO_MANY_REQUESTS);
    assert!((838..=841).contains(&ra.unwrap()), "{ra:?}");

    // Two limits at once: the longer wait is the answer (pair frees in 5 minutes, backstop later).
    app.sql("delete from login_failure").await;
    for _ in 0..100 {
        app.add_failure("ana", Some("198.51.100.1"), 2).await;
    }
    for age in [10, 9, 8, 7, 6] {
        app.add_failure("ana", Some(A), age).await;
    }
    let (s, ra, _) = fail_from(&app, "ana", A).await;
    assert_eq!(s, StatusCode::TOO_MANY_REQUESTS);
    // 105 failures: the backstop needs 6 gone, the sixth oldest is 2 minutes old: 13 minutes.
    assert!((778..=781).contains(&ra.unwrap()), "{ra:?}");
}

#[tokio::test]
async fn thirty_failures_from_one_known_address_lock_the_address() {
    let app = TestApp::new().await;
    app.give_password(ANA, "ana", PW).await;
    app.sql("delete from login_failure").await;
    for i in 0..30 {
        let (s, _, _) = try_login(&app, &format!("guess{i}"), PW, "203.0.113.9", None).await;
        assert_eq!(s, StatusCode::UNAUTHORIZED, "{i}");
    }
    // A fresh name, even the right password, from the same address: locked.
    let (s, ra, _) = try_login(&app, "ana", PW, "203.0.113.9", None).await;
    assert_eq!((s, ra.is_some()), (StatusCode::TOO_MANY_REQUESTS, true));
    // Another address is free.
    assert_eq!(
        try_login(&app, "ana", PW, "203.0.113.10", None).await.0,
        StatusCode::OK
    );
    // Behind our proxy the client from X-Forwarded-For is what counts: the locked one is still
    // locked, a different one is not, and made up left parts change nothing.
    let via = |xff: &'static str| {
        let app = &app;
        async move { try_login(app, "ana", PW, "172.18.0.3", Some(xff)).await.0 }
    };
    assert_eq!(via("203.0.113.9").await, StatusCode::TOO_MANY_REQUESTS);
    assert_eq!(
        via("1.2.3.4, 203.0.113.9, 10.0.0.2").await,
        StatusCode::TOO_MANY_REQUESTS
    );
    assert_eq!(via("203.0.113.77, 10.0.0.2").await, StatusCode::OK);
    // A public peer is not trusted to say who it is.
    assert_eq!(
        try_login(&app, "ana", PW, "203.0.113.9", Some("203.0.113.200"))
            .await
            .0,
        StatusCode::TOO_MANY_REQUESTS
    );
    // The lock follows the window.
    app.sql("update login_failure set at = now() - interval '16 minutes'")
        .await;
    assert_eq!(
        try_login(&app, "ana", PW, "203.0.113.9", None).await.0,
        StatusCode::OK
    );
}

#[tokio::test]
async fn without_a_public_client_address_there_is_no_address_limit_and_no_shared_bucket() {
    let app = TestApp::new().await;
    app.give_password(ANA, "ana", PW).await;
    app.sql("delete from login_failure").await;
    // Everything private: docker NAT, a LAN client, IPv6 through docker-proxy, a bad header, no
    // socket at all. 40 different names fail from "everybody": nobody gets a 429 for that.
    let cases: [(&str, Option<&str>); 5] = [
        ("172.18.0.1", None),
        ("172.18.0.1", Some("192.168.1.50")),
        ("fd00::2", None),
        ("172.18.0.1", Some("203.0.113.9, garbage")),
        ("::ffff:172.18.0.1", Some("10.1.2.3, fe80::1")),
    ];
    let mut n = 0;
    for (peer, xff) in cases {
        for _ in 0..8 {
            n += 1;
            let (s, _, _) = try_login(&app, &format!("guess{n}"), "wrong wrong", peer, xff).await;
            assert_eq!(s, StatusCode::UNAUTHORIZED, "{peer} {xff:?} try {n}");
        }
    }
    for i in 0..8 {
        assert_eq!(
            fail(&app, &format!("nosocket{i}")).await.0,
            StatusCode::UNAUTHORIZED
        );
    }
    // The right password of a person with no failures passes from any of them.
    for (peer, xff) in cases {
        assert_eq!(
            try_login(&app, "ana", PW, peer, xff).await.0,
            StatusCode::OK,
            "{peer} {xff:?}"
        );
    }
    assert_eq!(app.password_login("ana", PW).await.0, StatusCode::OK);
    // All of them share ONE pair per name, the 'unknown' address: five wrong tries for a name
    // lock it for all unknown addresses, and only for them.
    app.sql("delete from login_failure").await;
    for _ in 0..5 {
        assert_eq!(
            try_login(&app, "ana", "wrong wrong", "172.18.0.1", None)
                .await
                .0,
            StatusCode::UNAUTHORIZED
        );
    }
    assert_eq!(
        try_login(&app, "ana", PW, "fd00::2", None).await.0,
        StatusCode::TOO_MANY_REQUESTS
    );
    assert_eq!(
        app.password_login("ana", PW).await.0,
        StatusCode::TOO_MANY_REQUESTS
    );
    assert_eq!(try_login(&app, "ana", PW, B, None).await.0, StatusCode::OK);
    // An unknown address is never remembered as trusted.
    assert_eq!(app.count("login_success").await, 1);
    assert_eq!(
        app.scalar(&format!(
            "select count(*) from login_success where address_key = '{}'",
            app.addr_key(None)
        ))
        .await,
        0
    );
}

#[tokio::test]
async fn a_hundred_failures_from_anywhere_lock_a_name_except_for_trusted_addresses() {
    let app = TestApp::new().await;
    app.give_password(ANA, "ana", PW).await;
    app.sql("delete from login_failure").await;
    app.sql("delete from login_success").await;
    // Ana signed in from B (and from C a month and a day ago) before.
    assert_eq!(try_login(&app, "ana", PW, B, None).await.0, StatusCode::OK);
    app.add_success("ana", Some("203.0.113.40"), 31).await;
    app.add_success("ben", Some("203.0.113.41"), 1).await;
    // 99 failures from 99 addresses: still open to everybody.
    for i in 0..99 {
        app.add_failure("ana", Some(&format!("198.51.100.{i}")), 1)
            .await;
    }
    assert_eq!(try_login(&app, "ana", PW, A, None).await.0, StatusCode::OK);
    // The 100th failure closes the name for addresses that never signed in...
    app.add_failure("ana", Some("198.51.100.200"), 1).await;
    for peer in [
        "203.0.113.42",
        "203.0.113.40",
        "203.0.113.41",
        "203.0.113.99",
    ] {
        let (s, ra, v) = try_login(&app, "ana", PW, peer, None).await;
        assert_eq!(s, StatusCode::TOO_MANY_REQUESTS, "{peer}");
        assert_eq!(v, json!({ "error": TOO_MANY }));
        assert!(ra.unwrap() > 0);
    }
    // ... and no address is "trusted" without a known address.
    assert_eq!(
        app.password_login("ana", PW).await.0,
        StatusCode::TOO_MANY_REQUESTS
    );
    // ... but not to an address that signed in within 30 days (B and A just did).
    let (s, _, v) = try_login(&app, "ana", PW, B, None).await;
    assert_eq!(s, StatusCode::OK, "{v}");
    // A trusted address still has its own pair limit: five wrong tries lock it for that name.
    for _ in 0..5 {
        assert_eq!(fail_from(&app, "ana", B).await.0, StatusCode::UNAUTHORIZED);
    }
    assert_eq!(
        try_login(&app, "ana", PW, B, None).await.0,
        StatusCode::TOO_MANY_REQUESTS
    );
    // Another name is not affected by ana's backstop.
    assert_eq!(
        try_login(&app, "ben", PW2, A, None).await.0,
        StatusCode::UNAUTHORIZED
    );
    // The trust lasts 30 days.
    app.sql(&format!(
        "update login_success set at = now() - interval '31 days' where address_key = '{}'",
        app.addr_key(Some(B))
    ))
    .await;
    app.sql(&format!(
        "delete from login_failure where address_key = '{}'",
        app.addr_key(Some(B))
    ))
    .await;
    assert_eq!(
        try_login(&app, "ana", PW, B, None).await.0,
        StatusCode::TOO_MANY_REQUESTS
    );
    // The backstop ends with the window.
    app.sql("update login_failure set at = now() - interval '16 minutes'")
        .await;
    assert_eq!(try_login(&app, "ana", PW, A, None).await.0, StatusCode::OK);
}

#[tokio::test]
async fn a_sign_in_link_makes_the_address_trusted_for_the_name() {
    let app = TestApp::new().await;
    app.give_password(ANA, "ana", PW).await;
    app.sql("delete from login_failure").await;
    app.sql("delete from login_success").await;
    // Ask for a link and open it from B.
    let before = app.state.mailer.sent().len();
    let (s, _) = app
        .call(
            "POST",
            "/api/auth/magic-link",
            None,
            Some(json!({"email": "ana@example.org"})),
        )
        .await;
    assert_eq!(s, StatusCode::ACCEPTED);
    let link = app.state.mailer.sent()[before].link.clone();
    let token = link.split("token=").nth(1).unwrap().to_string();
    let (s, _, v) = app
        .call_from(
            "POST",
            "/api/auth/verify",
            None,
            Some(json!({"token": token})),
            B,
            None,
        )
        .await;
    assert_eq!(s, StatusCode::OK, "{v}");
    assert_eq!(app.count("login_success").await, 1);
    for i in 0..100 {
        app.add_failure("ana", Some(&format!("198.51.100.{i}")), 1)
            .await;
    }
    assert_eq!(try_login(&app, "ana", PW, B, None).await.0, StatusCode::OK);
    assert_eq!(
        try_login(&app, "ana", PW, A, None).await.0,
        StatusCode::TOO_MANY_REQUESTS
    );
    // Opening a link without a known address trusts nobody.
    app.sql("delete from login_success").await;
    let _ = app.login("ana@example.org").await;
    assert_eq!(app.count("login_success").await, 0);
}

#[tokio::test]
async fn a_wrong_current_password_counts_against_the_pair_and_only_that() {
    let app = TestApp::new().await;
    let tok = app.give_password(ANA, "ana", PW).await;
    app.sql("delete from login_failure").await;
    let change = |current: &'static str, peer: &'static str, tok: String| {
        let app = &app;
        async move {
            let (s, h, v) = app
                .call_from(
                    "POST",
                    "/api/auth/password",
                    Some(&tok),
                    Some(json!({"current_password": current, "new_password": PW2})),
                    peer,
                    None,
                )
                .await;
            (s, h.get("retry-after").is_some(), v)
        }
    };
    // Failures of OTHER addresses (a hundred, and a locked pair at C) never lock this session.
    for i in 0..100 {
        app.add_failure("ana", Some(&format!("198.51.100.{i}")), 1)
            .await;
    }
    for _ in 0..5 {
        app.add_failure("ana", Some("203.0.113.60"), 1).await;
    }
    for i in 0..5 {
        let (s, _, v) = change("nope nope nope", A, tok.clone()).await;
        assert_eq!(
            (s, v["error"].as_str()),
            (
                StatusCode::FORBIDDEN,
                Some("Your current password is not right.")
            ),
            "try {i}"
        );
    }
    assert_eq!(app.pair_failures("ana", Some(A)).await, 5);
    // The sixth try from the same address is locked, right password or not ...
    let (s, ra, v) = change(PW, A, tok.clone()).await;
    assert_eq!((s, ra), (StatusCode::TOO_MANY_REQUESTS, true), "{v}");
    // ... and so is the sign-in of that pair: it is the same counter.
    assert_eq!(
        try_login(&app, "ana", PW, A, None).await.0,
        StatusCode::TOO_MANY_REQUESTS
    );
    // From another address the right current password works, even though the name has had a
    // hundred failures from elsewhere and the pair at C is locked.
    let (s, _, v) = change(PW, B, tok.clone()).await;
    assert_eq!(s, StatusCode::OK, "{v}");
    // Changing the password does not make the address trusted.
    assert_eq!(app.count("login_success").await, 0);
}

#[tokio::test]
async fn parallel_guesses_from_one_pair_cannot_slip_past_the_limit() {
    let app = TestApp::new().await;
    for peer in [None, Some(A)] {
        app.sql("delete from login_failure").await;
        let codes = many_logins(&app, "cora", peer, 24).await;
        let n = |c: StatusCode| codes.iter().filter(|x| **x == c).count();
        assert_eq!(n(StatusCode::UNAUTHORIZED), 5, "{peer:?} {codes:?}");
        assert_eq!(n(StatusCode::TOO_MANY_REQUESTS), 19, "{peer:?}");
        assert_eq!(app.failures_of("cora").await, 5);
    }
    // Parallel tries from 30 addresses for one name stay within the backstop: exactly 100 get a
    // 401 once the name is at its limit, no matter how many come at once.
    app.sql("delete from login_failure").await;
    for i in 0..96 {
        app.add_failure("cora", Some(&format!("198.51.100.{i}")), 1)
            .await;
    }
    let mut set = tokio::task::JoinSet::new();
    for i in 0..20 {
        let router = app.router.clone();
        set.spawn(async move {
            use tower::ServiceExt;
            let mut req = axum::http::Request::builder()
                .method("POST")
                .uri("/api/auth/login")
                .header("content-type", "application/json")
                .body(axum::body::Body::from(
                    r#"{"username":"cora","password":"not the one"}"#,
                ))
                .unwrap();
            let peer: std::net::SocketAddr =
                format!("203.0.113.{}:40000", 100 + i).parse().unwrap();
            req.extensions_mut()
                .insert(axum::extract::ConnectInfo(peer));
            router.oneshot(req).await.unwrap().status()
        });
    }
    let mut ok = 0;
    while let Some(r) = set.join_next().await {
        if r.unwrap() == StatusCode::UNAUTHORIZED {
            ok += 1;
        }
    }
    assert_eq!(ok, 4);
    assert_eq!(app.failures_of("cora").await, 100);
}

#[tokio::test]
async fn old_rows_are_purged() {
    let app = TestApp::new().await;
    app.add_failure("a", Some("1.1.1.1"), 3 * 24 * 60).await;
    app.add_failure("b", Some("1.1.1.1"), 60).await;
    app.add_success("a", Some("1.1.1.1"), 31).await;
    app.add_success("b", Some("1.1.1.1"), 29).await;
    let n: i32 = sqlx::query_scalar("select xt_purge_expired()")
        .fetch_one(&app.state.pool)
        .await
        .unwrap();
    assert!(n >= 2);
    assert_eq!(app.count("login_failure").await, 1);
    assert_eq!(app.count("login_success").await, 1);
    // A name's own old rows also go the next time that name is tried.
    app.add_failure("zed", Some(A), 20).await;
    fail_from(&app, "zed", A).await;
    assert_eq!(app.failures_of("zed").await, 1);
}

#[tokio::test]
async fn the_limit_tables_keep_no_readable_names_or_addresses() {
    let app = TestApp::new().await;
    app.give_password(ANA, "ana", PW).await;
    // People type their password in the username box.
    let typed = "purple bicycle rain";
    for (who, peer) in [(typed, A), ("ana", B), ("ana", "2001:db8:1:2:3:4:5:6")] {
        try_login(&app, who, "wrong wrong", peer, None).await;
    }
    assert_eq!(try_login(&app, "ana", PW, B, None).await.0, StatusCode::OK);
    for table in ["login_failure", "login_success"] {
        let dump: String = sqlx::query_scalar(&format!(
            "select coalesce(string_agg(x::text, ' '), '') from {table} x"
        ))
        .fetch_one(&app.state.pool)
        .await
        .unwrap();
        for secret in ["purple", "bicycle", "ana", "203.0.113", "unknown"] {
            assert!(!dump.contains(secret), "{table} shows {secret}: {dump}");
        }
    }
    let keys: Vec<(String, String)> =
        sqlx::query_as("select username_key, address_key from login_failure")
            .fetch_all(&app.state.pool)
            .await
            .unwrap();
    // (ana's wrong try from B was cleared by her success there)
    assert_eq!(keys.len(), 2);
    for (u, a) in &keys {
        for k in [u, a] {
            assert_eq!(k.len(), 64);
            assert!(k
                .bytes()
                .all(|c| c.is_ascii_digit() || (b'a'..=b'f').contains(&c)));
        }
    }
    assert!(keys.contains(&(app.user_key(typed), app.addr_key(Some(A)))));
    // An IPv6 client counts per /64.
    assert!(keys.contains(&(app.user_key("ana"), app.addr_key(Some("2001:db8:1:2::/64")))));
    // The database itself refuses a readable key.
    let r =
        sqlx::query("insert into login_failure (username_key, address_key) values ('ana', 'x')")
            .execute(&app.state.pool)
            .await;
    assert!(r.is_err());
    let r =
        sqlx::query("insert into login_success (username_key, address_key) values ('ana', 'x')")
            .execute(&app.state.pool)
            .await;
    assert!(r.is_err());
    // The key comes from the secret: another secret gives other keys.
    let other =
        xynotransit_api::loginlimit::LimitKeys::new("another secret another secret 1234567");
    assert_ne!(other.user("ana"), app.user_key("ana"));
}

// ---------------------------------------------------------------------------------------------
// change, reset, remove
// ---------------------------------------------------------------------------------------------

#[tokio::test]
async fn first_password_after_a_link_needs_no_current_one() {
    let app = TestApp::new().await;
    let old = app.token_for(ANA, false);
    let (s, v) = status_of(
        &app,
        "POST",
        "/api/auth/password",
        &old,
        Some(json!({"new_password": PW})),
    )
    .await;
    assert_eq!(s, StatusCode::OK, "{v}");
    let fresh = bearer(&v);
    assert!(v["expires_at"].as_str().is_some());
    // The old session is over, the fresh one works.
    let (s, v) = app.call("GET", "/api/me", Some(&old), None).await;
    assert_eq!(
        (s, v["error"].as_str()),
        (StatusCode::UNAUTHORIZED, Some("Please sign in again."))
    );
    let (s, me) = app.call("GET", "/api/me", Some(&fresh), None).await;
    assert_eq!(s, StatusCode::OK);
    assert_eq!(me["has_password"], true);
    assert_eq!(app.password_login("ana", PW).await.0, StatusCode::OK);
    let audit: Vec<(String, Option<String>)> =
        sqlx::query_as("select kind, issued_by::text from password_audit")
            .fetch_all(&app.state.pool)
            .await
            .unwrap();
    assert_eq!(audit, vec![("change".to_string(), None)]);
    assert_eq!(app.scalar("select count(*) from person where id = '00000000-0000-0000-0000-0000000000a1' and session_epoch = 1 and password_changed_at is not null and not must_change_password").await, 1);
}

#[tokio::test]
async fn changing_needs_the_current_password_and_the_policy() {
    let app = TestApp::new().await;
    let tok = app.give_password(ANA, "ana", PW).await;
    let go = |cur: Option<&str>, new: &str| {
        let (app, tok) = (&app, tok.clone());
        let body = match cur {
            Some(c) => json!({"current_password": c, "new_password": new}),
            None => json!({"new_password": new}),
        };
        let new = new.to_string();
        async move {
            let r = app
                .call("POST", "/api/auth/password", Some(&tok), Some(body))
                .await;
            let _ = new;
            r
        }
    };
    let (s, v) = go(None, PW2).await;
    assert_eq!(
        (s, v["error"].as_str()),
        (
            StatusCode::BAD_REQUEST,
            Some("Enter your current password.")
        )
    );
    let (s, v) = go(Some(""), PW2).await;
    assert_eq!(
        (s, v["error"].as_str()),
        (
            StatusCode::BAD_REQUEST,
            Some("Enter your current password.")
        )
    );
    let (s, v) = go(Some("not my password"), PW2).await;
    assert_eq!(
        (s, v["error"].as_str()),
        (
            StatusCode::FORBIDDEN,
            Some("Your current password is not right.")
        )
    );
    let (s, v) = go(Some(PW), "").await;
    assert_eq!(
        (s, v["error"].as_str()),
        (StatusCode::BAD_REQUEST, Some("Enter a new password."))
    );
    let (s, v) = go(Some(PW), PW).await;
    assert_eq!(
        (s, v["error"].as_str()),
        (
            StatusCode::BAD_REQUEST,
            Some("Choose a password different from the current one.")
        )
    );
    let cases = [
        ("short", "Use at least 10 characters."),
        ("nine char", "Use at least 10 characters."),
        (
            "ANA RAKOTO",
            "Do not use your username, email address or name as a password.",
        ),
        (
            "ana@example.org",
            "Do not use your username, email address or name as a password.",
        ),
        ("aaaaaaaaaaaa", "Do not repeat one character."),
        (
            "1234567890",
            "Do not use a simple run such as 1234567890 or abcdefghij.",
        ),
        (
            "abcdefghij",
            "Do not use a simple run such as 1234567890 or abcdefghij.",
        ),
        (
            "Password123",
            "That password is too common. Pick something only you would think of.",
        ),
        (
            "bad\u{0}password here",
            "Use letters, numbers, spaces and symbols only.",
        ),
        (&"x7".repeat(65), "Use at most 128 characters."),
    ];
    for (pw, msg) in cases {
        let (s, v) = go(Some(PW), pw).await;
        assert_eq!(
            (s, v["error"].as_str()),
            (StatusCode::BAD_REQUEST, Some(msg)),
            "{pw:?}"
        );
    }
    // None of those changed anything.
    assert_eq!(app.password_login("ana", PW).await.0, StatusCode::OK);
    let (s, v) = go(Some(PW), PW2).await;
    assert_eq!(s, StatusCode::OK, "{v}");
    assert_eq!(
        app.password_login("ana", PW).await.0,
        StatusCode::UNAUTHORIZED
    );
    assert_eq!(app.password_login("ana", PW2).await.0, StatusCode::OK);
    // Spaces are kept exactly as typed.
    let fresh = bearer(&v);
    let (s, v) = status_of(
        &app,
        "POST",
        "/api/auth/password",
        &fresh,
        Some(json!({"current_password": PW2, "new_password": "  two  spaces  "})),
    )
    .await;
    assert_eq!(s, StatusCode::OK, "{v}");
    assert_eq!(
        app.password_login("ana", "  two  spaces  ").await.0,
        StatusCode::OK
    );
    assert_eq!(
        app.password_login("ana", "two  spaces").await.0,
        StatusCode::UNAUTHORIZED
    );
}

#[tokio::test]
async fn reset_gives_a_temporary_password_shown_once() {
    let app = TestApp::new().await;
    let mgr = app.token_for(CORA, true);
    let url = format!("/api/persons/{ANA}/password-reset");
    // Only the manager.
    let (s, v) = status_of(
        &app,
        "POST",
        &url,
        &app.token_for(ANA, false),
        Some(json!({})),
    )
    .await;
    assert_eq!(
        (s, v["error"].as_str()),
        (StatusCode::FORBIDDEN, Some("Only the manager can do this."))
    );
    let old_ana = app.token_for(ANA, false);
    let (s, v) = status_of(&app, "POST", &url, &mgr, Some(json!({}))).await;
    assert_eq!(s, StatusCode::CREATED, "{v}");
    assert_eq!(v["username"], "ana");
    assert_eq!(v["must_change_password"], true);
    let temp = v["temporary_password"].as_str().unwrap().to_string();
    assert_eq!(temp.chars().count(), 16);
    assert!(!temp.chars().any(|c| "0O1lI".contains(c)));
    assert_eq!(v.as_object().unwrap().len(), 3);
    // Her old session ended at once.
    assert_eq!(
        app.call("GET", "/api/me", Some(&old_ana), None).await.0,
        StatusCode::UNAUTHORIZED
    );
    // The temporary password is not stored in clear, nowhere in the database.
    let hay: String = sqlx::query_scalar(
        "select coalesce(string_agg(p::text, ' '), '') from (select * from person) p",
    )
    .fetch_one(&app.state.pool)
    .await
    .unwrap();
    assert!(!hay.contains(&temp) && hay.contains("$argon2id$"));
    for t in [
        "password_audit",
        "login_failure",
        "login_token",
        "sign_in_link_audit",
    ] {
        let rows: String = sqlx::query_scalar(&format!(
            "select coalesce(string_agg(x::text, ' '), '') from {t} x"
        ))
        .fetch_one(&app.state.pool)
        .await
        .unwrap();
        assert!(!rows.contains(&temp) && !rows.contains("argon2"), "{t}");
    }
    let audit: Vec<(String, Option<String>)> =
        sqlx::query_as("select kind, issued_by::text from password_audit")
            .fetch_all(&app.state.pool)
            .await
            .unwrap();
    assert_eq!(audit, vec![("reset".to_string(), Some(CORA.to_string()))]);

    // Signing in with it works but she must choose her own before anything else.
    let (s, v) = app.password_login("ana", &temp).await;
    assert_eq!(s, StatusCode::OK, "{v}");
    assert_eq!(
        (&v["must_change_password"], &v["has_password"]),
        (&json!(true), &json!(true))
    );
    let tok = bearer(&v);
    let period = app.ensure_period(&mgr, "2026-02-01").await;
    let blocked: Vec<(&str, String, Option<Value>)> = vec![
        ("GET", "/api/catalog".into(), None),
        ("GET", "/api/catalog?include_inactive=true".into(), None),
        (
            "POST",
            "/api/periods/ensure".into(),
            Some(json!({"start_month": "2026-02-01"})),
        ),
        (
            "GET",
            format!("/api/periods/{period}/reports/{A_ANA}"),
            None,
        ),
        (
            "PUT",
            format!("/api/periods/{period}/reports/{A_ANA}"),
            Some(ana_report()),
        ),
        ("GET", format!("/api/periods/{period}/reports"), None),
        ("GET", format!("/api/periods/{period}/deck-text"), None),
        ("POST", "/api/events/ticket".into(), None),
        ("GET", "/api/summary".into(), None),
        ("POST", "/api/teams".into(), Some(json!({"name": "Sneaky"}))),
        (
            "POST",
            format!("/api/persons/{BEN}/sign-in-link"),
            Some(json!({})),
        ),
        (
            "POST",
            format!("/api/persons/{BEN}/password-reset"),
            Some(json!({})),
        ),
        ("DELETE", format!("/api/persons/{BEN}/password"), None),
        ("GET", "/api/health".into(), None),
    ];
    for (m, u, b) in blocked {
        let (s, v) = app.call(m, &u, Some(&tok), b).await;
        if u == "/api/health" {
            assert_eq!(s, StatusCode::OK, "health is public");
            continue;
        }
        assert_eq!(
            (s, v["error"].as_str()),
            (StatusCode::FORBIDDEN, Some("Choose a new password first.")),
            "{m} {u}"
        );
    }
    // A manager with a temporary password is gated too, whatever the role.
    assert_eq!(
        app.call("GET", "/api/me", Some(&tok), None).await.1["must_change_password"],
        true
    );
    // Nothing was created by the blocked calls.
    assert_eq!(
        app.scalar("select count(*) from team where name = 'Sneaky'")
            .await,
        0
    );

    // The temporary one cannot stay.
    let (s, v) = status_of(
        &app,
        "POST",
        "/api/auth/password",
        &tok,
        Some(json!({"current_password": temp, "new_password": temp})),
    )
    .await;
    assert_eq!(s, StatusCode::BAD_REQUEST, "{v}");
    let (s, v) = status_of(
        &app,
        "POST",
        "/api/auth/password",
        &tok,
        Some(json!({"current_password": temp, "new_password": PW})),
    )
    .await;
    assert_eq!(s, StatusCode::OK, "{v}");
    let fresh = bearer(&v);
    assert_eq!(
        app.call("GET", "/api/catalog", Some(&fresh), None).await.0,
        StatusCode::OK
    );
    assert_eq!(
        app.call("GET", "/api/catalog", Some(&tok), None).await.0,
        StatusCode::UNAUTHORIZED
    );
    assert_eq!(
        app.password_login("ana", &temp).await.0,
        StatusCode::UNAUTHORIZED
    );
    assert_eq!(
        app.password_login("ana", PW).await.1["must_change_password"],
        false
    );

    // Another reset replaces the first temporary password.
    let (_, v2) = status_of(&app, "POST", &url, &mgr, Some(json!({}))).await;
    let temp2 = v2["temporary_password"].as_str().unwrap().to_string();
    assert_ne!(temp, temp2);
    assert_eq!(
        app.password_login("ana", PW).await.0,
        StatusCode::UNAUTHORIZED
    );
    assert_eq!(app.password_login("ana", &temp2).await.0, StatusCode::OK);
}

#[tokio::test]
async fn reset_and_remove_edge_cases() {
    let app = TestApp::new().await;
    let mgr = app.token_for(CORA, true);
    let (s, v) = status_of(
        &app,
        "POST",
        "/api/persons/00000000-0000-0000-0000-00000000ffff/password-reset",
        &mgr,
        Some(json!({})),
    )
    .await;
    assert_eq!(
        (s, v["error"].as_str()),
        (StatusCode::NOT_FOUND, Some("That person does not exist."))
    );
    assert_eq!(
        status_of(
            &app,
            "POST",
            "/api/persons/not-an-id/password-reset",
            &mgr,
            Some(json!({}))
        )
        .await
        .0,
        StatusCode::NOT_FOUND
    );
    let (s, v) = status_of(
        &app,
        "POST",
        &format!("/api/persons/{DAN}/password-reset"),
        &mgr,
        Some(json!({})),
    )
    .await;
    assert_eq!(
        (s, v["error"].as_str()),
        (StatusCode::CONFLICT, Some("This person is switched off."))
    );
    assert_eq!(
        status_of(
            &app,
            "POST",
            &format!("/api/persons/{ANA}/password-reset"),
            &app.token_for(ANA, false),
            Some(json!({}))
        )
        .await
        .0,
        StatusCode::FORBIDDEN
    );
    assert_eq!(
        app.call(
            "POST",
            &format!("/api/persons/{ANA}/password-reset"),
            None,
            Some(json!({}))
        )
        .await
        .0,
        StatusCode::UNAUTHORIZED
    );
    assert_eq!(
        app.count("password_audit").await,
        0,
        "refusals leave no trace"
    );

    // Remove.
    let ana_tok = app.give_password(ANA, "ana", PW).await;
    let url = format!("/api/persons/{ANA}/password");
    assert_eq!(
        status_of(&app, "DELETE", &url, &app.token_for(BEN, false), None)
            .await
            .0,
        StatusCode::FORBIDDEN
    );
    assert_eq!(
        status_of(
            &app,
            "DELETE",
            "/api/persons/00000000-0000-0000-0000-00000000ffff/password",
            &mgr,
            None
        )
        .await
        .0,
        StatusCode::NOT_FOUND
    );
    let (s, _) = status_of(&app, "DELETE", &url, &mgr, None).await;
    assert_eq!(s, StatusCode::NO_CONTENT);
    assert_eq!(
        app.password_login("ana", PW).await.0,
        StatusCode::UNAUTHORIZED
    );
    assert_eq!(
        app.call("GET", "/api/me", Some(&ana_tok), None).await.0,
        StatusCode::UNAUTHORIZED
    );
    assert_eq!(app.scalar(&format!("select count(*) from person where id = '{ANA}' and password_hash is null and not must_change_password")).await, 1);
    // Back to links: the old link flow still works and says there is no password.
    let t = app.login("ana@example.org").await;
    assert_eq!(
        app.call("GET", "/api/me", Some(&t), None).await.1["has_password"],
        false
    );
    let kinds: Vec<String> = sqlx::query_scalar(
        "select kind from password_audit where person_id = $1::uuid order by id",
    )
    .bind(ANA)
    .fetch_all(&app.state.pool)
    .await
    .unwrap();
    assert_eq!(kinds, vec!["reset", "change", "remove"]);
}

#[tokio::test]
async fn at_most_thirty_resets_per_manager_per_hour() {
    let app = TestApp::new().await;
    let mgr = app.token_for(CORA, true);
    let url = format!("/api/persons/{BEN}/password-reset");
    for i in 0..30 {
        let (s, v) = status_of(&app, "POST", &url, &mgr, Some(json!({}))).await;
        assert_eq!(s, StatusCode::CREATED, "{i}: {v}");
    }
    let (s, h, v) = app
        .call_from("POST", &url, Some(&mgr), Some(json!({})), "10.0.0.1", None)
        .await;
    assert_eq!(s, StatusCode::TOO_MANY_REQUESTS);
    assert_eq!(
        v["error"],
        "Too many temporary passwords created. Try again later."
    );
    let ra: u64 = h["retry-after"].to_str().unwrap().parse().unwrap();
    assert!((3590..=3600).contains(&ra), "{ra}");
    // Another manager has their own count; an old one drops out of the hour.
    app.sql(&format!(
        "update person set app_role = 'controller' where id = '{ANA}'"
    ))
    .await;
    assert_eq!(
        status_of(
            &app,
            "POST",
            &url,
            &app.token_for(ANA, true),
            Some(json!({}))
        )
        .await
        .0,
        StatusCode::CREATED
    );
    app.sql("update password_audit set at = now() - interval '61 minutes' where id = (select min(id) from password_audit)").await;
    assert_eq!(
        status_of(&app, "POST", &url, &mgr, Some(json!({}))).await.0,
        StatusCode::CREATED
    );
}

// ---------------------------------------------------------------------------------------------
// sessions
// ---------------------------------------------------------------------------------------------

#[tokio::test]
async fn tokens_without_an_epoch_work_until_the_first_password_change() {
    use jsonwebtoken::{encode, EncodingKey, Header};
    let app = TestApp::new().await;
    let now = chrono::Utc::now().timestamp();
    // The shape of a token from before epochs existed: no "ep" claim.
    let old = encode(
        &Header::default(),
        &json!({"sub": ANA, "role": "contributor", "iat": now, "exp": now + 600}),
        &EncodingKey::from_secret(SECRET.as_bytes()),
    )
    .unwrap();
    assert_eq!(
        app.call("GET", "/api/me", Some(&old), None).await.0,
        StatusCode::OK
    );
    assert_eq!(
        app.call(
            "GET",
            "/api/me",
            Some(&app.token_for_epoch(ANA, false, 1)),
            None
        )
        .await
        .0,
        StatusCode::UNAUTHORIZED
    );
    app.give_password(ANA, "ana", PW).await;
    assert_eq!(
        app.call("GET", "/api/me", Some(&old), None).await.0,
        StatusCode::UNAUTHORIZED
    );
    // A token that claims a later epoch than the person has is refused too.
    assert_eq!(
        app.call(
            "GET",
            "/api/me",
            Some(&app.token_for_epoch(BEN, false, 5)),
            None
        )
        .await
        .0,
        StatusCode::UNAUTHORIZED
    );
}

#[tokio::test]
async fn switched_off_people_stay_out_with_or_without_a_password() {
    let app = TestApp::new().await;
    let t = app.give_password(ANA, "ana", PW).await;
    let mgr = app.token_for(CORA, true);
    let (s, _) = status_of(
        &app,
        "PATCH",
        &format!("/api/persons/{ANA}"),
        &mgr,
        Some(json!({"active": false})),
    )
    .await;
    assert_eq!(s, StatusCode::OK);
    assert_eq!(
        app.call("GET", "/api/me", Some(&t), None).await.0,
        StatusCode::UNAUTHORIZED
    );
    assert_eq!(
        app.password_login("ana", PW).await.0,
        StatusCode::UNAUTHORIZED
    );
    assert_eq!(
        status_of(
            &app,
            "POST",
            "/api/auth/password",
            &t,
            Some(json!({"current_password": PW, "new_password": PW2}))
        )
        .await
        .0,
        StatusCode::UNAUTHORIZED
    );
}

/// After any password change, reset or removal every older token fails and only the newest works.
#[tokio::test]
async fn after_any_password_change_all_older_tokens_fail() {
    let app = TestApp::new().await;
    let mgr = app.token_for(CORA, true);
    let mut rng = StdRng::seed_from_u64(
        std::env::var("PROPTEST_SEED")
            .ok()
            .and_then(|s| s.parse().ok())
            .unwrap_or(7),
    );
    let rounds: usize = std::env::var("PROPTEST_CASES")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(14);
    let mut password: Option<String> = None;
    let mut tokens: Vec<String> = vec![app.token_for(ANA, false)];
    let mut must_change = false;
    let mut temp = String::new();
    for round in 0..rounds {
        // Always a few live sessions: links and passwords both.
        tokens.push(app.token_for_epoch(ANA, false, current_epoch(&app).await));
        if !must_change {
            if let Some(p) = &password {
                let (s, v) = app.password_login("ana", p).await;
                assert_eq!(s, StatusCode::OK);
                tokens.push(bearer(&v));
            }
        }
        for t in &tokens {
            let (s, _) = app.call("GET", "/api/me", Some(t), None).await;
            assert_eq!(s, StatusCode::OK, "round {round}: live token");
        }
        let before = tokens.clone();
        tokens.clear();
        match rng.random_range(0..4) {
            0 if password.is_some() && !must_change => {
                let new = format!("{PW} {round}");
                let (s, v) = status_of(
                    &app,
                    "POST",
                    "/api/auth/password",
                    &before[0],
                    Some(
                        json!({"current_password": password.clone().unwrap(), "new_password": new}),
                    ),
                )
                .await;
                assert_eq!(s, StatusCode::OK, "{v}");
                tokens.push(bearer(&v));
                password = Some(new);
            }
            1 => {
                let (s, v) = status_of(
                    &app,
                    "POST",
                    &format!("/api/persons/{ANA}/password-reset"),
                    &mgr,
                    Some(json!({})),
                )
                .await;
                assert_eq!(s, StatusCode::CREATED);
                temp = v["temporary_password"].as_str().unwrap().to_string();
                let (s, v) = app.password_login("ana", &temp).await;
                assert_eq!(s, StatusCode::OK);
                tokens.push(bearer(&v));
                must_change = true;
                password = None;
            }
            2 => {
                assert_eq!(
                    status_of(
                        &app,
                        "DELETE",
                        &format!("/api/persons/{ANA}/password"),
                        &mgr,
                        None
                    )
                    .await
                    .0,
                    StatusCode::NO_CONTENT
                );
                password = None;
                must_change = false;
                tokens.push(app.token_for_epoch(ANA, false, current_epoch(&app).await));
            }
            _ => {
                // First or next password through a session (a link session when there is none).
                let new = format!("{PW2} {round}");
                let body = match (&password, must_change) {
                    (_, true) => json!({"current_password": temp, "new_password": new}),
                    (Some(p), _) => json!({"current_password": p, "new_password": new}),
                    _ => json!({"new_password": new}),
                };
                let (s, _) =
                    status_of(&app, "POST", "/api/auth/password", &before[0], Some(body)).await;
                assert_eq!(s, StatusCode::OK);
                must_change = false;
                password = Some(new);
                let (s, v) = app.password_login("ana", password.as_ref().unwrap()).await;
                assert_eq!(s, StatusCode::OK);
                tokens.push(bearer(&v));
            }
        }
        if tokens.is_empty() {
            tokens = before.clone();
            continue;
        }
        for t in &before {
            let (s, v) = app.call("GET", "/api/me", Some(t), None).await;
            assert_eq!(
                s,
                StatusCode::UNAUTHORIZED,
                "round {round}: old token still works: {v}"
            );
        }
        for t in &tokens {
            assert_eq!(
                app.call("GET", "/api/me", Some(t), None).await.0,
                StatusCode::OK,
                "round {round}"
            );
        }
        if must_change && password.is_none() {
            // After the reset the session is the gated one; take it out of the game by choosing.
            must_change = true;
        }
    }
}

async fn current_epoch(app: &TestApp) -> i32 {
    sqlx::query_scalar::<_, i32>(&format!(
        "select session_epoch from person where id = '{ANA}'"
    ))
    .fetch_one(&app.state.pool)
    .await
    .unwrap()
}

// ---------------------------------------------------------------------------------------------
// usernames in the people API
// ---------------------------------------------------------------------------------------------

#[tokio::test]
async fn new_people_get_usernames_and_managers_can_set_them() {
    let app = TestApp::new().await;
    let mgr = app.token_for(CORA, true);
    let add = |body: Value| {
        let (app, mgr) = (&app, mgr.clone());
        async move {
            app.call("POST", "/api/persons", Some(&mgr), Some(body))
                .await
        }
    };
    let (s, a) = add(json!({"full_name": "Rosa Rakoto", "email": "Rosa.Rakoto@north.org", "app_role": "contributor"})).await;
    assert_eq!(s, StatusCode::CREATED, "{a}");
    assert_eq!(
        (&a["username"], &a["has_password"]),
        (&json!("rosa.rakoto"), &json!(false))
    );
    let (_, b) = add(json!({"full_name": "Rosa Rakoto", "email": "rosa.rakoto@south.org", "app_role": "contributor"})).await;
    assert_eq!(b["username"], "rosa.rakoto2");
    let (_, c) = add(json!({"full_name": "Rosa Rakoto", "app_role": "contributor"})).await;
    assert_eq!(c["username"], "rosa.rakoto3");
    assert_eq!(c["email"], "rosa.rakoto@xynotransit.internal");
    // Chosen on purpose.
    let (s, d) = add(json!({"full_name": "Tahina", "email": "t@x.org", "app_role": "contributor", "username": " Tahina_R "})).await;
    assert_eq!(
        (s, &d["username"]),
        (StatusCode::CREATED, &json!("tahina_r"))
    );
    let (s, v) = add(json!({"full_name": "Tahina Two", "email": "t2@x.org", "app_role": "contributor", "username": "TAHINA_r"})).await;
    assert_eq!(
        (s, v["error"].as_str()),
        (StatusCode::CONFLICT, Some("That username is already used."))
    );
    let nice = "Usernames use letters, digits, dots, dashes and underscores, 3 to 40 characters.";
    for bad in ["", "ab", "has space", "ünï", "a@b.c", &"x".repeat(41)] {
        let (s, v) = add(json!({"full_name": "Bad Name", "email": "bad@x.org", "app_role": "contributor", "username": bad})).await;
        assert_eq!(
            (s, v["error"].as_str()),
            (StatusCode::BAD_REQUEST, Some(nice)),
            "{bad:?}"
        );
    }
    assert_eq!(
        app.scalar("select count(*) from person where email = 'bad@x.org'")
            .await,
        0
    );
    // The chosen one cannot take the generated one's name either.
    let (s, _) = add(json!({"full_name": "X Y", "email": "xy@x.org", "app_role": "contributor", "username": "rosa.rakoto"})).await;
    assert_eq!(s, StatusCode::CONFLICT);

    // Patch.
    let id = a["id"].as_str().unwrap();
    let url = format!("/api/persons/{id}");
    let (s, v) = status_of(
        &app,
        "PATCH",
        &url,
        &mgr,
        Some(json!({"username": "Rosa.R"})),
    )
    .await;
    assert_eq!((s, &v["username"]), (StatusCode::OK, &json!("rosa.r")));
    // Nothing else changed, the same name for the same person is fine, null leaves it alone.
    assert_eq!(
        status_of(
            &app,
            "PATCH",
            &url,
            &mgr,
            Some(json!({"username": "rosa.r"}))
        )
        .await
        .0,
        StatusCode::OK
    );
    let (s, v) = status_of(
        &app,
        "PATCH",
        &url,
        &mgr,
        Some(json!({"username": null, "full_name": "Rosa R"})),
    )
    .await;
    assert_eq!((s, &v["username"]), (StatusCode::OK, &json!("rosa.r")));
    let (s, v) = status_of(&app, "PATCH", &url, &mgr, Some(json!({"username": "ANA"}))).await;
    assert_eq!(
        (s, v["error"].as_str()),
        (StatusCode::CONFLICT, Some("That username is already used."))
    );
    let (s, v) = status_of(
        &app,
        "PATCH",
        &url,
        &mgr,
        Some(json!({"username": "no good"})),
    )
    .await;
    assert_eq!(
        (s, v["error"].as_str()),
        (StatusCode::BAD_REQUEST, Some(nice))
    );
    // Employees cannot.
    let (s, v) = status_of(
        &app,
        "PATCH",
        &format!("/api/persons/{ANA}"),
        &app.token_for(ANA, false),
        Some(json!({"username": "ana2"})),
    )
    .await;
    assert_eq!(
        (s, v["error"].as_str()),
        (StatusCode::FORBIDDEN, Some("Only the manager can do this."))
    );
    // A renamed person signs in with the new name only; the password stays.
    app.give_password(ANA, "ana", PW).await;
    status_of(
        &app,
        "PATCH",
        &format!("/api/persons/{ANA}"),
        &mgr,
        Some(json!({"username": "ana.rakoto"})),
    )
    .await;
    assert_eq!(
        app.password_login("ana", PW).await.0,
        StatusCode::UNAUTHORIZED
    );
    assert_eq!(app.password_login("Ana.Rakoto", PW).await.0, StatusCode::OK);
}

#[tokio::test]
async fn the_catalog_and_me_show_the_username_and_whether_there_is_a_password_never_the_hash() {
    let app = TestApp::new().await;
    app.give_password(ANA, "ana", PW).await;
    let mgr = app.token_for(CORA, true);
    let (s, bytes) = app
        .raw(
            "GET",
            "/api/catalog?include_inactive=true",
            Some(&mgr),
            None,
        )
        .await;
    assert_eq!(s, StatusCode::OK);
    let text = String::from_utf8(bytes).unwrap();
    assert!(!text.contains("argon2") && !text.contains("password_hash") && !text.contains(PW));
    let v: Value = serde_json::from_str(&text).unwrap();
    let ana = v["persons"]
        .as_array()
        .unwrap()
        .iter()
        .find(|p| p["id"] == ANA)
        .unwrap();
    assert_eq!(
        (&ana["username"], &ana["has_password"]),
        (&json!("ana"), &json!(true))
    );
    let cora = v["persons"]
        .as_array()
        .unwrap()
        .iter()
        .find(|p| p["id"] == CORA)
        .unwrap();
    assert_eq!(
        (&cora["username"], &cora["has_password"]),
        (&json!("cora"), &json!(false))
    );
    // An employee sees only themselves.
    let (_, v) = app
        .call(
            "GET",
            "/api/catalog",
            Some(&app.token_for_epoch(ANA, false, 2)),
            None,
        )
        .await;
    assert_eq!(v["persons"].as_array().unwrap().len(), 1);
    assert_eq!(v["persons"][0]["username"], "ana");
}

// ---------------------------------------------------------------------------------------------
// hashing in the running API
// ---------------------------------------------------------------------------------------------

#[tokio::test]
async fn a_busy_machine_answers_503_and_the_try_is_not_counted() {
    let mut app = TestApp::new().await;
    app.give_password(ANA, "ana", PW).await;
    let mut state = app.state.clone();
    state.hasher = Hasher::with_limits(
        state.config.password_hash,
        2,
        std::time::Duration::from_millis(80),
    );
    let sem = state.hasher.semaphore();
    app.router = build_router(state);
    let held = [
        sem.clone().acquire_owned().await.unwrap(),
        sem.clone().acquire_owned().await.unwrap(),
    ];
    let (s, v) = app.password_login("ana", PW).await;
    assert_eq!(
        (s, v["error"].as_str()),
        (
            StatusCode::SERVICE_UNAVAILABLE,
            Some("Busy, try again in a moment.")
        )
    );
    let (s, v) = app.password_login("nobody", PW).await;
    assert_eq!(
        (s, v["error"].as_str()),
        (
            StatusCode::SERVICE_UNAVAILABLE,
            Some("Busy, try again in a moment.")
        )
    );
    assert_eq!(app.count("login_failure").await, 0);
    let (s, v) = status_of(
        &app,
        "POST",
        &format!("/api/persons/{BEN}/password-reset"),
        &app.token_for(CORA, true),
        Some(json!({})),
    )
    .await;
    assert_eq!(
        (s, v["error"].as_str()),
        (
            StatusCode::SERVICE_UNAVAILABLE,
            Some("Busy, try again in a moment.")
        )
    );
    drop(held);
    assert_eq!(app.password_login("ana", PW).await.0, StatusCode::OK);
}

#[tokio::test]
async fn hashes_use_the_configured_parameters_and_old_ones_are_upgraded() {
    let mut app = TestApp::new().await;
    // The shipped default is the OWASP minimum.
    let mut state = app.state.clone();
    state.hasher = Hasher::new(xynotransit_api::hashing::HashSettings::default());
    app.router = build_router(state.clone());
    app.give_password(ANA, "ana", PW).await;
    let h: String = sqlx::query_scalar(&format!(
        "select password_hash from person where id = '{ANA}'"
    ))
    .fetch_one(&app.state.pool)
    .await
    .unwrap();
    assert!(h.starts_with("$argon2id$v=19$m=19456,t=2,p=1$"), "{h}");
    // Back to the cheap test settings: the old hash still works and is made again on sign-in.
    app.router = build_router(app.state.clone());
    assert_eq!(app.password_login("ana", PW).await.0, StatusCode::OK);
    let h: String = sqlx::query_scalar(&format!(
        "select password_hash from person where id = '{ANA}'"
    ))
    .fetch_one(&app.state.pool)
    .await
    .unwrap();
    assert!(h.starts_with("$argon2id$v=19$m=64,t=1,p=1$"), "{h}");
    // That did not end any session or write an audit row.
    assert_eq!(
        app.scalar(&format!(
            "select session_epoch::bigint from person where id = '{ANA}'"
        ))
        .await,
        2
    );
    assert_eq!(app.password_login("ana", PW).await.0, StatusCode::OK);
}

#[tokio::test]
async fn unknown_names_cost_about_as_much_time_as_known_ones() {
    let mut app = TestApp::new().await;
    let mut state = app.state.clone();
    state.hasher = Hasher::new(xynotransit_api::hashing::HashSettings::default());
    app.router = build_router(state);
    app.give_password(ANA, "ana", PW).await;
    let time = |who: &'static str| {
        let app = &app;
        async move {
            let mut v = vec![];
            for i in 0..3 {
                let t = std::time::Instant::now();
                // A different address each time so no limit gets in the way.
                let (s, _, _) = app
                    .call_from(
                        "POST",
                        "/api/auth/login",
                        None,
                        Some(json!({"username": who, "password": "wrong wrong wrong"})),
                        &format!("203.0.113.{}", 20 + i),
                        None,
                    )
                    .await;
                assert_eq!(s, StatusCode::UNAUTHORIZED);
                v.push(t.elapsed().as_secs_f64());
            }
            v.sort_by(|a, b| a.partial_cmp(b).unwrap());
            v[1]
        }
    };
    let known = time("ana").await;
    let unknown = time("not.a.person").await;
    let off = {
        app.sql(&format!(
            "update person set active = false where id = '{BEN}'"
        ))
        .await;
        time("ben").await
    };
    for (what, t) in [("unknown", unknown), ("switched off", off)] {
        assert!(
            t > known * 0.4 && t < known * 2.5,
            "{what}: {t:.3}s against {known:.3}s for a real password"
        );
    }
}

// ---------------------------------------------------------------------------------------------
// logs hold no password
// ---------------------------------------------------------------------------------------------

#[derive(Clone, Default)]
struct Buf(Arc<Mutex<Vec<u8>>>);
impl Write for Buf {
    fn write(&mut self, b: &[u8]) -> std::io::Result<usize> {
        self.0.lock().unwrap().extend_from_slice(b);
        Ok(b.len())
    }
    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}
impl<'a> tracing_subscriber::fmt::MakeWriter<'a> for Buf {
    type Writer = Buf;
    fn make_writer(&'a self) -> Buf {
        self.clone()
    }
}

#[tokio::test]
async fn no_password_reaches_a_log_the_audit_or_an_error() {
    static LOG: OnceLock<Buf> = OnceLock::new();
    let buf = LOG
        .get_or_init(|| {
            let b = Buf::default();
            let _ = tracing::subscriber::set_global_default(
                tracing_subscriber::fmt()
                    .with_writer(b.clone())
                    .with_env_filter(tracing_subscriber::EnvFilter::new("debug"))
                    .with_ansi(false)
                    .finish(),
            );
            b
        })
        .clone();
    let app = TestApp::new().await;
    let secret_old = "zebra-quartz-ZEBRA-98765";
    let secret_new = "walnut-lantern-WALNUT-43210";
    let tok = app.give_password(ANA, "ana", secret_old).await;
    let mut answers = vec![];
    for (m, u, b) in [
        (
            "POST",
            "/api/auth/login",
            json!({"username": "ana", "password": secret_old}),
        ),
        (
            "POST",
            "/api/auth/login",
            json!({"username": "ana", "password": secret_new}),
        ),
        (
            "POST",
            "/api/auth/password",
            json!({"current_password": secret_old, "new_password": secret_new}),
        ),
        (
            "POST",
            "/api/auth/password",
            json!({"current_password": "wrong " , "new_password": secret_new}),
        ),
        (
            "POST",
            "/api/auth/password",
            json!({"current_password": secret_new, "new_password": "short"}),
        ),
    ] {
        let (s, bytes) = app
            .raw(m, u, Some(&tok), Some(serde_json::to_vec(&b).unwrap()))
            .await;
        assert_ne!(s, StatusCode::INTERNAL_SERVER_ERROR);
        answers.push(String::from_utf8(bytes).unwrap());
    }
    let (_, bytes) = app
        .raw(
            "POST",
            &format!("/api/persons/{BEN}/password-reset"),
            Some(&app.token_for(CORA, true)),
            Some(b"{}".to_vec()),
        )
        .await;
    let temp = serde_json::from_slice::<Value>(&bytes).unwrap()["temporary_password"]
        .as_str()
        .unwrap()
        .to_string();
    let log = String::from_utf8(buf.0.lock().unwrap().clone()).unwrap();
    let audit: String =
        sqlx::query_scalar("select coalesce(string_agg(x::text, ' '), '') from password_audit x")
            .fetch_one(&app.state.pool)
            .await
            .unwrap();
    let failures: String =
        sqlx::query_scalar("select coalesce(string_agg(x::text, ' '), '') from login_failure x")
            .fetch_one(&app.state.pool)
            .await
            .unwrap();
    for secret in [secret_old, secret_new, temp.as_str()] {
        assert!(!log.contains(secret), "log has {secret}");
        assert!(!audit.contains(secret) && !failures.contains(secret));
        for a in &answers {
            assert!(!a.contains(secret) || a.contains("access_token"), "{a}");
        }
    }
    assert!(!log.contains("argon2id"));
}

// ---------------------------------------------------------------------------------------------
// the migration
// ---------------------------------------------------------------------------------------------

fn admin_url() -> String {
    std::env::var("TEST_ADMIN_URL")
        .unwrap_or_else(|_| "postgres://xynotransit:xynotransit@127.0.0.1:5432/postgres".into())
}

#[tokio::test]
async fn the_migration_backfills_usernames_on_realistic_data_and_runs_twice() {
    let admin = admin_url();
    let name = format!("xt_test_{}", uuid::Uuid::new_v4().simple());
    let mut conn = PgConnection::connect(&admin).await.unwrap();
    sqlx::query(&format!("create database {name}"))
        .execute(&mut conn)
        .await
        .unwrap();
    let url = format!("{}/{}", admin.rsplit_once('/').unwrap().0, name);
    let pool = PgPoolOptions::new()
        .max_connections(2)
        .connect(&url)
        .await
        .unwrap();
    let initdb = concat!(env!("CARGO_MANIFEST_DIR"), "/../xynotransit-db/initdb/");
    let mut files: Vec<_> = std::fs::read_dir(initdb)
        .unwrap()
        .map(|e| e.unwrap().path())
        .filter(|p| p.extension().is_some_and(|x| x == "sql"))
        .collect();
    files.sort();
    let name_of = |p: &std::path::PathBuf| p.file_name().unwrap().to_string_lossy().to_string();
    let before: Vec<_> = files
        .iter()
        .filter(|p| name_of(p).as_str() < "12-")
        .collect();
    let twelve: Vec<_> = files
        .iter()
        .filter(|p| name_of(p).starts_with("12-"))
        .collect();
    let thirteen: Vec<_> = files
        .iter()
        .filter(|p| name_of(p).starts_with("13-"))
        .collect();
    for f in before {
        sqlx::raw_sql(&std::fs::read_to_string(f).unwrap())
            .execute(&pool)
            .await
            .unwrap();
    }
    // A database as it was before passwords: duplicate local parts, accents, no email, odd ones.
    let long = format!("{}@long.org", "l".repeat(60));
    let rows: Vec<(&str, Option<String>, bool)> = vec![
        ("Rosa Rakoto", Some("Rosa.Rakoto@north.org".into()), true),
        ("Rosa Rakoto", Some("rosa.rakoto@south.org".into()), true),
        ("Rosa Rakoto", Some("rosa.rakoto@east.org".into()), false),
        ("Rosa R", Some("rosa.rakoto2@west.org".into()), true),
        (
            "Rosa Internal",
            Some("rosa.rakoto@xynotransit.internal".into()),
            true,
        ),
        ("Jose", Some("josé.müller@x.org".into()), true),
        ("Short", Some("ab@x.org".into()), true),
        ("Tiny", Some("a@x.org".into()), true),
        ("Plus", Some("a+b+c@x.org".into()), true),
        ("Kanji", Some("名前@x.org".into()), true),
        ("Dots", Some("..dots..@x.org".into()), true),
        ("Long", Some(long.clone()), true),
        ("Long2", Some(long.replace("@long.org", "@other.org")), true),
        ("No Email", None, true),
        ("No Email Two", None, true),
        ("Upper", Some("MANAGER@X.ORG".into()), true),
    ];
    for (n, e, a) in &rows {
        sqlx::query("insert into person (full_name, email, active) values ($1, $2, $3)")
            .bind(n)
            .bind(e)
            .bind(a)
            .execute(&pool)
            .await
            .unwrap();
    }
    let sql12 = std::fs::read_to_string(twelve[0]).unwrap();
    sqlx::raw_sql(&sql12).execute(&pool).await.unwrap();
    let got: Vec<(String, Option<String>, String)> =
        sqlx::query_as("select full_name, email, username from person order by username")
            .fetch_all(&pool)
            .await
            .unwrap();
    let names: Vec<&str> = got.iter().map(|g| g.2.as_str()).collect();
    let mut uniq = names.clone();
    uniq.dedup();
    assert_eq!(uniq.len(), names.len(), "usernames are unique: {names:?}");
    for n in &names {
        assert!(
            xynotransit_api::username::clean(n).as_deref() == Ok(*n),
            "{n} is a valid username"
        );
    }
    let has = |n: &str| names.contains(&n);
    for n in [
        "rosa.rakoto",
        "rosa.rakoto2",
        "rosa.rakoto3",
        "rosa.rakoto4",
        "rosa.rakoto5",
        "jose.muller",
        "user.ab",
        "user.a",
        "abc",
        "user",
        "user2",
        "dots",
        "manager",
    ] {
        assert!(has(n), "{n} missing in {names:?}");
    }
    let l40 = "l".repeat(40);
    assert!(
        has(&l40) && has(&format!("{}2", "l".repeat(39))),
        "{names:?}"
    );
    // The email of a person that already had rosa.rakoto2 as its local part keeps it.
    let west = got
        .iter()
        .find(|g| g.1.as_deref() == Some("rosa.rakoto2@west.org"))
        .unwrap();
    let rosas: Vec<&str> = names
        .iter()
        .copied()
        .filter(|n| n.starts_with("rosa.rakoto"))
        .collect();
    assert_eq!(rosas.len(), 5, "{rosas:?}");
    let _ = west;
    // The ledger knows the file; a second run changes nothing.
    assert_eq!(
        sqlx::query_scalar::<_, i64>(
            "select count(*) from schema_migration where file = '12-passwords.sql'"
        )
        .fetch_one(&pool)
        .await
        .unwrap(),
        1
    );
    let snapshot = || async {
        sqlx::query_as::<_, (String, String)>("select id::text, username from person order by id")
            .fetch_all(&pool)
            .await
            .unwrap()
    };
    let first = snapshot().await;
    sqlx::raw_sql(&sql12).execute(&pool).await.unwrap();
    assert_eq!(first, snapshot().await);
    // A new person inserted by older code (no username) gets one from the trigger.
    sqlx::query("insert into person (full_name, email) values ('Late', 'rosa.rakoto@late.org')")
        .execute(&pool)
        .await
        .unwrap();
    let late: String = sqlx::query_scalar("select username from person where full_name = 'Late'")
        .fetch_one(&pool)
        .await
        .unwrap();
    assert_eq!(late, "rosa.rakoto6");
    // The rules are enforced by the database as well.
    for bad in ["Has Upper", "ab", "with space"] {
        let r = sqlx::query("update person set username = $1 where full_name = 'Late'")
            .bind(bad)
            .execute(&pool)
            .await;
        assert!(r.is_err(), "{bad}");
    }
    let r = sqlx::query("update person set username = 'ROSA.RAKOTO' where full_name = 'Late'")
        .execute(&pool)
        .await;
    assert!(r.is_err());
    let r = sqlx::query(
        "insert into password_audit (person_id, kind) select id, 'guess' from person limit 1",
    )
    .execute(&pool)
    .await;
    assert!(r.is_err(), "unknown audit kinds are refused");

    // SQL and Rust agree on the base name for the emails SQL can fold.
    for email in [
        "rosa.rakoto@x.org",
        "Rosa.Rakoto@X.org",
        "josé.müller@x.org",
        "ab@x.org",
        "a@x.org",
        "@x.org",
        "...@x.org",
        ".rosa.@x.org",
        "名前@x.org",
        "a_b-c@x.org",
        "-@x.org",
        "noat",
        "a+b@x.org",
        &long,
        "ÀÉÎÕÜ.ÿ@x.org",
        "x.y.z@a@b",
        "UPPER.case@x",
        "tab\there@x",
    ] {
        let sql: String = sqlx::query_scalar("select xt_username_base($1)")
            .bind(email)
            .fetch_one(&pool)
            .await
            .unwrap();
        assert_eq!(
            sql,
            xynotransit_api::username::base_from_email(email),
            "{email:?}"
        );
    }

    // ---- 13-hashed-keys.sql on top of 12 ----
    // Under 12 the table kept what was typed and the address; 13 drops those rows (they were only
    // 15 minute counters) and the columns, adds login_success, and is safe to run again.
    sqlx::query("insert into login_failure (username_key, ip) values ('purple bicycle rain', '203.0.113.7')")
        .execute(&pool)
        .await
        .unwrap();
    let sql13 = std::fs::read_to_string(thirteen[0]).unwrap();
    sqlx::raw_sql(&sql13).execute(&pool).await.unwrap();
    let cols: Vec<String> = sqlx::query_scalar(
        "select column_name::text from information_schema.columns
         where table_name = 'login_failure' order by ordinal_position",
    )
    .fetch_all(&pool)
    .await
    .unwrap();
    assert_eq!(cols, ["id", "username_key", "address_key", "at"]);
    let rows = |t: &'static str| {
        let pool = pool.clone();
        async move {
            sqlx::query_scalar::<_, i64>(&format!("select count(*) from {t}"))
                .fetch_one(&pool)
                .await
                .unwrap()
        }
    };
    assert_eq!(rows("login_failure").await, 0, "old rows are gone");
    assert_eq!(rows("login_success").await, 0);
    let h = "a".repeat(64);
    sqlx::query("insert into login_failure (username_key, address_key) values ($1, $1)")
        .bind(&h)
        .execute(&pool)
        .await
        .unwrap();
    sqlx::query("insert into login_success (username_key, address_key, at) values ($1, $1, now() - interval '40 days')")
        .bind(&h)
        .execute(&pool)
        .await
        .unwrap();
    // A second run (and a second run of 12 on top of it) keeps what is there and changes nothing.
    sqlx::raw_sql(&sql13).execute(&pool).await.unwrap();
    sqlx::raw_sql(&sql12).execute(&pool).await.unwrap();
    sqlx::raw_sql(&sql13).execute(&pool).await.unwrap();
    assert_eq!(rows("login_failure").await, 1);
    // One success row per pair, refreshed in place.
    let dup = sqlx::query("insert into login_success (username_key, address_key) values ($1, $1)")
        .bind(&h)
        .execute(&pool)
        .await;
    assert!(dup.is_err());
    // Readable keys are refused by the database.
    for bad in ["ana", &"A".repeat(64), &"a".repeat(63)] {
        let r =
            sqlx::query("insert into login_failure (username_key, address_key) values ($1, $2)")
                .bind(bad)
                .bind(&h)
                .execute(&pool)
                .await;
        assert!(r.is_err(), "{bad}");
    }
    // The audit trail knows the new kind.
    sqlx::query(
        "insert into password_audit (person_id, kind) select id, 'change-via-link' from person limit 1",
    )
    .execute(&pool)
    .await
    .unwrap();
    // Housekeeping drops trusted addresses older than 30 days and failures older than a day.
    sqlx::query("select xt_purge_expired()")
        .execute(&pool)
        .await
        .unwrap();
    assert_eq!(rows("login_success").await, 0);
    assert_eq!(rows("login_failure").await, 1);
    assert_eq!(
        sqlx::query_scalar::<_, i64>(
            "select count(*) from schema_migration where file = '13-hashed-keys.sql'"
        )
        .fetch_one(&pool)
        .await
        .unwrap(),
        1
    );

    pool.close().await;
    sqlx::query(&format!("drop database {name} with (force)"))
        .execute(&mut conn)
        .await
        .unwrap();
}

// ---------------------------------------------------------------------------------------------
// the server command
// ---------------------------------------------------------------------------------------------

struct Run {
    code: i32,
    out: String,
    err: String,
}

async fn set_password_cli(
    app: &TestApp,
    args: &[&str],
    stdin: Option<&str>,
    with_url: bool,
) -> Run {
    let args: Vec<String> = args.iter().map(|s| s.to_string()).collect();
    let url = app.state.config.database_url.clone();
    let stdin = stdin.map(str::to_string);
    tokio::task::spawn_blocking(move || {
        let mut cmd = Command::new(env!("CARGO_BIN_EXE_xynotransit-api"));
        cmd.arg("set-password")
            .args(&args)
            .env_clear()
            .env("PASSWORD_HASH_MEMORY_KIB", "64")
            .env("PASSWORD_HASH_ITERATIONS", "1")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        if with_url {
            cmd.env("DATABASE_URL", url);
        }
        let mut child = cmd.spawn().unwrap();
        {
            let mut si = child.stdin.take().unwrap();
            if let Some(s) = stdin {
                let _ = si.write_all(s.as_bytes());
            }
        }
        let o = child.wait_with_output().unwrap();
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
async fn set_password_command_reads_stdin_and_prints_one_line() {
    let app = TestApp::new().await;
    let old = app.token_for(CORA, true);
    let r = set_password_cli(&app, &["cora"], Some("a long fresh secret\n"), true).await;
    assert_eq!(
        (r.code, r.out.as_str(), r.err.as_str()),
        (0, "Password set for cora.\n", "")
    );
    assert_eq!(
        app.password_login("cora", "a long fresh secret").await.0,
        StatusCode::OK
    );
    // The old session ended; the person is not asked to change it; audit says cli.
    assert_eq!(
        app.call("GET", "/api/me", Some(&old), None).await.0,
        StatusCode::UNAUTHORIZED
    );
    let (must, epoch): (bool, i32) = sqlx::query_as(&format!(
        "select must_change_password, session_epoch from person where id = '{CORA}'"
    ))
    .fetch_one(&app.state.pool)
    .await
    .unwrap();
    assert_eq!((must, epoch), (false, 1));
    let audit: Vec<(String, Option<String>)> =
        sqlx::query_as("select kind, issued_by::text from password_audit")
            .fetch_all(&app.state.pool)
            .await
            .unwrap();
    assert_eq!(audit, vec![("cli".to_string(), None)]);
    // By email, with a Windows line ending and no line ending at all; spaces inside are kept.
    let r = set_password_cli(
        &app,
        &["Ana@Example.org"],
        Some("  spaced out secret \r\n"),
        true,
    )
    .await;
    assert_eq!(
        (r.code, r.out.as_str()),
        (0, "Password set for ana.\n"),
        "{}",
        r.err
    );
    assert_eq!(
        app.password_login("ana", "  spaced out secret ").await.0,
        StatusCode::OK
    );
    let r = set_password_cli(&app, &["ben"], Some("no newline at the end"), true).await;
    assert_eq!(r.code, 0, "{}", r.err);
    assert_eq!(
        app.password_login("ben", "no newline at the end").await.0,
        StatusCode::OK
    );
    // A manager reset is undone by it: the temporary mark goes away.
    let mgr = app.token_for_epoch(CORA, true, 1);
    status_of(
        &app,
        "POST",
        &format!("/api/persons/{BEN}/password-reset"),
        &mgr,
        Some(json!({})),
    )
    .await;
    let r = set_password_cli(&app, &["ben"], Some("a new calm passphrase\n"), true).await;
    assert_eq!(r.code, 0);
    assert_eq!(
        app.scalar(&format!(
            "select count(*) from person where id = '{BEN}' and not must_change_password"
        ))
        .await,
        1
    );
}

#[tokio::test]
async fn set_password_command_exit_codes_and_messages() {
    let app = TestApp::new().await;
    type Case<'a> = (Vec<&'a str>, Option<&'a str>, bool, i32, &'a str);
    let cases: Vec<Case> = vec![
        (vec![], Some("x"), true, 2, "Usage:"),
        (vec!["a", "b"], Some("x"), true, 2, "Usage:"),
        (vec!["--force"], Some("x"), true, 2, "Usage:"),
        (
            vec!["nobody"],
            Some("a long fresh secret\n"),
            true,
            1,
            "No person has the username or email nobody.",
        ),
        (
            vec!["dan"],
            Some("a long fresh secret\n"),
            true,
            1,
            "is switched off.",
        ),
        (
            vec!["cora"],
            Some("short\n"),
            true,
            1,
            "Use at least 10 characters.",
        ),
        (
            vec!["cora"],
            Some("Password123\n"),
            true,
            1,
            "That password is too common. Pick something only you would think of.",
        ),
        (
            vec!["cora"],
            Some("cora@example.org\n"),
            true,
            1,
            "Do not use your username, email address or name as a password.",
        ),
        (
            vec!["cora"],
            Some(""),
            true,
            1,
            "No password was given on standard input.",
        ),
        (
            vec!["cora"],
            Some("a long fresh secret\n"),
            false,
            1,
            "DATABASE_URL is not set.",
        ),
    ];
    for (args, stdin, url, code, msg) in cases {
        let r = set_password_cli(&app, &args, stdin, url).await;
        assert_eq!(r.code, code, "{args:?}: {}", r.err);
        assert!(r.err.contains(msg), "{args:?}: {}", r.err);
        assert_eq!(r.out, "", "{args:?}");
        for s in ["a long fresh secret", "Password123", "short"] {
            assert!(
                !r.err.contains(s) || msg.contains(s),
                "the password is never repeated: {}",
                r.err
            );
        }
    }
    assert_eq!(app.count("password_audit").await, 0);
    assert_eq!(
        app.scalar("select count(*) from person where password_hash is not null")
            .await,
        0
    );
    let r = set_password_cli(&app, &["cora"], Some("x\n"), true).await;
    assert!(!r.err.contains("Database error"));
}
