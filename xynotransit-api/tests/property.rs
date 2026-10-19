//! Property tests: random catalogs, reports and decks, the API compared with brute force loops.
//!
//! PROPTEST_CASES (default 300) and PROPTEST_SEED (default 1) change the run. A failing case prints
//! its own seed, so it can be replayed with PROPTEST_SEED=<seed> PROPTEST_CASES=1.

mod common;

use std::time::Instant;

use common::{model::Dataset, *};
use serde_json::Value;

const CORA: &str = "00000000-0000-0000-0000-0000000000a3";

fn env_u64(k: &str, d: u64) -> u64 {
    std::env::var(k)
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(d)
}

async fn load(app: &TestApp, d: &Dataset) {
    app.wipe().await;
    app.sql(&format!(
        "insert into person (id, full_name, email, app_role) values ('{CORA}', 'Cora Boss', 'cora@example.org', 'controller')"
    ))
    .await;
    sqlx::raw_sql(&d.insert_sql())
        .execute(&app.state.pool)
        .await
        .unwrap_or_else(|e| panic!("dataset does not insert: {e}"));
}

#[tokio::test]
async fn summary_matches_brute_force_for_random_datasets() {
    let app = TestApp::empty().await;
    let t = app.token_for(CORA, true);
    let cases = env_u64("PROPTEST_CASES", 300);
    let base = env_u64("PROPTEST_SEED", 1);
    let start = Instant::now();
    let mut compared = 0;
    for case in 0..cases {
        let seed = base * 1_000_003 + case;
        let d = Dataset::generate(seed);
        load(&app, &d).await;
        for _ in 0..3 {
            let shown = (seed as usize * 7 + compared) % d.periods.len();
            let trend = [1usize, 2, 6, 24][(seed as usize + compared) % 4];
            let (s, got) = app
                .call(
                    "GET",
                    &format!(
                        "/api/summary?period_id={}&trend={trend}",
                        d.periods[shown].id
                    ),
                    Some(&t),
                    None,
                )
                .await;
            assert_eq!(s, 200, "seed {seed}: {got}");
            let want = d.summary(shown, trend);
            assert_eq!(
                got,
                want,
                "seed {seed} period {shown} trend {trend}\nGOT  {}\nWANT {}",
                serde_json::to_string_pretty(&got).unwrap(),
                serde_json::to_string_pretty(&want).unwrap()
            );
            compared += 1;
        }
    }
    eprintln!("{compared} summaries compared in {:?}", start.elapsed());
}

#[tokio::test]
async fn decks_match_brute_force_for_random_datasets() {
    let app = TestApp::empty().await;
    let t = app.token_for(CORA, true);
    let cases = env_u64("PROPTEST_CASES", 300);
    let base = env_u64("PROPTEST_SEED", 1) + 77;
    let mut slides_seen = 0;
    for case in 0..cases {
        let seed = base * 1_000_003 + case;
        let d = Dataset::generate(seed);
        load(&app, &d).await;
        let p = seed as usize % d.periods.len();
        let (s, got) = app
            .call(
                "POST",
                &format!("/api/periods/{}/deck", d.periods[p].id),
                Some(&t),
                None,
            )
            .await;
        assert_eq!(s, 201, "seed {seed}: {got}");
        let (expected, want) = d.deck(p);
        assert_eq!(got["expected_count"], expected, "seed {seed}");
        assert_eq!(got["included_count"], want.len(), "seed {seed}");
        let items = got["items"].as_array().unwrap();
        assert_eq!(items.len(), want.len(), "seed {seed}");
        for (i, (item, (rid, snap))) in items.iter().zip(&want).enumerate() {
            assert_eq!(item["report_id"], rid.to_string(), "seed {seed} slide {i}");
            assert_eq!(item["sort"], i as i64 + 1);
            assert_eq!(
                &item["snapshot"], snap,
                "seed {seed} slide {i}\nGOT  {}\nWANT {}",
                item["snapshot"], snap
            );
        }
        slides_seen += items.len();
        // Reading it back gives the same frozen deck.
        let (_, latest) = app
            .call(
                "GET",
                &format!("/api/periods/{}/deck", d.periods[p].id),
                Some(&t),
                None,
            )
            .await;
        assert_eq!(latest["items"], got["items"], "seed {seed}");
    }
    eprintln!("{slides_seen} slides compared");
    assert!(slides_seen > 100, "the generator should produce slides");
}

#[tokio::test]
async fn generated_data_has_the_variety_the_properties_need() {
    // A guard against a generator that quietly stops producing the hard cases.
    let (mut mixed_case, mut retired_values, mut legacy, mut drafts, mut inactive) =
        (0, 0, 0, 0, 0);
    for seed in 0..300u64 {
        let d = Dataset::generate(seed);
        for r in &d.reports {
            legacy += r.reporter.is_none() as i32;
            drafts += !r.submitted as i32;
            retired_values += r.values.iter().any(|v| d.mdefs[v.0].retired) as i32;
        }
        inactive += d.seats.iter().any(|s| !s.active) as i32;
        mixed_case += d.mdefs.iter().any(|a| {
            d.mdefs.iter().any(|b| {
                a.seat == b.seat
                    && a.label != b.label
                    && a.label.to_lowercase() == b.label.to_lowercase()
            })
        }) as i32;
    }
    for (what, n) in [
        ("mixed case names", mixed_case),
        ("reports with retired counts", retired_values),
        ("legacy reports", legacy),
        ("drafts", drafts),
        ("inactive seats", inactive),
    ] {
        assert!(n > 20, "only {n} cases with {what}");
    }
    let _: Option<Value> = None;
}
