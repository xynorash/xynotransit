//! Things that happen at the same moment: double clicks, two managers, many senders.

mod common;

use axum::http::StatusCode;
use common::*;
use futures_util::future::join_all;
use serde_json::{json, Value};

fn report_with(files: [i64; 3], calls: [i64; 3], comment: &str, note: &str) -> Value {
    let mut r = ana_report();
    r["values"] = json!([
        {"metric_def_id": M_FILES, "month_offset": 0, "value": files[0]},
        {"metric_def_id": M_FILES, "month_offset": 1, "value": files[1]},
        {"metric_def_id": M_FILES, "month_offset": 2, "value": files[2]},
        {"metric_def_id": M_CALLS, "month_offset": 0, "value": calls[0]},
        {"metric_def_id": M_CALLS, "month_offset": 1, "value": calls[1]},
        {"metric_def_id": M_CALLS, "month_offset": 2, "value": calls[2]},
    ]);
    r["kpis"][1]["comment"] = json!(comment);
    r["notes"] = json!([{"kind": "well", "position": 1, "text": note}]);
    r
}

#[tokio::test]
async fn the_same_report_sent_many_times_at_once_leaves_exactly_one_consistent_row() {
    let app = TestApp::new().await;
    let cora = app.login("cora@example.org").await;
    let ana = app.token_for(ANA, false);
    let p = app.ensure_period(&cora, "2026-02-01").await;
    let bodies: Vec<Value> = (0..16)
        .map(|i| {
            report_with(
                [i, i + 100, i + 200],
                [i * 2, i * 3, i * 4],
                &format!("version {i}"),
                &format!("note {i}"),
            )
        })
        .collect();
    let answers = join_all(
        bodies
            .iter()
            .map(|b| app.put_report(&ana, &p, A_ANA, b.clone())),
    )
    .await;
    for (s, v) in &answers {
        assert_eq!(*s, StatusCode::OK, "{v}");
    }
    assert_eq!(app.count("report").await, 1);
    assert_eq!(app.count("report_metric_value").await, 6);
    assert_eq!(app.count("report_kpi_result").await, 2);
    assert_eq!(app.count("report_note").await, 1);
    // The stored report is exactly one of the versions, whole: last write wins, never a mix.
    let (_, stored) = app
        .call(
            "GET",
            &format!("/api/periods/{p}/reports/{A_ANA}"),
            Some(&ana),
            None,
        )
        .await;
    assert_eq!(stored["status"], "submitted");
    let note = stored["notes"][0]["text"].as_str().unwrap();
    let i: i64 = note.strip_prefix("note ").unwrap().parse().unwrap();
    let file0 = stored["values"]
        .as_array()
        .unwrap()
        .iter()
        .find(|v| v["metric_def_id"] == M_FILES && v["month_offset"] == 0)
        .unwrap()["value"]
        .as_i64()
        .unwrap();
    assert_eq!(file0, i);
    let calls2 = stored["values"]
        .as_array()
        .unwrap()
        .iter()
        .find(|v| v["metric_def_id"] == M_CALLS && v["month_offset"] == 2)
        .unwrap()["value"]
        .as_i64()
        .unwrap();
    assert_eq!(calls2, i * 4);
    let comment = stored["kpis"]
        .as_array()
        .unwrap()
        .iter()
        .find(|k| k["kpi_def_id"] == K_NOERR)
        .unwrap()["comment"]
        .as_str()
        .unwrap()
        .to_string();
    assert_eq!(comment, format!("version {i}"));
    // The answer each caller got was the report it sent.
    for (b, (_, v)) in bodies.iter().zip(&answers) {
        assert_eq!(v["notes"][0]["text"], b["notes"][0]["text"]);
    }
}

#[tokio::test]
async fn many_people_sending_in_the_same_period_while_a_deck_is_made() {
    let app = TestApp::new().await;
    let cora = app.token_for(CORA, true);
    let p = app.ensure_period(&cora, "2026-02-01").await;
    let (ana, ben) = (app.token_for(ANA, false), app.token_for(BEN, false));
    let sends = vec![
        app.put_report(&ana, &p, A_ANA, ana_report()),
        app.put_report(&ben, &p, A_BEN, ben_report()),
        app.put_report(&cora, &p, A_CORA, cora_report()),
        app.put_report(&ana, &p, A_ANA, ana_report()),
    ];
    let deck_uri = format!("/api/periods/{p}/deck");
    let decks = (0..4).map(|_| app.call("POST", &deck_uri, Some(&cora), None));
    let (sent, made) = futures_util::future::join(join_all(sends), join_all(decks)).await;
    for (s, v) in sent {
        assert_eq!(s, StatusCode::OK, "{v}");
    }
    for (s, v) in &made {
        assert_eq!(*s, StatusCode::CREATED, "{v}");
        // Every deck is whole: its items match its own count.
        assert_eq!(
            v["items"].as_array().unwrap().len() as i64,
            v["included_count"].as_i64().unwrap()
        );
    }
    assert_eq!(app.count("report").await, 3);
    assert_eq!(app.count("deck_run").await, 4);
    // A deck made after everything is in has all three slides.
    let (_, d) = app
        .call("POST", &format!("/api/periods/{p}/deck"), Some(&cora), None)
        .await;
    assert_eq!(d["included_count"], 3);
}

#[tokio::test]
async fn parallel_definition_edits_keep_the_seat_consistent() {
    let app = TestApp::new().await;
    let cora = app.token_for(CORA, true);
    let sets: Vec<Value> = (0..12)
        .map(|i| {
            let metrics: Vec<Value> = (0..(i % 5 + 1))
                .map(|k| json!({"label": format!("Count {i}-{k}")}))
                .collect();
            let kpis: Vec<Value> = (0..(i % 4))
                .map(|k| json!({"text": format!("Target {i}-{k}")}))
                .collect();
            json!({"metrics": metrics, "kpis": kpis})
        })
        .collect();
    let uri = format!("/api/assignments/{A_ANA}/definitions");
    let answers = join_all(
        sets.iter()
            .map(|b| app.call("PUT", &uri, Some(&cora), Some(b.clone()))),
    )
    .await;
    for (s, v) in &answers {
        assert_eq!(*s, StatusCode::OK, "{v}");
    }
    // Live counts: series 0..n-1 exactly once each, names unique ignoring case.
    let live: Vec<(i16, String)> = sqlx::query_as(
        "select series, label from metric_def where assignment_id = $1 and retired_at is null order by series",
    )
    .bind(A_ANA.parse::<uuid::Uuid>().unwrap())
    .fetch_all(&app.state.pool)
    .await
    .unwrap();
    for (pos, (series, _)) in live.iter().enumerate() {
        assert_eq!(*series as usize, pos, "{live:?}");
    }
    // The winner is one whole edit, not a blend of two.
    let winner = sets
        .iter()
        .position(|s| {
            s["metrics"]
                .as_array()
                .unwrap()
                .iter()
                .map(|m| m["label"].as_str().unwrap().to_string())
                .collect::<Vec<_>>()
                == live.iter().map(|l| l.1.clone()).collect::<Vec<_>>()
        })
        .expect("the live counts are exactly one of the edits");
    let kpis: Vec<(String,)> = sqlx::query_as(
        "select text from kpi_def where assignment_id = $1 and retired_at is null order by sort",
    )
    .bind(A_ANA.parse::<uuid::Uuid>().unwrap())
    .fetch_all(&app.state.pool)
    .await
    .unwrap();
    let want: Vec<String> = sets[winner]["kpis"]
        .as_array()
        .unwrap()
        .iter()
        .map(|k| k["text"].as_str().unwrap().to_string())
        .collect();
    assert_eq!(kpis.into_iter().map(|k| k.0).collect::<Vec<_>>(), want);
}

#[tokio::test]
async fn double_click_on_the_magic_link_signs_in_once() {
    let app = TestApp::new().await;
    app.call(
        "POST",
        "/api/auth/magic-link",
        None,
        Some(json!({"email": "ana@example.org"})),
    )
    .await;
    let link = app.state.mailer.sent()[0].link.clone();
    let token = link.split("token=").nth(1).unwrap().to_string();
    let answers = join_all((0..8).map(|_| {
        app.call(
            "POST",
            "/api/auth/verify",
            None,
            Some(json!({"token": token})),
        )
    }))
    .await;
    let ok = answers.iter().filter(|(s, _)| *s == StatusCode::OK).count();
    let refused = answers
        .iter()
        .filter(|(s, _)| *s == StatusCode::UNAUTHORIZED)
        .count();
    assert_eq!((ok, refused), (1, 7), "{answers:?}");
    for (s, v) in &answers {
        if *s == StatusCode::UNAUTHORIZED {
            assert_eq!(
                v["error"],
                "This link has expired or was already used. Ask for a new one."
            );
        }
    }
}

#[tokio::test]
async fn the_sign_in_limit_holds_under_parallel_requests() {
    let app = TestApp::new().await;
    let answers = join_all((0..14).map(|i| {
        let email = if i % 2 == 0 {
            "ana@example.org"
        } else {
            "ANA@Example.org "
        };
        app.call(
            "POST",
            "/api/auth/magic-link",
            None,
            Some(json!({"email": email})),
        )
    }))
    .await;
    let accepted = answers
        .iter()
        .filter(|(s, _)| *s == StatusCode::ACCEPTED)
        .count();
    let limited = answers
        .iter()
        .filter(|(s, _)| *s == StatusCode::TOO_MANY_REQUESTS)
        .count();
    assert_eq!((accepted, limited), (5, 9));
    assert_eq!(app.state.mailer.sent().len(), 5);
}

#[tokio::test]
async fn parallel_catalog_edits_never_double_up() {
    let app = TestApp::new().await;
    let cora = app.token_for(CORA, true);

    // The same team name from many clicks: one wins.
    let answers = join_all((0..10).map(|i| {
        let name = if i % 2 == 0 { "Mahajanga" } else { "MAHAJANGA" };
        app.call(
            "POST",
            "/api/teams",
            Some(&cora),
            Some(json!({"name": name})),
        )
    }))
    .await;
    assert_eq!(
        answers
            .iter()
            .filter(|(s, _)| *s == StatusCode::CREATED)
            .count(),
        1
    );
    assert_eq!(
        answers
            .iter()
            .filter(|(s, _)| *s == StatusCode::CONFLICT)
            .count(),
        9
    );

    // The same person email.
    let answers = join_all((0..10).map(|i| {
        let email = if i % 2 == 0 {
            "new@example.org"
        } else {
            "New@Example.org"
        };
        app.call(
            "POST",
            "/api/persons",
            Some(&cora),
            Some(json!({"full_name": "New One", "email": email, "app_role": "contributor"})),
        )
    }))
    .await;
    assert_eq!(
        answers
            .iter()
            .filter(|(s, _)| *s == StatusCode::CREATED)
            .count(),
        1
    );

    // The same seat.
    let answers = join_all((0..10).map(|_| {
        app.call(
            "POST",
            "/api/assignments",
            Some(&cora),
            Some(json!({"person_id": BEN, "team_id": 2, "role_title": "Double seat"})),
        )
    }))
    .await;
    assert_eq!(
        answers
            .iter()
            .filter(|(s, _)| *s == StatusCode::CREATED)
            .count(),
        1
    );
    for (s, v) in &answers {
        assert!(
            *s == StatusCode::CREATED || *s == StatusCode::CONFLICT,
            "{s} {v}"
        );
    }

    // Two managers each demote the other at the same moment: one stays.
    app.sql("update person set app_role = 'controller' where id = '00000000-0000-0000-0000-0000000000a1'").await;
    let ana = app.token_for(ANA, true);
    let (uri_cora, uri_ana) = (
        format!("/api/persons/{CORA}"),
        format!("/api/persons/{ANA}"),
    );
    let (a, b) = (
        app.call(
            "PATCH",
            &uri_cora,
            Some(&ana),
            Some(json!({"app_role": "contributor"})),
        ),
        app.call(
            "PATCH",
            &uri_ana,
            Some(&cora),
            Some(json!({"app_role": "contributor"})),
        ),
    );
    let (a, b) = futures_util::future::join(a, b).await;
    assert!(
        (a.0 == StatusCode::OK) != (b.0 == StatusCode::OK),
        "exactly one demotion may pass: {} {}",
        a.0,
        b.0
    );
    assert_eq!(
        app.scalar("select count(*) from person where active and app_role = 'controller'")
            .await,
        1
    );
}

#[tokio::test]
async fn deck_texts_saved_at_once_leave_one_whole_row() {
    let app = TestApp::new().await;
    let cora = app.token_for(CORA, true);
    let p = app.ensure_period(&cora, "2026-02-01").await;
    let uri = format!("/api/periods/{p}/deck-text");
    let answers = join_all((0..10).map(|i| {
        app.call(
            "PUT",
            &uri,
            Some(&cora),
            Some(json!({"settings": {"title": format!("Title {i}"), "subtitle": format!("Sub {i}, {{period}}")}})),
        )
    }))
    .await;
    for (s, v) in &answers {
        assert_eq!(*s, StatusCode::OK, "{v}");
    }
    assert_eq!(app.count("deck_text").await, 1);
    let (_, v) = app
        .call(
            "GET",
            &format!("/api/periods/{p}/deck-text"),
            Some(&cora),
            None,
        )
        .await;
    let title = v["settings"]["title"].as_str().unwrap();
    let i = title.strip_prefix("Title ").unwrap();
    assert_eq!(v["settings"]["subtitle"], format!("Sub {i}, {{period}}"));
}
