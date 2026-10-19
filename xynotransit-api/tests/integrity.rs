//! The database refuses bad data by itself (initdb/06-integrity.sql), whatever the API does.

mod common;

use common::*;

/// The SQLSTATE of a statement that must fail.
async fn code_of(app: &TestApp, q: &str) -> String {
    let err = sqlx::query(q)
        .execute(&app.state.pool)
        .await
        .expect_err(&format!("should have been refused: {q}"));
    err.as_database_error()
        .and_then(|d| d.code().map(|c| c.to_string()))
        .unwrap_or_default()
}

const CHECK: &str = "23514";
const UNIQUE: &str = "23505";
const RESTRICT: &str = "23001";
const FK: &str = "23503";

#[tokio::test]
async fn check_constraints_refuse_bad_rows() {
    let app = TestApp::new().await;
    let long80 = "a".repeat(81);
    let long60 = "a".repeat(61);
    let long200 = "a".repeat(201);
    let cases: Vec<(String, &str)> = vec![
        (
            "insert into person (full_name, email) values ('', 'z1@x.org')".into(),
            CHECK,
        ),
        (
            "insert into person (full_name, email) values ('  ', 'z1@x.org')".into(),
            CHECK,
        ),
        (
            format!("insert into person (full_name, email) values ('{long80}', 'z1@x.org')"),
            CHECK,
        ),
        (
            "insert into person (full_name, email) values (' Pad', 'z1@x.org')".into(),
            CHECK,
        ),
        (
            "insert into person (full_name, email) values ('Z', 'no at sign')".into(),
            CHECK,
        ),
        (
            "insert into person (full_name, email) values ('Z', 'a b@x.org')".into(),
            CHECK,
        ),
        (
            "insert into person (full_name, email) values ('Z', '@x.org')".into(),
            CHECK,
        ),
        (
            "insert into team (code, name, sort) values ('z', '', 3)".into(),
            CHECK,
        ),
        (
            format!("insert into team (code, name, sort) values ('z', '{long60}', 3)"),
            CHECK,
        ),
        (
            "insert into team (code, name, sort) values ('z', 'Z', -1)".into(),
            CHECK,
        ),
        (
            format!("update assignment set role_title = '{long80}' where code = 'ana-import'"),
            CHECK,
        ),
        (
            "update assignment set role_title = ' ' where code = 'ana-import'".into(),
            CHECK,
        ),
        (
            format!("update metric_def set label = '{long60}' where key = 'files'"),
            CHECK,
        ),
        (
            "update metric_def set label = '' where key = 'files'".into(),
            CHECK,
        ),
        (
            format!("update kpi_def set text = '{long200}' where sort = 1"),
            CHECK,
        ),
        (
            "update kpi_def set text = '   ' where sort = 1".into(),
            CHECK,
        ),
        (
            "insert into period (start_month) values ('1999-12-01')".into(),
            CHECK,
        ),
        (
            "insert into period (start_month) values ('2101-01-01')".into(),
            CHECK,
        ),
        (
            "insert into period (start_month, meeting_date) values ('2026-02-01', '1999-01-01')"
                .into(),
            CHECK,
        ),
    ];
    for (q, want) in &cases {
        assert_eq!(&code_of(&app, q).await, want, "{q}");
    }
}

#[tokio::test]
async fn report_rows_are_checked() {
    let app = TestApp::new().await;
    let t = app.login("cora@example.org").await;
    let p = app.ensure_period(&t, "2026-02-01").await;
    let (s, v) = app.put_report(&t, &p, A_ANA, ana_report()).await;
    assert_eq!(s, 200, "{v}");
    // The reporter words are all there or all missing, never blank, never padded.
    for set in [
        "reporter_name = ''",
        "reporter_name = ' x '",
        "reporter_country = null",
        "reporter_role = repeat('r', 81)",
    ] {
        let q = format!("update report set {set} where assignment_id = '{A_ANA}'");
        assert_eq!(code_of(&app, &q).await, CHECK, "{set}");
    }
    app.sql(&format!(
        "update report set reporter_name = null, reporter_country = null, reporter_role = null
         where assignment_id = '{A_ANA}'"
    ))
    .await;
    for q in [
        "update report_metric_value set value = -1".to_string(),
        "update report_metric_value set value = 1000000001".to_string(),
        "update report_kpi_result set comment = '   '".to_string(),
        "update report_kpi_result set comment = repeat('c', 201)".to_string(),
        "update report_note set text = '  '".to_string(),
        "update report_note set text = repeat('n', 71)".to_string(),
    ] {
        assert_eq!(code_of(&app, &q).await, CHECK, "{q}");
    }
    // The boundaries themselves are fine.
    app.sql(
        "update report_metric_value set value = 1000000000 where month_offset = 0 and value = 10",
    )
    .await;
    app.sql("update report_metric_value set value = 0 where month_offset = 2 and value = 12")
        .await;
}

#[tokio::test]
async fn names_are_unique_ignoring_case() {
    let app = TestApp::new().await;
    assert_eq!(
        code_of(
            &app,
            "insert into person (full_name, email) values ('Twin', 'ANA@Example.org')"
        )
        .await,
        UNIQUE
    );
    assert_eq!(
        code_of(
            &app,
            "insert into team (code, name, sort) values ('tana2', 'TANA', 9)"
        )
        .await,
        UNIQUE
    );
    // A second live count with the same name (any case) on one seat is refused,
    // a retired one does not count, and another seat may reuse the name.
    assert_eq!(
        code_of(&app, &format!(
            "insert into metric_def (assignment_id, key, label, series) values ('{A_ANA}', 'f2', 'FILES', 5)"
        )).await,
        UNIQUE
    );
    app.sql(&format!(
        "insert into metric_def (assignment_id, key, label, series, retired_at) values ('{A_ANA}', 'f3', 'files', 6, now())"
    ))
    .await;
    app.sql(&format!(
        "insert into metric_def (assignment_id, key, label, series) values ('{A_BEN}', 'files', 'Files', 5)"
    ))
    .await;
}

#[tokio::test]
async fn generated_decks_are_frozen() {
    let app = TestApp::new().await;
    let t = app.login("cora@example.org").await;
    let p = app.ensure_period(&t, "2026-02-01").await;
    app.put_report(&t, &p, A_ANA, ana_report()).await;
    app.put_report(&t, &p, A_BEN, ben_report()).await;
    let (s, deck) = app
        .call("POST", &format!("/api/periods/{p}/deck"), Some(&t), None)
        .await;
    assert_eq!(s, 201, "{deck}");
    assert_eq!(app.count("deck_run_item").await, 2);

    for q in [
        "update deck_run set expected_count = 99",
        "update deck_run_item set sort = 9",
        "update deck_run_item set snapshot = '{}'::jsonb",
        "delete from deck_run",
        "delete from deck_run_item",
        "truncate deck_run cascade",
        "truncate deck_run_item",
    ] {
        assert_eq!(code_of(&app, q).await, RESTRICT, "{q}");
    }
    // A report or period with a deck cannot disappear either.
    assert_eq!(code_of(&app, "delete from report").await, FK);
    assert_eq!(code_of(&app, "delete from period").await, FK);
    assert_eq!(app.count("deck_run_item").await, 2);

    // Even the switch never allows an edit.
    let mut tx = app.state.pool.begin().await.unwrap();
    sqlx::query("set local xt.allow_deck_delete = 'on'")
        .execute(&mut *tx)
        .await
        .unwrap();
    let e = sqlx::query("update deck_run set expected_count = 99")
        .execute(&mut *tx)
        .await;
    assert!(e.is_err());
    drop(tx);

    // The deliberate way to remove a deck: the switch, and the items follow by cascade.
    let mut tx = app.state.pool.begin().await.unwrap();
    sqlx::query("set local xt.allow_deck_delete = 'on'")
        .execute(&mut *tx)
        .await
        .unwrap();
    sqlx::query("delete from deck_run")
        .execute(&mut *tx)
        .await
        .unwrap();
    tx.commit().await.unwrap();
    assert_eq!(app.count("deck_run").await, 0);
    assert_eq!(app.count("deck_run_item").await, 0);
    // And a new deck can be made again.
    let (s, _) = app
        .call("POST", &format!("/api/periods/{p}/deck"), Some(&t), None)
        .await;
    assert_eq!(s, 201);
}

#[tokio::test]
async fn updated_at_moves_only_when_something_changed() {
    let app = TestApp::new().await;
    let age = |q: &'static str| {
        let app = &app;
        async move { app.scalar(q).await }
    };
    app.sql("update person set updated_at = now() - interval '1 day'")
        .await;
    let q = "select count(*) from person where updated_at < now() - interval '1 hour'";
    assert_eq!(age(q).await, 4);
    // Same values: nothing moves.
    app.sql("update person set full_name = full_name").await;
    assert_eq!(age(q).await, 4);
    // A real change moves that row only.
    app.sql("update person set full_name = 'Ana R.' where email = 'ana@example.org'")
        .await;
    assert_eq!(age(q).await, 3);
    for table in ["team", "assignment", "metric_def", "kpi_def", "period"] {
        let col = match table {
            "team" => "name = 'Renamed'",
            "assignment" => "role_title = 'Renamed'",
            "metric_def" => "label = 'Renamed'",
            "kpi_def" => "text = 'Renamed'",
            _ => "meeting_date = '2026-03-01'",
        };
        if table == "period" {
            app.sql("insert into period (start_month) values ('2026-02-01')")
                .await;
        }
        app.sql(&format!(
            "update {table} set updated_at = now() - interval '1 day'"
        ))
        .await;
        let moved =
            format!("select count(*) from {table} where updated_at > now() - interval '1 hour'");
        assert_eq!(app.scalar(&moved).await, 0, "{table}");
        app.sql(&format!(
            "update {table} set {col} where ctid = (select min(ctid) from {table})"
        ))
        .await;
        assert_eq!(app.scalar(&moved).await, 1, "{table}");
    }
}

#[tokio::test]
async fn migrations_run_twice_and_keep_old_rows_that_break_a_check() {
    let app = TestApp::empty().await;
    let initdb = concat!(env!("CARGO_MANIFEST_DIR"), "/../xynotransit-db/initdb/");
    let run = |file: &'static str| {
        let app = &app;
        async move {
            let sql = std::fs::read_to_string(format!("{initdb}{file}")).unwrap();
            sqlx::raw_sql(&sql).execute(&app.state.pool).await
        }
    };
    for f in [
        "03-dynamic.sql",
        "04-deck-text.sql",
        "05-reporter.sql",
        "06-integrity.sql",
        "07-ledger.sql",
        "08-role-title-unique.sql",
    ] {
        run(f).await.unwrap_or_else(|e| panic!("{f} twice: {e}"));
    }
    // An old database holds a row that the new rule forbids: the migration must not fail,
    // it leaves the check NOT VALID, and new rows are still checked.
    app.sql("alter table person drop constraint person_full_name_ck")
        .await;
    app.sql(&format!(
        "insert into person (full_name, email) values ('{}', 'old@x.org')",
        "n".repeat(100)
    ))
    .await;
    run("06-integrity.sql")
        .await
        .expect("migration must not fail on old data");
    assert_eq!(
        app.scalar("select count(*) from pg_constraint where conname = 'person_full_name_ck' and not convalidated").await,
        1
    );
    assert_eq!(
        code_of(
            &app,
            &format!(
                "insert into person (full_name, email) values ('{}', 'new@x.org')",
                "n".repeat(100)
            )
        )
        .await,
        CHECK
    );
    assert_eq!(app.count("person").await, 1);
}

#[tokio::test]
async fn the_ledger_lists_every_file() {
    let app = TestApp::empty().await;
    let initdb = concat!(env!("CARGO_MANIFEST_DIR"), "/../xynotransit-db/initdb/");
    let n = std::fs::read_dir(initdb)
        .unwrap()
        .filter(|e| {
            e.as_ref()
                .unwrap()
                .path()
                .extension()
                .is_some_and(|x| x == "sql")
        })
        .count() as i64;
    assert_eq!(app.count("schema_migration").await, n);
}
