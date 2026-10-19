//! The "perfect" review of the data paths: edge cases around periods, seats and definitions.

mod common;

use axum::http::StatusCode;
use common::*;
use serde_json::{json, Value};

async fn boss(app: &TestApp) -> String {
    app.login("cora@example.org").await
}

async fn deck(app: &TestApp, t: &str, p: &str) -> Value {
    let (s, v) = app
        .call("POST", &format!("/api/periods/{p}/deck"), Some(t), None)
        .await;
    assert_eq!(s, StatusCode::CREATED, "{v}");
    v
}

#[tokio::test]
async fn a_deck_shows_what_the_report_answered_even_after_the_definitions_changed() {
    let app = TestApp::new().await;
    let t = boss(&app).await;
    let p = app.ensure_period(&t, "2026-02-01").await;
    let (s, v) = app.put_report(&t, &p, A_ANA, ana_report()).await;
    assert_eq!(s, StatusCode::OK, "{v}");

    // The manager edits Ana's seat after she sent her report: Calls is dropped, Visits is new,
    // "On time" gets new wording.
    let (s, v) = app
        .call(
            "PUT",
            &format!("/api/assignments/{A_ANA}/definitions"),
            Some(&t),
            Some(json!({
                "metrics": [{"id": M_FILES, "label": "Files"}, {"label": "Visits"}],
                "kpis": [{"id": K_ONTIME, "text": "On time, within a day"}, {"id": K_NOERR, "text": "No errors"}],
            })),
        )
        .await;
    assert_eq!(s, StatusCode::OK, "{v}");

    let d = deck(&app, &t, &p).await;
    let snap = d["items"]
        .as_array()
        .unwrap()
        .iter()
        .map(|i| &i["snapshot"])
        .find(|s| s["assignmentCode"] == "ana-import")
        .unwrap();
    let labels: Vec<&str> = snap["metrics"]
        .as_array()
        .unwrap()
        .iter()
        .map(|m| m["label"].as_str().unwrap())
        .collect();
    assert_eq!(labels, vec!["Files", "Calls"], "{snap}");
    assert_eq!(snap["metrics"][1]["values"], json!([0, 5, 6]));
    let targets: Vec<(&str, Option<&str>)> = snap["targets"]
        .as_array()
        .unwrap()
        .iter()
        .map(|t| (t["text"].as_str().unwrap(), t["status"].as_str()))
        .collect();
    assert_eq!(
        targets,
        vec![("On time", Some("met")), ("No errors", Some("partly"))],
        "{snap}"
    );
    // Series stay one per count, so the chart colours never repeat inside one slide.
    let series: Vec<i64> = snap["metrics"]
        .as_array()
        .unwrap()
        .iter()
        .map(|m| m["series"].as_i64().unwrap())
        .collect();
    let mut uniq = series.clone();
    uniq.sort();
    uniq.dedup();
    assert_eq!(uniq.len(), series.len(), "{series:?}");
}

#[tokio::test]
async fn colours_stay_unique_when_a_retired_count_and_a_moved_count_share_a_series() {
    let app = TestApp::new().await;
    let t = boss(&app).await;
    let p = app.ensure_period(&t, "2026-02-01").await;
    // Ana has Files (0) and Calls (1). Report, then retire Files: Calls moves to series 0 while
    // retired Files keeps 0, so both are answered in the report and both claim series 0.
    app.put_report(&t, &p, A_ANA, ana_report()).await;
    app.call(
        "PUT",
        &format!("/api/assignments/{A_ANA}/definitions"),
        Some(&t),
        Some(json!({
            "metrics": [{"id": M_CALLS, "label": "Calls"}],
            "kpis": [{"id": K_ONTIME, "text": "On time"}, {"id": K_NOERR, "text": "No errors"}],
        })),
    )
    .await;
    let d = deck(&app, &t, &p).await;
    let snap = d["items"]
        .as_array()
        .unwrap()
        .iter()
        .map(|i| &i["snapshot"])
        .find(|s| s["assignmentCode"] == "ana-import")
        .unwrap();
    let series: Vec<i64> = snap["metrics"]
        .as_array()
        .unwrap()
        .iter()
        .map(|m| m["series"].as_i64().unwrap())
        .collect();
    assert_eq!(series.len(), 2, "{snap}");
    assert_ne!(series[0], series[1], "{snap}");
}

async fn summary(app: &TestApp, t: &str, p: &str) -> Value {
    let (s, v) = app
        .call("GET", &format!("/api/summary?period_id={p}"), Some(t), None)
        .await;
    assert_eq!(s, StatusCode::OK, "{v}");
    v
}

#[tokio::test]
async fn a_fresh_install_has_an_empty_but_valid_summary_and_deck() {
    let app = TestApp::empty().await;
    app.sql("insert into person (id, full_name, email, app_role) values ('00000000-0000-0000-0000-0000000000a3', 'Cora', 'cora@example.org', 'controller')").await;
    let t = app.login("cora@example.org").await;
    let p = app.ensure_period(&t, "2026-02-01").await;
    let s = summary(&app, &t, &p).await;
    assert_eq!(s["expected"], 0);
    assert_eq!(s["submitted"], 0);
    for k in ["teams", "metrics", "people"] {
        assert_eq!(s[k], json!([]), "{k}");
    }
    assert_eq!(s["trend"].as_array().unwrap().len(), 1);
    assert_eq!(s["trend"][0]["volume_total"], 0);
    let d = deck(&app, &t, &p).await;
    assert_eq!(d["expected_count"], 0);
    assert_eq!(d["included_count"], 0);
    assert_eq!(d["items"], json!([]));
    let (s, v) = app
        .call("GET", &format!("/api/periods/{p}/reports"), Some(&t), None)
        .await;
    assert_eq!((s, v), (StatusCode::OK, json!([])));
}

#[tokio::test]
async fn an_empty_period_of_a_full_catalog_counts_everyone_as_missing() {
    let app = TestApp::new().await;
    let t = boss(&app).await;
    let p = app.ensure_period(&t, "2026-02-01").await;
    let s = summary(&app, &t, &p).await;
    assert_eq!(
        (s["expected"].as_i64(), s["submitted"].as_i64()),
        (Some(3), Some(0))
    );
    assert_eq!(s["people"].as_array().unwrap().len(), 3);
    assert!(s["people"]
        .as_array()
        .unwrap()
        .iter()
        .all(|x| x["submitted"] == false));
    assert_eq!(s["metrics"], json!([]));
    let d = deck(&app, &t, &p).await;
    assert_eq!(
        (d["expected_count"].as_i64(), d["included_count"].as_i64()),
        (Some(3), Some(0))
    );
}

#[tokio::test]
async fn the_edges_of_the_calendar() {
    let app = TestApp::new().await;
    let t = boss(&app).await;
    for (date, want) in [
        ("1999-12-01", StatusCode::BAD_REQUEST),
        ("2101-01-01", StatusCode::BAD_REQUEST),
        ("2000-01-01", StatusCode::OK),
        ("2100-12-31", StatusCode::OK),
        ("2023-02-29", StatusCode::BAD_REQUEST),
        ("2024-02-29", StatusCode::OK),
        ("2026-13-01", StatusCode::BAD_REQUEST),
        ("not a date", StatusCode::BAD_REQUEST),
        ("0000-00-00", StatusCode::BAD_REQUEST),
        ("", StatusCode::BAD_REQUEST),
    ] {
        let (s, v) = app
            .call(
                "POST",
                "/api/periods/ensure",
                Some(&t),
                Some(json!({"start_month": date})),
            )
            .await;
        assert_eq!(s, want, "{date}: {v}");
        if s == StatusCode::BAD_REQUEST {
            assert!(
                v["error"].as_str().unwrap().starts_with("Enter a date"),
                "{date}: {v}"
            );
        }
    }
    // The first day of the month is stored, whatever day was sent.
    let (_, v) = app
        .call(
            "POST",
            "/api/periods/ensure",
            Some(&t),
            Some(json!({"start_month": "2024-02-29"})),
        )
        .await;
    assert_eq!(v["start_month"], "2024-02-01");

    // The last allowed period crosses into 2101 in its label and months.
    let p = app.ensure_period(&t, "2100-12-15").await;
    let s = summary(&app, &t, &p).await;
    assert_eq!(s["period_label"], "Dec 2100 to Feb 2101");
    assert_eq!(
        s["months"][2],
        json!({"offset": 2, "year": 2101, "month": 2, "short": "Feb"})
    );
    let (st, rep) = app.put_report(&t, &p, A_ANA, ana_report()).await;
    assert_eq!(st, StatusCode::OK, "{rep}");
    let d = deck(&app, &t, &p).await;
    assert_eq!(
        d["items"][0]["snapshot"]["periodLabel"],
        "Dec 2100 to Feb 2101"
    );
    // The database refuses what the API refuses, even by hand.
    let e = sqlx::query("insert into period (start_month) values ('1999-01-01')")
        .execute(&app.state.pool)
        .await;
    assert!(e.is_err());
    // The meeting date has the same range.
    for (d, want) in [
        ("1999-12-31", 400),
        ("2101-01-01", 400),
        ("2100-12-31", 200),
    ] {
        let (s, _) = app
            .call(
                "PATCH",
                &format!("/api/periods/{p}"),
                Some(&t),
                Some(json!({"meeting_date": d})),
            )
            .await;
        assert_eq!(s.as_u16(), want, "{d}");
    }
    // No meeting date at all clears it.
    let (s, v) = app
        .call(
            "PATCH",
            &format!("/api/periods/{p}"),
            Some(&t),
            Some(json!({"meeting_date": null})),
        )
        .await;
    assert_eq!(
        (s, v["meeting_date"].clone()),
        (StatusCode::OK, Value::Null)
    );
}

#[tokio::test]
async fn a_team_without_seats_is_in_the_catalog_but_not_in_the_summary() {
    let app = TestApp::new().await;
    let t = boss(&app).await;
    let (s, team) = app
        .call(
            "POST",
            "/api/teams",
            Some(&t),
            Some(json!({"name": "Nobody Here"})),
        )
        .await;
    assert_eq!(s, StatusCode::CREATED, "{team}");
    let p = app.ensure_period(&t, "2026-02-01").await;
    let sm = summary(&app, &t, &p).await;
    let names: Vec<&str> = sm["teams"]
        .as_array()
        .unwrap()
        .iter()
        .map(|x| x["name"].as_str().unwrap())
        .collect();
    assert_eq!(names, vec!["Tana", "Antsirabe"]);
    let (_, cat) = app.call("GET", "/api/catalog", Some(&t), None).await;
    assert_eq!(cat["teams"].as_array().unwrap().len(), 3);
    let (s, _) = app
        .call(
            "DELETE",
            &format!("/api/teams/{}", team["id"].as_str().unwrap()),
            Some(&t),
            None,
        )
        .await;
    assert_eq!(s, StatusCode::NO_CONTENT);
}

#[tokio::test]
async fn one_person_with_two_seats_in_the_same_team() {
    let app = TestApp::new().await;
    let t = boss(&app).await;
    let (s, seat) = app
        .call(
            "POST",
            "/api/assignments",
            Some(&t),
            Some(json!({"person_id": ANA, "team_id": 1, "role_title": "Export"})),
        )
        .await;
    assert_eq!(s, StatusCode::CREATED, "{seat}");
    // The very same seat again is refused, in any spelling of the team id.
    for team in [json!(1), json!("1")] {
        let (s, v) = app
            .call(
                "POST",
                "/api/assignments",
                Some(&t),
                Some(json!({"person_id": ANA, "team_id": team, "role_title": "  Export "})),
            )
            .await;
        assert_eq!(s, StatusCode::CONFLICT, "{v}");
        assert_eq!(
            v["error"],
            "That person already has this role in this team."
        );
    }
    let seat_id = seat["id"].as_str().unwrap();
    app.call(
        "PUT",
        &format!("/api/assignments/{seat_id}/definitions"),
        Some(&t),
        Some(json!({"metrics": [{"label": "Boxes"}], "kpis": [{"text": "Fast"}]})),
    )
    .await;
    let (_, cat) = app.call("GET", "/api/catalog", Some(&t), None).await;
    let boxes = cat["assignments"]
        .as_array()
        .unwrap()
        .iter()
        .find(|a| a["id"] == seat_id)
        .unwrap()["metrics"][0]["id"]
        .clone();
    let fast = cat["assignments"]
        .as_array()
        .unwrap()
        .iter()
        .find(|a| a["id"] == seat_id)
        .unwrap()["kpis"][0]["id"]
        .clone();
    let p = app.ensure_period(&t, "2026-02-01").await;
    let ana = app.token_for(ANA, false);
    let (s, v) = app.put_report(&ana, &p, A_ANA, ana_report()).await;
    assert_eq!(s, StatusCode::OK, "{v}");
    let values: Vec<Value> = (0..3)
        .map(|o| json!({"metric_def_id": boxes, "month_offset": o, "value": 4}))
        .collect();
    let second = json!({
        "reporter": {"name": "Ana Rakoto", "country": "Tana", "role": "Export"},
        "values": values,
        "kpis": [{"kpi_def_id": fast, "status": "met"}],
        "notes": [],
    });
    let (s, v) = app.put_report(&ana, &p, seat_id, second).await;
    assert_eq!(s, StatusCode::OK, "{v}");
    assert_eq!(app.count("report").await, 2);
    // One report cannot be sent for the other seat.
    let (s, v) = app.put_report(&ana, &p, seat_id, ana_report()).await;
    assert_eq!(s, StatusCode::BAD_REQUEST, "{v}");
    let sm = summary(&app, &t, &p).await;
    let mine: Vec<&Value> = sm["people"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|x| x["name"] == "Ana Rakoto")
        .collect();
    assert_eq!(mine.len(), 2);
    assert!(mine.iter().all(|x| x["submitted"] == true));
    let d = deck(&app, &t, &p).await;
    assert_eq!(d["included_count"], 2);
    // Each seat has its own report words, and both slides are kept apart.
    let roles: Vec<&str> = d["items"]
        .as_array()
        .unwrap()
        .iter()
        .map(|i| i["snapshot"]["role"].as_str().unwrap())
        .collect();
    assert_eq!(roles, vec!["Import", "Export"]);
}

#[tokio::test]
async fn a_seat_that_is_switched_off_after_its_report_was_sent() {
    let app = TestApp::new().await;
    let t = boss(&app).await;
    let ana = app.token_for(ANA, false);
    let p = app.ensure_period(&t, "2026-02-01").await;
    app.put_report(&ana, &p, A_ANA, ana_report()).await;
    app.put_report(&ana, &p, A_ANA, ana_report()).await;
    app.put_report(&t, &p, A_BEN, ben_report()).await;
    let before = summary(&app, &t, &p).await;
    assert_eq!(
        (before["expected"].as_i64(), before["submitted"].as_i64()),
        (Some(3), Some(2))
    );

    let (s, _) = app
        .call(
            "PATCH",
            &format!("/api/assignments/{A_ANA}"),
            Some(&t),
            Some(json!({"active": false})),
        )
        .await;
    assert_eq!(s, StatusCode::OK);
    // The report stays and can be read by its owner and the manager.
    let (s, r) = app
        .call(
            "GET",
            &format!("/api/periods/{p}/reports/{A_ANA}"),
            Some(&ana),
            None,
        )
        .await;
    assert_eq!(
        (s, r["status"].clone()),
        (StatusCode::OK, json!("submitted"))
    );
    // Nobody can send a new version for a switched-off seat: plain 404.
    let (s, v) = app.put_report(&ana, &p, A_ANA, ana_report()).await;
    assert_eq!(s, StatusCode::NOT_FOUND, "{v}");
    assert_eq!(v["error"], "That seat does not exist.");
    // The summary no longer expects the seat but still counts what was sent (README: old reports
    // still count), and the person still shows because a report exists.
    let after = summary(&app, &t, &p).await;
    assert_eq!(after["expected"], 2);
    assert_eq!(after["submitted"], 2);
    assert!(after["people"]
        .as_array()
        .unwrap()
        .iter()
        .any(|x| x["assignment_id"] == A_ANA && x["submitted"] == true));
    // The deck is for active seats only: expected 2, one slide (Ben) plus none for Ana.
    let d = deck(&app, &t, &p).await;
    assert_eq!(
        (d["expected_count"].as_i64(), d["included_count"].as_i64()),
        (Some(2), Some(1))
    );
    // Switch it on again and its report is back in the deck, untouched.
    app.call(
        "PATCH",
        &format!("/api/assignments/{A_ANA}"),
        Some(&t),
        Some(json!({"active": true})),
    )
    .await;
    let d = deck(&app, &t, &p).await;
    assert_eq!(d["included_count"], 2);
}

#[tokio::test]
async fn a_person_who_is_switched_off_is_not_expected_to_report() {
    let app = TestApp::new().await;
    let t = boss(&app).await;
    let p = app.ensure_period(&t, "2026-02-01").await;
    let (s, v) = app
        .call(
            "PATCH",
            &format!("/api/persons/{BEN}"),
            Some(&t),
            Some(json!({"active": false})),
        )
        .await;
    assert_eq!(s, StatusCode::OK, "{v}");
    // Ben has an active seat but cannot sign in, so he cannot be missing from the meeting.
    let sm = summary(&app, &t, &p).await;
    assert_eq!(sm["expected"], 2, "{sm}");
    assert!(sm["people"]
        .as_array()
        .unwrap()
        .iter()
        .all(|x| x["name"] != "Ben Rabe"));
    let d = deck(&app, &t, &p).await;
    assert_eq!(d["expected_count"], 2);
    // Switched on again: expected again.
    app.call(
        "PATCH",
        &format!("/api/persons/{BEN}"),
        Some(&t),
        Some(json!({"active": true})),
    )
    .await;
    let sm = summary(&app, &t, &p).await;
    assert_eq!(sm["expected"], 3);
}
