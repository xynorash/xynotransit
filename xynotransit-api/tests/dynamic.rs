//! Teams, people, seats, counts and targets built in the app, and the manager summary.

mod common;

use axum::http::StatusCode;
use common::*;
use serde_json::{json, Value};

const M_OLD: &str = "00000000-0000-0000-0000-0000000000b3";

async fn boss(app: &TestApp) -> String {
    app.login("cora@example.org").await
}

fn seat<'a>(cat: &'a Value, id: &str) -> &'a Value {
    cat["assignments"]
        .as_array()
        .unwrap()
        .iter()
        .find(|a| a["id"] == id)
        .unwrap_or_else(|| panic!("seat {id} missing"))
}

async fn catalog(app: &TestApp, t: &str, q: &str) -> Value {
    let (s, v) = app
        .call("GET", &format!("/api/catalog{q}"), Some(t), None)
        .await;
    assert_eq!(s, StatusCode::OK);
    v
}

async fn defs(app: &TestApp, t: &str, seat: &str, body: Value) -> (StatusCode, Value) {
    app.call(
        "PUT",
        &format!("/api/assignments/{seat}/definitions"),
        Some(t),
        Some(body),
    )
    .await
}

async fn expect(
    app: &TestApp,
    method: &str,
    uri: &str,
    t: &str,
    body: Value,
    code: u16,
    msg: &str,
) {
    let (s, v) = app.call(method, uri, Some(t), Some(body)).await;
    assert_eq!(s.as_u16(), code, "{method} {uri}: {v}");
    assert_eq!(v["error"], msg, "{method} {uri}");
}

fn labels(seat: &Value) -> Vec<String> {
    seat["metrics"]
        .as_array()
        .unwrap()
        .iter()
        .map(|m| m["label"].as_str().unwrap().to_string())
        .collect()
}

// ---------- who may do it ----------

#[tokio::test]
async fn every_new_write_and_the_summary_are_manager_only() {
    let app = TestApp::new().await;
    let ana = app.login("ana@example.org").await;
    let calls: Vec<(&str, String, Value)> = vec![
        ("POST", "/api/teams".into(), json!({"name": "X"})),
        ("PATCH", "/api/teams/1".into(), json!({"name": "X"})),
        ("DELETE", "/api/teams/1".into(), json!(null)),
        (
            "POST",
            "/api/persons".into(),
            json!({"full_name": "X", "email": "x@x.org", "app_role": "contributor"}),
        ),
        (
            "PATCH",
            format!("/api/persons/{ANA}"),
            json!({"active": false}),
        ),
        (
            "POST",
            "/api/assignments".into(),
            json!({"person_id": ANA, "team_id": "1", "role_title": "X"}),
        ),
        (
            "PATCH",
            format!("/api/assignments/{A_ANA}"),
            json!({"sort": 1}),
        ),
        (
            "PUT",
            format!("/api/assignments/{A_ANA}/definitions"),
            json!({"metrics": [], "kpis": []}),
        ),
        (
            "GET",
            format!("/api/summary?period_id={}", Uuid::new_v4()),
            json!(null),
        ),
    ];
    for (m, uri, body) in calls {
        let b = if body.is_null() {
            None
        } else {
            Some(body.clone())
        };
        let (s, v) = app.call(m, &uri, Some(&ana), b.clone()).await;
        assert_eq!(s, StatusCode::FORBIDDEN, "{m} {uri}");
        assert_eq!(v["error"], "Only the manager can do this.");
        let (s, _) = app.call(m, &uri, None, b).await;
        assert_eq!(s, StatusCode::UNAUTHORIZED, "{m} {uri}");
    }
    // Nothing changed.
    assert_eq!(app.count("team").await, 2);
}

use uuid::Uuid;

// ---------- teams ----------

#[tokio::test]
async fn teams_can_be_created_renamed_ordered_and_deleted() {
    let app = TestApp::new().await;
    let t = boss(&app).await;

    let (s, v) = app
        .call(
            "POST",
            "/api/teams",
            Some(&t),
            Some(json!({"name": "  Tamatave Port "})),
        )
        .await;
    assert_eq!(s, StatusCode::CREATED, "{v}");
    assert_eq!(v["code"], "tamatave-port");
    assert_eq!(v["name"], "Tamatave Port");
    assert_eq!(v["sort"], 3, "last sort plus one");
    let id = v["id"].as_str().unwrap().to_string();

    // A name that makes the same slug gets its own code.
    let (_, v2) = app
        .call(
            "POST",
            "/api/teams",
            Some(&t),
            Some(json!({"name": "Tamatave-Port!"})),
        )
        .await;
    assert_eq!(v2["code"], "tamatave-port-2");
    assert_eq!(v2["sort"], 4);

    expect(
        &app,
        "POST",
        "/api/teams",
        &t,
        json!({"name": "tamatave port"}),
        409,
        "That team name is already used.",
    )
    .await;
    expect(
        &app,
        "POST",
        "/api/teams",
        &t,
        json!({"name": "   "}),
        400,
        "Enter a team name.",
    )
    .await;
    expect(
        &app,
        "POST",
        "/api/teams",
        &t,
        json!({"name": "x".repeat(61)}),
        400,
        "A team name can have at most 60 characters.",
    )
    .await;
    let (s, _) = app
        .call(
            "POST",
            "/api/teams",
            Some(&t),
            Some(json!({"name": "x".repeat(60)})),
        )
        .await;
    assert_eq!(s, StatusCode::CREATED);

    let (s, v) = app
        .call(
            "PATCH",
            &format!("/api/teams/{id}"),
            Some(&t),
            Some(json!({"name": "Port", "sort": 0})),
        )
        .await;
    assert_eq!(s, StatusCode::OK, "{v}");
    assert_eq!(
        (v["name"].as_str(), v["sort"].as_i64(), v["code"].as_str()),
        (Some("Port"), Some(0), Some("tamatave-port"))
    );
    expect(
        &app,
        "PATCH",
        &format!("/api/teams/{id}"),
        &t,
        json!({"name": "Tana"}),
        409,
        "That team name is already used.",
    )
    .await;
    // Renaming to the same name in another case is the team itself, so allowed.
    let (s, _) = app
        .call(
            "PATCH",
            &format!("/api/teams/{id}"),
            Some(&t),
            Some(json!({"name": "PORT"})),
        )
        .await;
    assert_eq!(s, StatusCode::OK);
    expect(
        &app,
        "PATCH",
        &format!("/api/teams/{id}"),
        &t,
        json!({"sort": -1}),
        400,
        "Enter an order between 0 and 10000.",
    )
    .await;
    expect(
        &app,
        "PATCH",
        "/api/teams/9999",
        &t,
        json!({"name": "Z"}),
        404,
        "That team does not exist.",
    )
    .await;
    expect(
        &app,
        "PATCH",
        "/api/teams/abc",
        &t,
        json!({"name": "Z"}),
        404,
        "That team does not exist.",
    )
    .await;
    let cat = catalog(&app, &t, "").await;
    assert_eq!(cat["teams"][0]["name"], "PORT", "sort 0 comes first");

    // A team with seats cannot go; an empty one can.
    expect(
        &app,
        "DELETE",
        "/api/teams/1",
        &t,
        json!(null),
        409,
        "Move or remove the seats of this team first.",
    )
    .await;
    let (s, _) = app
        .call("DELETE", &format!("/api/teams/{id}"), Some(&t), None)
        .await;
    assert_eq!(s, StatusCode::NO_CONTENT);
    expect(
        &app,
        "DELETE",
        &format!("/api/teams/{id}"),
        &t,
        json!(null),
        404,
        "That team does not exist.",
    )
    .await;
    expect(
        &app,
        "DELETE",
        "/api/teams/2",
        &t,
        json!(null),
        409,
        "Move or remove the seats of this team first.",
    )
    .await;
}

// ---------- persons ----------

#[tokio::test]
async fn persons_are_created_and_edited_with_plain_errors() {
    let app = TestApp::new().await;
    let t = boss(&app).await;
    let (s, v) = app
        .call(
            "POST",
            "/api/persons",
            Some(&t),
            Some(json!({"full_name": " Eve Dupont ", "email": "  Eve@Example.ORG ", "app_role": "contributor"})),
        )
        .await;
    assert_eq!(s, StatusCode::CREATED, "{v}");
    assert_eq!(v["full_name"], "Eve Dupont");
    assert_eq!(v["email"], "eve@example.org");
    assert_eq!(v["app_role"], "contributor");
    assert_eq!(v["active"], true);
    let eve = v["id"].as_str().unwrap().to_string();

    let post = |n: &str, e: &str, r: &str| json!({"full_name": n, "email": e, "app_role": r});
    expect(
        &app,
        "POST",
        "/api/persons",
        &t,
        post("Eve 2", "EVE@example.org", "contributor"),
        409,
        "That email is already used.",
    )
    .await;
    expect(
        &app,
        "POST",
        "/api/persons",
        &t,
        post("Dan", "dan@example.org", "contributor"),
        409,
        "That email is already used.",
    )
    .await;
    expect(
        &app,
        "POST",
        "/api/persons",
        &t,
        post("Z", "not an email", "contributor"),
        400,
        "Enter a valid email address.",
    )
    .await;
    expect(
        &app,
        "POST",
        "/api/persons",
        &t,
        post("Z", "z@nodot", "contributor"),
        400,
        "Enter a valid email address.",
    )
    .await;
    expect(
        &app,
        "POST",
        "/api/persons",
        &t,
        post(" ", "z@z.org", "contributor"),
        400,
        "Enter a name.",
    )
    .await;
    expect(
        &app,
        "POST",
        "/api/persons",
        &t,
        post(&"n".repeat(81), "z@z.org", "contributor"),
        400,
        "A name can have at most 80 characters.",
    )
    .await;
    expect(
        &app,
        "POST",
        "/api/persons",
        &t,
        post("Z", "z@z.org", "admin"),
        400,
        "Choose employee or manager.",
    )
    .await;

    let (s, v) = app
        .call("PATCH", &format!("/api/persons/{eve}"), Some(&t), Some(json!({"full_name": "Eve D", "email": "eve.d@example.org", "app_role": "controller"})))
        .await;
    assert_eq!(s, StatusCode::OK, "{v}");
    assert_eq!(
        (
            v["full_name"].as_str(),
            v["email"].as_str(),
            v["app_role"].as_str()
        ),
        (Some("Eve D"), Some("eve.d@example.org"), Some("controller"))
    );
    expect(
        &app,
        "PATCH",
        &format!("/api/persons/{eve}"),
        &t,
        json!({"email": "ben@example.org"}),
        409,
        "That email is already used.",
    )
    .await;
    // Keeping your own email is fine.
    let (s, _) = app
        .call(
            "PATCH",
            &format!("/api/persons/{eve}"),
            Some(&t),
            Some(json!({"email": "EVE.D@example.org"})),
        )
        .await;
    assert_eq!(s, StatusCode::OK);
    expect(
        &app,
        "PATCH",
        &format!("/api/persons/{}", Uuid::new_v4()),
        &t,
        json!({"active": false}),
        404,
        "That person does not exist.",
    )
    .await;
    expect(
        &app,
        "PATCH",
        "/api/persons/nope",
        &t,
        json!({"active": false}),
        404,
        "That person does not exist.",
    )
    .await;
    expect(
        &app,
        "PATCH",
        &format!("/api/persons/{eve}"),
        &t,
        json!({"app_role": "x"}),
        400,
        "Choose employee or manager.",
    )
    .await;

    let cat = catalog(&app, &t, "").await;
    assert!(cat["persons"]
        .as_array()
        .unwrap()
        .iter()
        .any(|p| p["id"] == eve.as_str()));
}

#[tokio::test]
async fn there_is_always_at_least_one_manager() {
    let app = TestApp::new().await;
    let t = boss(&app).await;
    let msg = "There must be at least one manager.";
    expect(
        &app,
        "PATCH",
        &format!("/api/persons/{CORA}"),
        &t,
        json!({"app_role": "contributor"}),
        409,
        msg,
    )
    .await;
    expect(
        &app,
        "PATCH",
        &format!("/api/persons/{CORA}"),
        &t,
        json!({"active": false}),
        409,
        msg,
    )
    .await;
    expect(
        &app,
        "PATCH",
        &format!("/api/persons/{CORA}"),
        &t,
        json!({"active": false, "app_role": "contributor"}),
        409,
        msg,
    )
    .await;
    // Harmless edits are fine.
    let (s, _) = app
        .call(
            "PATCH",
            &format!("/api/persons/{CORA}"),
            Some(&t),
            Some(json!({"full_name": "Cora B"})),
        )
        .await;
    assert_eq!(s, StatusCode::OK);

    // An inactive manager does not count: promote Dan's row, deactivate, then try again.
    app.sql("update person set app_role = 'controller' where id = '00000000-0000-0000-0000-0000000000a4'").await;
    expect(
        &app,
        "PATCH",
        &format!("/api/persons/{CORA}"),
        &t,
        json!({"active": false}),
        409,
        msg,
    )
    .await;

    // With a second active manager, the first can step down.
    let (s, _) = app
        .call(
            "PATCH",
            &format!("/api/persons/{ANA}"),
            Some(&t),
            Some(json!({"app_role": "controller"})),
        )
        .await;
    assert_eq!(s, StatusCode::OK);
    let (s, v) = app
        .call(
            "PATCH",
            &format!("/api/persons/{CORA}"),
            Some(&t),
            Some(json!({"app_role": "contributor"})),
        )
        .await;
    assert_eq!(s, StatusCode::OK, "{v}");
    // Her old token now has employee rights only, and Ana is the last one.
    let (s, _) = app
        .call(
            "GET",
            &format!("/api/summary?period_id={}", Uuid::new_v4()),
            Some(&t),
            None,
        )
        .await;
    assert_eq!(s, StatusCode::FORBIDDEN);
    let ana = app.login("ana@example.org").await;
    expect(
        &app,
        "PATCH",
        &format!("/api/persons/{ANA}"),
        &ana,
        json!({"active": false}),
        409,
        msg,
    )
    .await;
}

#[tokio::test]
async fn a_deactivated_person_cannot_sign_in_or_use_a_token() {
    let app = TestApp::new().await;
    let t = boss(&app).await;
    let ben = app.login("ben@example.org").await;
    let (s, _) = app.call("GET", "/api/me", Some(&ben), None).await;
    assert_eq!(s, StatusCode::OK);

    let (s, v) = app
        .call(
            "PATCH",
            &format!("/api/persons/{BEN}"),
            Some(&t),
            Some(json!({"active": false})),
        )
        .await;
    assert_eq!(s, StatusCode::OK);
    assert_eq!(v["active"], false);
    for uri in ["/api/me", "/api/catalog"] {
        let (s, v) = app.call("GET", uri, Some(&ben), None).await;
        assert_eq!(s, StatusCode::UNAUTHORIZED, "{uri}");
        assert_eq!(v["error"], "Please sign in.");
    }
    // Their seat is untouched (still active), but the default view hides it with its person.
    let cat = catalog(&app, &t, "").await;
    assert!(cat["assignments"]
        .as_array()
        .unwrap()
        .iter()
        .all(|a| a["id"] != A_BEN));
    let cat = catalog(&app, &t, "?include_inactive=true").await;
    assert_eq!(seat(&cat, A_BEN)["active"], true);

    let before = app.state.mailer.sent().len();
    let (s, _) = app
        .call(
            "POST",
            "/api/auth/magic-link",
            None,
            Some(json!({"email": "ben@example.org"})),
        )
        .await;
    assert_eq!(s, StatusCode::ACCEPTED);
    assert_eq!(
        app.state.mailer.sent().len(),
        before,
        "no mail for an inactive person"
    );

    // Reactivated, they can sign in again.
    app.call(
        "PATCH",
        &format!("/api/persons/{BEN}"),
        Some(&t),
        Some(json!({"active": true})),
    )
    .await;
    let again = app.login("ben@example.org").await;
    let (s, _) = app.call("GET", "/api/me", Some(&again), None).await;
    assert_eq!(s, StatusCode::OK);
}

// ---------- seats ----------

#[tokio::test]
async fn seats_are_created_moved_and_deactivated() {
    let app = TestApp::new().await;
    let t = boss(&app).await;
    let (s, a) = app
        .call(
            "POST",
            "/api/assignments",
            Some(&t),
            Some(json!({"person_id": ANA, "team_id": "2", "role_title": "  Customs desk "})),
        )
        .await;
    assert_eq!(s, StatusCode::CREATED, "{a}");
    assert_eq!(a["code"], "ana-rakoto-customs-desk");
    assert_eq!(a["person_id"], ANA);
    assert_eq!(a["team_id"], "2");
    assert_eq!(a["role_title"], "Customs desk");
    assert_eq!(a["sort"], 3, "after the last seat of team 2");
    assert_eq!(a["active"], true);
    assert_eq!(a["metrics"], json!([]));
    assert_eq!(a["kpis"], json!([]));
    let id = a["id"].as_str().unwrap().to_string();

    // team_id may also be a number.
    let (s, b) = app
        .call(
            "POST",
            "/api/assignments",
            Some(&t),
            Some(json!({"person_id": ANA, "team_id": 2, "role_title": "Customs desk 2"})),
        )
        .await;
    assert_eq!(s, StatusCode::CREATED, "{b}");

    let dup = json!({"person_id": ANA, "team_id": "2", "role_title": "Customs desk"});
    expect(
        &app,
        "POST",
        "/api/assignments",
        &t,
        dup,
        409,
        "That person already has this role in this team.",
    )
    .await;
    expect(
        &app,
        "POST",
        "/api/assignments",
        &t,
        json!({"person_id": Uuid::new_v4(), "team_id": "2", "role_title": "X"}),
        400,
        "Choose a person.",
    )
    .await;
    expect(
        &app,
        "POST",
        "/api/assignments",
        &t,
        json!({"person_id": ANA, "team_id": "99", "role_title": "X"}),
        400,
        "Choose a team.",
    )
    .await;
    expect(
        &app,
        "POST",
        "/api/assignments",
        &t,
        json!({"person_id": ANA, "team_id": "x", "role_title": "X"}),
        400,
        "Choose a team.",
    )
    .await;
    expect(
        &app,
        "POST",
        "/api/assignments",
        &t,
        json!({"person_id": ANA, "team_id": "1", "role_title": " "}),
        400,
        "Enter a role title.",
    )
    .await;
    expect(
        &app,
        "POST",
        "/api/assignments",
        &t,
        json!({"person_id": ANA, "team_id": "1", "role_title": "r".repeat(81)}),
        400,
        "A role title can have at most 80 characters.",
    )
    .await;

    // Same person and role in another team is a different seat.
    let (s, c) = app
        .call(
            "PATCH",
            &format!("/api/assignments/{id}"),
            Some(&t),
            Some(json!({"team_id": "1", "role_title": "Import", "sort": 9})),
        )
        .await;
    assert_eq!(
        s,
        StatusCode::CONFLICT,
        "Ana already has Import in Tana: {c}"
    );
    assert_eq!(
        c["error"],
        "That person already has this role in this team."
    );
    let (s, c) = app
        .call(
            "PATCH",
            &format!("/api/assignments/{id}"),
            Some(&t),
            Some(json!({"team_id": 1, "role_title": "Customs", "sort": 9})),
        )
        .await;
    assert_eq!(s, StatusCode::OK, "{c}");
    assert_eq!(
        (
            c["team_id"].as_str(),
            c["role_title"].as_str(),
            c["sort"].as_i64()
        ),
        (Some("1"), Some("Customs"), Some(9))
    );
    expect(
        &app,
        "PATCH",
        &format!("/api/assignments/{id}"),
        &t,
        json!({"team_id": "77"}),
        400,
        "Choose a team.",
    )
    .await;
    expect(
        &app,
        "PATCH",
        &format!("/api/assignments/{}", Uuid::new_v4()),
        &t,
        json!({"sort": 1}),
        404,
        "That seat does not exist.",
    )
    .await;
    expect(
        &app,
        "PATCH",
        "/api/assignments/zzz",
        &t,
        json!({"sort": 1}),
        404,
        "That seat does not exist.",
    )
    .await;

    // Deactivate: gone from the default catalog, there with include_inactive.
    let (s, c) = app
        .call(
            "PATCH",
            &format!("/api/assignments/{id}"),
            Some(&t),
            Some(json!({"active": false})),
        )
        .await;
    assert_eq!(s, StatusCode::OK);
    assert_eq!(c["active"], false);
    let cat = catalog(&app, &t, "").await;
    assert!(cat["assignments"]
        .as_array()
        .unwrap()
        .iter()
        .all(|a| a["id"] != id.as_str()));
    let cat = catalog(&app, &t, "?include_inactive=true").await;
    assert_eq!(seat(&cat, &id)["active"], false);
}

#[tokio::test]
async fn include_inactive_is_for_managers_only() {
    let app = TestApp::new().await;
    let t = boss(&app).await;
    let plain = catalog(&app, &t, "").await;
    assert_eq!(plain["persons"].as_array().unwrap().len(), 3);
    assert_eq!(plain["assignments"].as_array().unwrap().len(), 3);
    assert!(plain["persons"]
        .as_array()
        .unwrap()
        .iter()
        .all(|p| p["active"] == true));

    let all = catalog(&app, &t, "?include_inactive=true").await;
    let persons = all["persons"].as_array().unwrap();
    assert_eq!(persons.len(), 4);
    let dan = persons
        .iter()
        .find(|p| p["full_name"] == "Dan Gone")
        .unwrap();
    assert_eq!(dan["active"], false);
    assert_eq!(dan["email"], "dan@example.org");
    assert_eq!(all["assignments"].as_array().unwrap().len(), 4);
    assert_eq!(
        seat(&all, "00000000-0000-0000-0000-0000000000d4")["active"],
        false
    );
    // Retired counts and targets stay hidden.
    assert_eq!(labels(seat(&all, A_ANA)), ["Files", "Calls"]);
    assert_eq!(seat(&all, A_ANA)["kpis"].as_array().unwrap().len(), 2);
    assert!(all.get("suggestions").is_none());

    let ana = app.login("ana@example.org").await;
    // A contributor gets only themselves, whatever they ask for.
    let v = catalog(&app, &ana, "?include_inactive=true").await;
    assert_eq!(v["persons"].as_array().unwrap().len(), 1);
    assert_eq!(v["persons"][0]["id"], ANA);
    assert_eq!(v["assignments"].as_array().unwrap().len(), 1);
    assert_eq!(v["teams"].as_array().unwrap().len(), 1);
}

#[tokio::test]
async fn a_seat_of_an_inactive_person_is_hidden_unless_asked_for() {
    let app = TestApp::new().await;
    let t = boss(&app).await;
    let (s, _) = app
        .call(
            "PATCH",
            &format!("/api/persons/{ANA}"),
            Some(&t),
            Some(json!({"active": false})),
        )
        .await;
    assert_eq!(s, StatusCode::OK);
    // The seat itself is still active, but its person is not.
    let plain = catalog(&app, &t, "").await;
    assert!(plain["persons"]
        .as_array()
        .unwrap()
        .iter()
        .all(|p| p["id"] != ANA));
    assert!(plain["assignments"]
        .as_array()
        .unwrap()
        .iter()
        .all(|a| a["person_id"] != ANA));
    let all = catalog(&app, &t, "?include_inactive=true").await;
    assert_eq!(seat(&all, A_ANA)["person_id"], ANA);
    let ben = app.login("ben@example.org").await;
    let v = catalog(&app, &ben, "").await;
    assert!(v["assignments"]
        .as_array()
        .unwrap()
        .iter()
        .all(|a| a["person_id"] != ANA));
}

#[tokio::test]
async fn lookalike_spaces_fold_to_one_plain_space_and_role_titles_ignore_case() {
    let app = TestApp::new().await;
    let t = boss(&app).await;
    let (s, team) = app
        .call(
            "POST",
            "/api/teams",
            Some(&t),
            Some(json!({"name": "  Sea\u{00A0}\u{3000}freight\u{2003} "})),
        )
        .await;
    assert_eq!(s, StatusCode::CREATED, "{team}");
    assert_eq!(team["name"], "Sea freight");
    // The same name with a no-break space is a case twin of the first team.
    let (s, _) = app
        .call(
            "POST",
            "/api/teams",
            Some(&t),
            Some(json!({"name": "sea\u{00A0}FREIGHT"})),
        )
        .await;
    assert_ne!(s, StatusCode::CREATED);
    let (s, p) = app
        .call(
            "POST",
            "/api/persons",
            Some(&t),
            Some(json!({"full_name": "Zed\u{00A0}\u{00A0}Quill", "email": "zed@example.org", "app_role": "contributor"})),
        )
        .await;
    assert_eq!(s, StatusCode::CREATED, "{p}");
    assert_eq!(p["full_name"], "Zed Quill");
    let body =
        |title: &str| json!({"person_id": p["id"], "team_id": team["id"], "role_title": title});
    let (s, seat1) = app
        .call(
            "POST",
            "/api/assignments",
            Some(&t),
            Some(body("Import\u{00A0}desk")),
        )
        .await;
    assert_eq!(s, StatusCode::CREATED, "{seat1}");
    assert_eq!(seat1["role_title"], "Import desk");
    let (s, _) = app
        .call(
            "POST",
            "/api/assignments",
            Some(&t),
            Some(body("IMPORT  DESK")),
        )
        .await;
    assert_eq!(s, StatusCode::CONFLICT);
}

// ---------- counts and targets ----------

#[tokio::test]
async fn five_counts_can_be_defined_reordered_retired_and_added_again() {
    let app = TestApp::new().await;
    let t = boss(&app).await;

    // Cora's seat starts with no counts.
    let five = json!({"metrics": [
        {"label": "Sea"}, {"label": " Air "}, {"label": "Road"}, {"label": "Rail"}, {"label": "Road!"}
    ], "kpis": []});
    let (s, a) = defs(&app, &t, A_CORA, five).await;
    assert_eq!(s, StatusCode::OK, "{a}");
    assert_eq!(labels(&a), ["Sea", "Air", "Road", "Rail", "Road!"]);
    let series: Vec<i64> = a["metrics"]
        .as_array()
        .unwrap()
        .iter()
        .map(|m| m["series"].as_i64().unwrap())
        .collect();
    assert_eq!(series, [0, 1, 2, 3, 4]);
    let keys: Vec<&str> = a["metrics"]
        .as_array()
        .unwrap()
        .iter()
        .map(|m| m["key"].as_str().unwrap())
        .collect();
    assert_eq!(
        keys,
        ["sea", "air", "road", "rail", "road-2"],
        "keys are slugs, unique in the seat"
    );
    assert_eq!(
        a["kpis"],
        json!([]),
        "targets list sent empty retires Keep calm"
    );
    let ids: Vec<String> = a["metrics"]
        .as_array()
        .unwrap()
        .iter()
        .map(|m| m["id"].as_str().unwrap().to_string())
        .collect();

    // Reverse the order, rename one, drop one, add one.
    let (s, b) = defs(
        &app,
        &t,
        A_CORA,
        json!({"metrics": [
        {"id": ids[4], "label": "Pipeline"},
        {"id": ids[3], "label": "Rail"},
        {"label": "Sea"},
        {"id": ids[0], "label": "Sea (old)"},
        {"id": ids[1], "label": "Air"}
    ], "kpis": []}),
    )
    .await;
    assert_eq!(s, StatusCode::OK, "{b}");
    assert_eq!(labels(&b), ["Pipeline", "Rail", "Sea", "Sea (old)", "Air"]);
    let m = b["metrics"].as_array().unwrap();
    assert_eq!(m[0]["id"], ids[4].as_str(), "same id, new label and place");
    assert_eq!(m[0]["key"], "road-2", "the key does not change on rename");
    assert_eq!(m[1]["id"], ids[3].as_str());
    assert_eq!(
        m[2]["key"], "sea-2",
        "a new count whose slug is taken by a retired or live one"
    );
    assert_eq!(m[3]["id"], ids[0].as_str());
    assert_eq!(m[3]["key"], "sea");
    assert_eq!(
        m.iter()
            .map(|x| x["series"].as_i64().unwrap())
            .collect::<Vec<_>>(),
        [0, 1, 2, 3, 4]
    );
    // "Road" (ids[2]) was dropped and is retired, not deleted.
    let (retired, total): (i64, i64) = sqlx::query_as(
        "select count(*) filter (where retired_at is not null), count(*) from metric_def where assignment_id = $1",
    )
    .bind(Uuid::parse_str(A_CORA).unwrap())
    .fetch_one(&app.state.pool)
    .await
    .unwrap();
    assert_eq!(
        (retired, total),
        (1, 5 + 1),
        "Road retired, Sea (new) added"
    );
    let cat = catalog(&app, &t, "").await;
    assert_eq!(
        labels(seat(&cat, A_CORA)),
        ["Pipeline", "Rail", "Sea", "Sea (old)", "Air"]
    );

    // Adding a name that only a retired count used gets a fresh key.
    let (s, c) = defs(
        &app,
        &t,
        A_CORA,
        json!({"metrics": [{"label": "Road"}], "kpis": []}),
    )
    .await;
    assert_eq!(s, StatusCode::OK, "{c}");
    assert_eq!(labels(&c), ["Road"]);
    assert_eq!(c["metrics"][0]["key"], "road-3");
    assert_eq!(c["metrics"][0]["series"], 0);

    // Everything can be cleared.
    let (s, d) = defs(&app, &t, A_CORA, json!({"metrics": [], "kpis": []})).await;
    assert_eq!(s, StatusCode::OK);
    assert_eq!(d["metrics"], json!([]));
}

#[tokio::test]
async fn a_seat_can_have_eight_counts_and_no_more() {
    let app = TestApp::new().await;
    let t = boss(&app).await;
    let eight: Vec<Value> = (1..=8)
        .map(|i| json!({"label": format!("Count {i}")}))
        .collect();
    let (s, a) = defs(&app, &t, A_CORA, json!({"metrics": eight, "kpis": []})).await;
    assert_eq!(s, StatusCode::OK, "{a}");
    assert_eq!(a["metrics"].as_array().unwrap().len(), 8);
    // Reversing all eight in one go works despite the unique index.
    let mut rev: Vec<Value> = a["metrics"]
        .as_array()
        .unwrap()
        .iter()
        .map(|m| json!({"id": m["id"], "label": m["label"]}))
        .collect();
    rev.reverse();
    let (s, b) = defs(&app, &t, A_CORA, json!({"metrics": rev, "kpis": []})).await;
    assert_eq!(s, StatusCode::OK, "{b}");
    assert_eq!(
        labels(&b),
        ["Count 8", "Count 7", "Count 6", "Count 5", "Count 4", "Count 3", "Count 2", "Count 1"]
    );
    let nine: Vec<Value> = (1..=9).map(|i| json!({"label": format!("C{i}")})).collect();
    expect(
        &app,
        "PUT",
        &format!("/api/assignments/{A_CORA}/definitions"),
        &t,
        json!({"metrics": nine, "kpis": []}),
        400,
        "A seat can have at most 8 counts.",
    )
    .await;
}

#[tokio::test]
async fn definition_errors_are_plain_and_change_nothing() {
    let app = TestApp::new().await;
    let t = boss(&app).await;
    let uri = format!("/api/assignments/{A_ANA}/definitions");
    let before = catalog(&app, &t, "").await;

    expect(
        &app,
        "PUT",
        &uri,
        &t,
        json!({"metrics": [{"label": " "}], "kpis": []}),
        400,
        "Give every count a name.",
    )
    .await;
    expect(
        &app,
        "PUT",
        &uri,
        &t,
        json!({"metrics": [{"label": "x".repeat(61)}], "kpis": []}),
        400,
        "A count name can have at most 60 characters.",
    )
    .await;
    expect(
        &app,
        "PUT",
        &uri,
        &t,
        json!({"metrics": [{"label": "Sea"}, {"label": "SEA"}], "kpis": []}),
        400,
        "Two counts have the same name. Give each count its own name.",
    )
    .await;
    expect(
        &app,
        "PUT",
        &uri,
        &t,
        json!({"metrics": [], "kpis": [{"text": ""}]}),
        400,
        "Write every target in words.",
    )
    .await;
    expect(
        &app,
        "PUT",
        &uri,
        &t,
        json!({"metrics": [], "kpis": [{"text": "k".repeat(201)}]}),
        400,
        "A target can have at most 200 characters.",
    )
    .await;
    let many: Vec<Value> = (0..11).map(|i| json!({"text": format!("t{i}")})).collect();
    expect(
        &app,
        "PUT",
        &uri,
        &t,
        json!({"metrics": [], "kpis": many}),
        400,
        "A seat can have at most 10 targets.",
    )
    .await;
    let belongs = "One of the counts or targets does not belong to this seat.";
    expect(
        &app,
        "PUT",
        &uri,
        &t,
        json!({"metrics": [{"id": M_BOXES, "label": "Boxes"}], "kpis": []}),
        400,
        belongs,
    )
    .await;
    expect(
        &app,
        "PUT",
        &uri,
        &t,
        json!({"metrics": [{"id": M_OLD, "label": "Old"}], "kpis": []}),
        400,
        belongs,
    )
    .await;
    // A foreign target after valid counts: the counts are rolled back too.
    expect(
        &app,
        "PUT",
        &uri,
        &t,
        json!({"metrics": [{"label": "Fresh"}], "kpis": [{"id": K_SHIP, "text": "x"}]}),
        400,
        belongs,
    )
    .await;
    expect(&app, "PUT", &uri, &t, json!({"metrics": [{"id": M_FILES, "label": "A"}, {"id": M_FILES, "label": "B"}], "kpis": []}), 400, "The same count is listed twice.").await;
    expect(
        &app,
        "PUT",
        &format!("/api/assignments/{}/definitions", Uuid::new_v4()),
        &t,
        json!({"metrics": [], "kpis": []}),
        404,
        "That seat does not exist.",
    )
    .await;
    let (s, v) = app
        .call("PUT", &uri, Some(&t), Some(json!({"metrics": "no"})))
        .await;
    assert_eq!(s, StatusCode::BAD_REQUEST);
    assert_eq!(v["error"], "That request is not valid.");

    assert_eq!(catalog(&app, &t, "").await, before, "nothing changed");
}

#[tokio::test]
async fn changed_target_wording_creates_a_new_row_and_old_reports_keep_theirs() {
    let app = TestApp::new().await;
    let t = boss(&app).await;
    let ana = app.login("ana@example.org").await;
    let period = app.ensure_period(&t, "2026-02-01").await;
    let (s, v) = app.put_report(&ana, &period, A_ANA, ana_report()).await;
    assert_eq!(s, StatusCode::OK, "{v}");

    let (s, a) = defs(
        &app,
        &t,
        A_ANA,
        json!({
            "metrics": [{"id": M_FILES, "label": "Files"}, {"id": M_CALLS, "label": "Calls"}],
            "kpis": [
                {"text": "A brand new one"},
                {"id": K_NOERR, "text": "No errors"},
                {"id": K_ONTIME, "text": "Always on time"}
            ]
        }),
    )
    .await;
    assert_eq!(s, StatusCode::OK, "{a}");
    let k = a["kpis"].as_array().unwrap();
    assert_eq!(
        k.iter()
            .map(|x| x["text"].as_str().unwrap())
            .collect::<Vec<_>>(),
        ["A brand new one", "No errors", "Always on time"]
    );
    assert_eq!(
        k.iter()
            .map(|x| x["sort"].as_i64().unwrap())
            .collect::<Vec<_>>(),
        [1, 2, 3]
    );
    assert_eq!(k[1]["id"], K_NOERR, "unchanged wording keeps its row");
    assert_ne!(k[2]["id"], K_ONTIME, "changed wording gets a new row");

    let (retired,): (bool,) =
        sqlx::query_as("select retired_at is not null from kpi_def where id = $1::uuid")
            .bind(K_ONTIME)
            .fetch_one(&app.state.pool)
            .await
            .unwrap();
    assert!(retired);
    // The sent report still points at the old wording.
    let (text, status): (String, String) = sqlx::query_as(
        "select k.text, r.status::text from report_kpi_result r join kpi_def k on k.id = r.kpi_def_id
         where r.kpi_def_id = $1::uuid",
    )
    .bind(K_ONTIME)
    .fetch_one(&app.state.pool)
    .await
    .unwrap();
    assert_eq!((text.as_str(), status.as_str()), ("On time", "met"));
    assert_eq!(app.count("report_kpi_result").await, 2);
    let (s, r) = app
        .call(
            "GET",
            &format!("/api/periods/{period}/reports/{A_ANA}"),
            Some(&ana),
            None,
        )
        .await;
    assert_eq!(s, StatusCode::OK, "{r}");

    // Removing a target retires it as well.
    let (_, b) = defs(&app, &t, A_ANA, json!({"metrics": [{"id": M_FILES, "label": "Files"}], "kpis": [{"id": K_NOERR, "text": "No errors"}]})).await;
    assert_eq!(b["kpis"].as_array().unwrap().len(), 1);
    assert_eq!(labels(&b), ["Files"]);
    let retired: i64 = sqlx::query_scalar(
        "select count(*) from kpi_def where assignment_id = $1 and retired_at is not null",
    )
    .bind(Uuid::parse_str(A_ANA).unwrap())
    .fetch_one(&app.state.pool)
    .await
    .unwrap();
    assert_eq!(
        retired, 4,
        "the fixture one, On time, A brand new one and Always on time"
    );
}

// ---------- summary ----------

async fn send(app: &TestApp, who: &str, period: &str, seat: &str, body: Value) {
    let (s, v) = app.put_report(who, period, seat, body).await;
    assert_eq!(s, StatusCode::OK, "{v}");
}

fn files_report(a: i64, b: i64, c: i64) -> Value {
    json!({
        "reporter": {"name": "Ana Rakoto", "country": "Tana", "role": "Import"},
        "values": [
            {"metric_def_id": M_FILES, "month_offset": 0, "value": a},
            {"metric_def_id": M_FILES, "month_offset": 1, "value": b},
            {"metric_def_id": M_FILES, "month_offset": 2, "value": c},
            {"metric_def_id": M_CALLS, "month_offset": 0, "value": 2},
            {"metric_def_id": M_CALLS, "month_offset": 1, "value": 2},
            {"metric_def_id": M_CALLS, "month_offset": 2, "value": 2},
        ],
        "kpis": [
            {"kpi_def_id": K_ONTIME, "status": "met"},
            {"kpi_def_id": K_NOERR, "status": "met"},
        ],
        "notes": [],
    })
}

#[tokio::test]
async fn summary_numbers_trend_and_label_grouping() {
    let app = TestApp::new().await;
    let t = boss(&app).await;
    let ana = app.login("ana@example.org").await;
    let ben = app.login("ben@example.org").await;

    // Ben's "Boxes" is renamed "files": it groups with Ana's "Files" by lower case label.
    let (s, _) = defs(&app, &t, A_BEN, json!({"metrics": [{"id": M_BOXES, "label": "files"}], "kpis": [{"id": K_SHIP, "text": "Ship fast"}]})).await;
    assert_eq!(s, StatusCode::OK);

    let aug = app.ensure_period(&t, "2025-08-01").await;
    let nov = app.ensure_period(&t, "2025-11-01").await;
    let feb = app.ensure_period(&t, "2026-02-01").await;
    let _empty = app.ensure_period(&t, "2026-05-01").await;

    // Aug: only Ben, 5+5+5 = 15, one target met.
    send(
        &app,
        &ben,
        &aug,
        A_BEN,
        json!({
            "reporter": {"name": "Ben Rabe", "country": "Tana", "role": "Export"},
            "values": [
                {"metric_def_id": M_BOXES, "month_offset": 0, "value": 5},
                {"metric_def_id": M_BOXES, "month_offset": 1, "value": 5},
                {"metric_def_id": M_BOXES, "month_offset": 2, "value": 5},
            ],
            "kpis": [{"kpi_def_id": K_SHIP, "status": "met"}],
            "notes": [],
        }),
    )
    .await;
    // Nov: only Ana, files 1,1,1 and calls 2,2,2 = 9, two met.
    send(&app, &ana, &nov, A_ANA, files_report(1, 1, 1)).await;
    // Feb: Ana (files 10,11,12; calls 0,5,6; met, partly), Ben (1,2,3; missed), Cora (met).
    send(&app, &ana, &feb, A_ANA, ana_report()).await;
    send(&app, &ben, &feb, A_BEN, ben_report()).await;
    send(&app, &t, &feb, A_CORA, cora_report()).await;
    // A draft never counts.
    app.sql(&format!(
        "insert into report (period_id, assignment_id, status) values ('{aug}', '{A_CORA}', 'draft')"
    )).await;

    let (s, v) = app
        .call(
            "GET",
            &format!("/api/summary?period_id={feb}&trend=6"),
            Some(&t),
            None,
        )
        .await;
    assert_eq!(s, StatusCode::OK, "{v}");
    assert_eq!(v["period_id"], feb.as_str());
    assert_eq!(v["period_label"], "Feb to Apr 2026");
    assert_eq!(
        v["months"][2],
        json!({"offset": 2, "year": 2026, "month": 4, "short": "Apr"})
    );
    assert_eq!(v["expected"], 3);
    assert_eq!(v["submitted"], 3);

    // Tana: Ben + Ana. Files 1,2,3 + 10,11,12, calls 0,5,6, so [11, 18, 21].
    assert_eq!(
        v["teams"],
        json!([
            {"team_id": "1", "name": "Tana", "expected": 2, "submitted": 2, "submitted_inactive": 0, "met": 1, "partly": 1, "missed": 1, "volume_by_month": [11, 18, 21]},
            {"team_id": "2", "name": "Antsirabe", "expected": 1, "submitted": 1, "submitted_inactive": 0, "met": 1, "partly": 0, "missed": 0, "volume_by_month": [0, 0, 0]},
        ])
    );
    // Files: Ben's "files" came first in deck order, so its label is displayed.
    assert_eq!(
        v["metrics"],
        json!([
            {"label": "files", "total": 39, "by_month": [11, 13, 15], "by_team": [{"team": "Tana", "total": 39}]},
            {"label": "Calls", "total": 11, "by_month": [0, 5, 6], "by_team": [{"team": "Tana", "total": 11}]},
        ])
    );
    // Trend: Aug 15, Nov 9, Feb 50. Expected is the active seats now.
    let trend = v["trend"].as_array().unwrap();
    assert_eq!(trend.len(), 3);
    assert_eq!(
        trend[0],
        json!({"period_id": aug, "label": "Aug to Oct 2025", "start_month": "2025-08-01",
        "expected": 3, "submitted": 1, "submitted_inactive": 0, "met": 1, "partly": 0, "missed": 0, "volume_total": 15})
    );
    assert_eq!(
        trend[1],
        json!({"period_id": nov, "label": "Nov 2025 to Jan 2026", "start_month": "2025-11-01",
        "expected": 3, "submitted": 1, "submitted_inactive": 0, "met": 2, "partly": 0, "missed": 0, "volume_total": 9})
    );
    assert_eq!(
        trend[2],
        json!({"period_id": feb, "label": "Feb to Apr 2026", "start_month": "2026-02-01",
        "expected": 3, "submitted": 3, "submitted_inactive": 0, "met": 2, "partly": 1, "missed": 1, "volume_total": 50})
    );
    // People in deck order, with the numbers of their own report.
    assert_eq!(
        v["people"],
        json!([
            {"assignment_id": A_BEN, "name": "Ben Rabe", "role": "Export", "team": "Tana", "active": true, "submitted": true, "met": 0, "partly": 0, "missed": 1, "volume_total": 6},
            {"assignment_id": A_ANA, "name": "Ana Rakoto", "role": "Import", "team": "Tana", "active": true, "submitted": true, "met": 1, "partly": 1, "missed": 0, "volume_total": 44},
            {"assignment_id": A_CORA, "name": "Cora Boss", "role": "Operations", "team": "Antsirabe", "active": true, "submitted": true, "met": 1, "partly": 0, "missed": 0, "volume_total": 0},
        ])
    );

    // The trend length is respected, the shown period is last.
    let (_, v2) = app
        .call(
            "GET",
            &format!("/api/summary?period_id={feb}&trend=2"),
            Some(&t),
            None,
        )
        .await;
    let labels: Vec<&str> = v2["trend"]
        .as_array()
        .unwrap()
        .iter()
        .map(|x| x["label"].as_str().unwrap())
        .collect();
    assert_eq!(labels, ["Nov 2025 to Jan 2026", "Feb to Apr 2026"]);
    let (_, v1) = app
        .call(
            "GET",
            &format!("/api/summary?period_id={feb}&trend=1"),
            Some(&t),
            None,
        )
        .await;
    assert_eq!(v1["trend"].as_array().unwrap().len(), 1);
    // Default is 6, and the oldest period shown has nothing before it.
    let (_, vd) = app
        .call(
            "GET",
            &format!("/api/summary?period_id={aug}"),
            Some(&t),
            None,
        )
        .await;
    assert_eq!(vd["trend"].as_array().unwrap().len(), 1);
    assert_eq!(vd["submitted"], 1);
    assert_eq!(
        vd["teams"].as_array().unwrap().len(),
        2,
        "both teams have active seats"
    );
    assert_eq!(vd["metrics"][0]["total"], 15);

    // A period with no reports is all zero but still lists who is expected.
    let empty = app.ensure_period(&t, "2026-05-01").await;
    let (_, ve) = app
        .call(
            "GET",
            &format!("/api/summary?period_id={empty}&trend=3"),
            Some(&t),
            None,
        )
        .await;
    assert_eq!(ve["submitted"], 0);
    assert_eq!(ve["metrics"], json!([]));
    assert_eq!(ve["people"].as_array().unwrap().len(), 3);
    assert!(ve["people"]
        .as_array()
        .unwrap()
        .iter()
        .all(|p| p["submitted"] == false));
    assert_eq!(ve["trend"].as_array().unwrap().len(), 3);

    // A deactivated seat stops being expected, its sent report stays in the volume and the list
    // but is not counted as submitted (so submitted never exceeds expected).
    let (s, _) = app
        .call(
            "PATCH",
            &format!("/api/assignments/{A_BEN}"),
            Some(&t),
            Some(json!({"active": false})),
        )
        .await;
    assert_eq!(s, StatusCode::OK);
    let (_, vb) = app
        .call(
            "GET",
            &format!("/api/summary?period_id={feb}"),
            Some(&t),
            None,
        )
        .await;
    assert_eq!(vb["expected"], 2);
    assert_eq!(vb["submitted"], 2);
    assert_eq!(vb["submitted_inactive"], 1);
    assert_eq!(vb["trend"][2]["volume_total"], 50);
    assert_eq!(vb["people"].as_array().unwrap().len(), 3);
    let (_, vb) = app
        .call(
            "GET",
            &format!("/api/summary?period_id={empty}"),
            Some(&t),
            None,
        )
        .await;
    assert_eq!(vb["people"].as_array().unwrap().len(), 2);
}

#[tokio::test]
async fn summary_asks_for_a_real_period_and_a_sane_trend() {
    let app = TestApp::new().await;
    let t = boss(&app).await;
    let feb = app.ensure_period(&t, "2026-02-01").await;
    let get = |q: String| {
        let (app, t) = (&app, t.clone());
        async move {
            app.call("GET", &format!("/api/summary{q}"), Some(&t), None)
                .await
        }
    };
    for q in ["", "?period_id=nope"] {
        let (s, v) = get(q.to_string()).await;
        assert_eq!(s, StatusCode::BAD_REQUEST, "{q}");
        assert_eq!(v["error"], "Choose a period.");
    }
    let (s, v) = get(format!("?period_id={}", Uuid::new_v4())).await;
    assert_eq!(s, StatusCode::NOT_FOUND);
    assert_eq!(v["error"], "That period does not exist.");
    for n in ["0", "25", "x", "-1"] {
        let (s, v) = get(format!("?period_id={feb}&trend={n}")).await;
        assert_eq!(s, StatusCode::BAD_REQUEST, "trend {n}");
        assert_eq!(v["error"], "The trend must be a number from 1 to 24.");
    }
    let (s, _) = get(format!("?period_id={feb}&trend=24")).await;
    assert_eq!(s, StatusCode::OK);
}

// ---------- notes stay free text ----------

#[tokio::test]
async fn notes_stay_free_text_with_the_old_limits() {
    let app = TestApp::new().await;
    let ana = app.login("ana@example.org").await;
    let period = app.ensure_period(&ana, "2026-02-01").await;
    let mut body = ana_report();
    body["notes"] = json!([{"kind": "well", "position": 1, "text": "é".repeat(70)}]);
    let (s, v) = app.put_report(&ana, &period, A_ANA, body).await;
    assert_eq!(s, StatusCode::OK, "70 characters, not bytes: {v}");
    let mut body = ana_report();
    body["notes"] = json!([{"kind": "well", "position": 1, "text": "é".repeat(71)}]);
    let (s, _) = app.put_report(&ana, &period, A_ANA, body).await;
    assert_eq!(s, StatusCode::BAD_REQUEST);
}
