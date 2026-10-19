//! Speed with a big organisation: 300 active seats, 24 periods, 8 counts each, every report sent.
//! Every call a manager's page makes must answer well under 300 ms. The numbers are printed
//! (run with --nocapture; `cargo test --release --test perf -- --nocapture` for the real ones).

mod common;

use std::time::{Duration, Instant};

use common::*;

const SEATS: i64 = 300;
const PERIODS: i64 = 24;
const COUNTS: i64 = 8;
/// The promise is 300 ms for the real (release) build. A debug build is several times slower and
/// shares the machine with the other tests, so it only has to stay within five times that.
pub const BUDGET_MS: u128 = if cfg!(debug_assertions) { 1500 } else { 300 };

pub async fn seed(app: &TestApp) {
    app.wipe().await;
    sqlx::raw_sql(include_str!("../../xynotransit-db/scripts/seed-perf.sql"))
        .execute(&app.state.pool)
        .await
        .unwrap();
}
struct Timing {
    what: &'static str,
    runs: Vec<Duration>,
}

async fn time<F, Fut>(what: &'static str, n: usize, mut f: F) -> Timing
where
    F: FnMut() -> Fut,
    Fut: std::future::Future<Output = ()>,
{
    f().await; // warm up: plans, caches
    let mut runs = Vec::new();
    for _ in 0..n {
        let t = Instant::now();
        f().await;
        runs.push(t.elapsed());
    }
    Timing { what, runs }
}

#[tokio::test]
async fn a_big_organisation_stays_fast() {
    let app = TestApp::empty().await;
    let seeding = Instant::now();
    seed(&app).await;
    eprintln!(
        "seeded {SEATS} seats x {PERIODS} periods x {COUNTS} counts in {:?} ({} values)",
        seeding.elapsed(),
        app.count("report_metric_value").await
    );
    let cora = app.token_for("00000000-0000-0000-0001-000000000001", true);
    let last = "00000000-0000-0000-0005-000000000024";
    let seat = "00000000-0000-0000-0002-000000000007";
    let owner = app.token_for("00000000-0000-0000-0001-000000000007", false);

    let ok = |s: axum::http::StatusCode, what: &str| assert!(s.is_success(), "{what}: {s}");
    let mut t = Vec::new();
    t.push(
        time("GET reports of a period (300 reports)", 7, || async {
            let (s, _, b) = app
                .send(
                    "GET",
                    &format!("/api/periods/{last}/reports"),
                    Some(&cora),
                    None,
                    vec![],
                )
                .await;
            ok(s, "reports");
            assert!(b.len() > 100_000);
        })
        .await,
    );
    t.push(
        time("GET summary, trend 24", 7, || async {
            let (s, _, _) = app
                .send(
                    "GET",
                    &format!("/api/summary?period_id={last}&trend=24"),
                    Some(&cora),
                    None,
                    vec![],
                )
                .await;
            ok(s, "summary");
        })
        .await,
    );
    t.push(
        time("GET summary, trend 6", 7, || async {
            let (s, _, _) = app
                .send(
                    "GET",
                    &format!("/api/summary?period_id={last}"),
                    Some(&cora),
                    None,
                    vec![],
                )
                .await;
            ok(s, "summary6");
        })
        .await,
    );
    t.push(
        time("GET catalog (manager, all seats)", 7, || async {
            let (s, _, _) = app
                .send(
                    "GET",
                    "/api/catalog?include_inactive=true",
                    Some(&cora),
                    None,
                    vec![],
                )
                .await;
            ok(s, "catalog");
        })
        .await,
    );
    t.push(
        time("GET catalog (employee)", 7, || async {
            let (s, _, _) = app
                .send("GET", "/api/catalog", Some(&owner), None, vec![])
                .await;
            ok(s, "catalog employee");
        })
        .await,
    );
    t.push(
        time("POST deck (300 slides)", 5, || async {
            let (s, _, b) = app
                .send(
                    "POST",
                    &format!("/api/periods/{last}/deck"),
                    Some(&cora),
                    None,
                    vec![],
                )
                .await;
            ok(s, "deck");
            assert!(b.len() > 300_000);
        })
        .await,
    );
    t.push(
        time("GET latest deck (300 slides)", 7, || async {
            let (s, _, _) = app
                .send(
                    "GET",
                    &format!("/api/periods/{last}/deck"),
                    Some(&cora),
                    None,
                    vec![],
                )
                .await;
            ok(s, "latest deck");
        })
        .await,
    );
    t.push(
        time("GET one report", 7, || async {
            let (s, _, _) = app
                .send(
                    "GET",
                    &format!("/api/periods/{last}/reports/{seat}"),
                    Some(&owner),
                    None,
                    vec![],
                )
                .await;
            ok(s, "one report");
        })
        .await,
    );
    // Send (replace) one report of an employee: 8 counts x 3 months and 4 targets.
    let (_, _, cat) = app
        .send("GET", "/api/catalog", Some(&owner), None, vec![])
        .await;
    let cat: serde_json::Value = serde_json::from_slice(&cat).unwrap();
    let a = cat["assignments"]
        .as_array()
        .unwrap()
        .iter()
        .find(|a| a["id"] == seat)
        .unwrap()
        .clone();
    let values: Vec<_> = a["metrics"].as_array().unwrap().iter().flat_map(|m| {
        (0..3).map(move |o| serde_json::json!({"metric_def_id": m["id"], "month_offset": o, "value": 10 + o}))
    }).collect();
    let kpis: Vec<_> = a["kpis"]
        .as_array()
        .unwrap()
        .iter()
        .map(|k| serde_json::json!({"kpi_def_id": k["id"], "status": "met"}))
        .collect();
    let body = serde_json::to_vec(&serde_json::json!({
        "reporter": {"name": "P", "country": "C", "role": "R"}, "values": values, "kpis": kpis,
        "notes": [{"kind": "well", "position": 1, "text": "ok"}],
    }))
    .unwrap();
    t.push(
        time("PUT one report", 7, || async {
            let (s, _, b) = app
                .send(
                    "PUT",
                    &format!("/api/periods/{last}/reports/{seat}"),
                    Some(&owner),
                    Some("application/json"),
                    body.clone(),
                )
                .await;
            assert!(s.is_success(), "{}", String::from_utf8_lossy(&b));
        })
        .await,
    );

    eprintln!("\n{:<44} {:>8} {:>8}", "call", "median", "max");
    let mut slow = Vec::new();
    for x in &mut t {
        x.runs.sort();
        let (med, max) = (x.runs[x.runs.len() / 2], *x.runs.last().unwrap());
        eprintln!(
            "{:<44} {:>6} ms {:>6} ms",
            x.what,
            med.as_millis(),
            max.as_millis()
        );
        if max.as_millis() > BUDGET_MS {
            slow.push(x.what);
        }
    }
    assert!(slow.is_empty(), "over {BUDGET_MS} ms: {slow:?}");
}
