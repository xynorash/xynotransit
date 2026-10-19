//! Pure helpers for month names, period labels and the deck snapshot JSON.
//! The snapshot shape is a stable contract with the slides in the app.

use chrono::{Datelike, Months, NaiveDate};
use serde_json::{json, Value};

const SHORT: [&str; 12] = [
    "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
];
const LONG: [&str; 12] = [
    "January",
    "February",
    "March",
    "April",
    "May",
    "June",
    "July",
    "August",
    "September",
    "October",
    "November",
    "December",
];

/// Month 1..12.
pub fn month_short(month: u32) -> &'static str {
    SHORT[(month as usize + 11) % 12]
}

pub fn month_long(month: u32) -> &'static str {
    LONG[(month as usize + 11) % 12]
}

/// First day of the month `offset` months after `start`.
pub fn month_at(start: NaiveDate, offset: u32) -> NaiveDate {
    start
        .checked_add_months(Months::new(offset))
        .unwrap_or(start)
}

/// "Feb to Apr 2026", or "Nov 2026 to Jan 2027" across a year end.
pub fn period_label(start: NaiveDate) -> String {
    let last = month_at(start, 2);
    if last.year() == start.year() {
        format!(
            "{} to {} {}",
            month_short(start.month()),
            month_short(last.month()),
            last.year()
        )
    } else {
        format!(
            "{} {} to {} {}",
            month_short(start.month()),
            start.year(),
            month_short(last.month()),
            last.year()
        )
    }
}

pub struct MetricIn {
    pub key: String,
    pub label: String,
    pub series: i16,
    pub values: [i64; 3],
}

pub struct SnapshotInput {
    pub assignment_code: String,
    pub name: String,
    pub role: String,
    pub team: String,
    pub start_month: NaiveDate,
    pub metrics: Vec<MetricIn>,
    /// (target text, "met" | "partly" | "missed" when answered)
    pub targets: Vec<(String, Option<String>)>,
    pub well: Vec<String>,
    pub wrong: Vec<String>,
    pub next: Vec<String>,
}

/// (name, role, team) for a slide: the reporter's own words when the report has them
/// (`reporter` is the report JSON block or null), else the catalog profile. The slide field
/// "team" carries the reporter's country.
pub fn words(reporter: &Value, profile: (&str, &str, &str)) -> (String, String, String) {
    let pick = |k: &str, fallback: &str| -> String {
        reporter[k]
            .as_str()
            .map(str::to_string)
            .unwrap_or_else(|| fallback.to_string())
    };
    (
        pick("name", profile.0),
        pick("role", profile.1),
        pick("country", profile.2),
    )
}

/// How decks group countries: case-insensitive, runs of whitespace collapsed to one space.
/// The deck shows the first spelling seen in a group. The Dart side does the grouping; this is
/// the reference for it.
pub fn country_key(s: &str) -> String {
    s.split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .to_lowercase()
}

pub fn build(i: &SnapshotInput) -> Value {
    let months: Vec<Value> = (0..3u32)
        .map(|o| {
            let d = month_at(i.start_month, o);
            json!({"offset": o, "year": d.year(), "month": d.month(), "short": month_short(d.month())})
        })
        .collect();
    json!({
        "assignmentCode": i.assignment_code,
        "name": i.name,
        "role": i.role,
        "team": i.team,
        "periodLabel": period_label(i.start_month),
        "months": months,
        "metrics": i.metrics.iter().map(|m| json!({
            "key": m.key, "label": m.label, "series": m.series, "values": m.values,
        })).collect::<Vec<_>>(),
        "targets": i.targets.iter().map(|(t, s)| json!({"text": t, "status": s})).collect::<Vec<_>>(),
        "well": i.well,
        "wrong": i.wrong,
        "next": i.next,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn d(y: i32, m: u32) -> NaiveDate {
        NaiveDate::from_ymd_opt(y, m, 1).unwrap()
    }

    #[test]
    fn month_names() {
        assert_eq!(month_short(1), "Jan");
        assert_eq!(month_short(12), "Dec");
        assert_eq!(month_long(2), "February");
        assert_eq!(month_long(9), "September");
    }

    #[test]
    fn label_same_year() {
        assert_eq!(period_label(d(2026, 2)), "Feb to Apr 2026");
        assert_eq!(period_label(d(2026, 10)), "Oct to Dec 2026");
    }

    #[test]
    fn label_across_year_end() {
        assert_eq!(period_label(d(2026, 11)), "Nov 2026 to Jan 2027");
        assert_eq!(period_label(d(2026, 12)), "Dec 2026 to Feb 2027");
    }

    fn input(start: NaiveDate) -> SnapshotInput {
        SnapshotInput {
            assignment_code: "rova".into(),
            name: "Rova R.".into(),
            role: "Import".into(),
            team: "Tana".into(),
            start_month: start,
            metrics: vec![MetricIn {
                key: "files".into(),
                label: "Files".into(),
                series: 0,
                values: [3, 0, 7],
            }],
            targets: vec![
                ("On time".into(), Some("met".into())),
                ("No errors".into(), None),
            ],
            well: vec!["a".into()],
            wrong: vec![],
            next: vec!["b".into(), "c".into()],
        }
    }

    #[test]
    fn snapshot_matches_contract() {
        let v = build(&input(d(2026, 2)));
        assert_eq!(v["assignmentCode"], "rova");
        assert_eq!(v["name"], "Rova R.");
        assert_eq!(v["role"], "Import");
        assert_eq!(v["team"], "Tana");
        assert_eq!(v["periodLabel"], "Feb to Apr 2026");
        assert_eq!(
            v["months"],
            json!([
                {"offset":0,"year":2026,"month":2,"short":"Feb"},
                {"offset":1,"year":2026,"month":3,"short":"Mar"},
                {"offset":2,"year":2026,"month":4,"short":"Apr"},
            ])
        );
        assert_eq!(
            v["metrics"],
            json!([{"key":"files","label":"Files","series":0,"values":[3,0,7]}])
        );
        assert_eq!(
            v["targets"],
            json!([{"text":"On time","status":"met"},{"text":"No errors","status":null}])
        );
        assert_eq!(v["well"], json!(["a"]));
        assert_eq!(v["wrong"], json!([]));
        assert_eq!(v["next"], json!(["b", "c"]));
    }

    #[test]
    fn snapshot_months_wrap_year() {
        let v = build(&input(d(2026, 11)));
        assert_eq!(v["periodLabel"], "Nov 2026 to Jan 2027");
        assert_eq!(
            v["months"][2],
            json!({"offset":2,"year":2027,"month":1,"short":"Jan"})
        );
    }

    #[test]
    fn words_prefer_reporter_over_profile() {
        let profile = ("Ana Rakoto", "Import", "Tana");
        let r = json!({"name": "Ana R.", "country": "Madagascar", "role": "Import lead"});
        assert_eq!(
            words(&r, profile),
            ("Ana R.".into(), "Import lead".into(), "Madagascar".into())
        );
        // Legacy report: no reporter, the profile is used.
        assert_eq!(
            words(&Value::Null, profile),
            ("Ana Rakoto".into(), "Import".into(), "Tana".into())
        );
    }

    #[test]
    fn country_key_ignores_case_and_spacing() {
        assert_eq!(country_key("  Mada  gascar "), "mada gascar");
        assert_eq!(country_key("MADAGASCAR"), country_key("madagascar"));
        assert_eq!(country_key("Côte\t d'Ivoire"), "côte d'ivoire");
        assert_ne!(country_key("Mali"), country_key("Malta"));
    }

    #[test]
    fn snapshot_with_reporter_words_uses_country_as_team() {
        let mut i = input(d(2026, 2));
        let (n, r, c) = words(
            &json!({"name": "Rova Andry", "country": "Madagascar", "role": "Lead"}),
            ("x", "y", "z"),
        );
        (i.name, i.role, i.team) = (n, r, c);
        let v = build(&i);
        assert_eq!(v["name"], "Rova Andry");
        assert_eq!(v["role"], "Lead");
        assert_eq!(v["team"], "Madagascar");
    }

    #[test]
    fn shared_fixture_matches_snapshot() {
        let raw = include_str!("../tests/fixtures/snapshot_case.json");
        let case: Value = serde_json::from_str(raw).unwrap();
        assert_eq!(build_from_case(&case), case["expected_snapshot"]);
    }

    /// Build a snapshot from the fixture's catalog, period and report, in the deck order
    /// rules: metrics by series, targets by sort, notes by position.
    fn build_from_case(case: &Value) -> Value {
        let cat = &case["catalog"];
        let a = &cat["assignment"];
        let start =
            NaiveDate::parse_from_str(case["period"]["start_month"].as_str().unwrap(), "%Y-%m-%d")
                .unwrap();
        let report = &case["report"];
        let value_of = |metric: &str, off: i64| -> i64 {
            report["values"]
                .as_array()
                .unwrap()
                .iter()
                .find(|v| v["metric_def_id"] == metric && v["month_offset"] == off)
                .map_or(0, |v| v["value"].as_i64().unwrap())
        };
        let mut metrics: Vec<&Value> = cat["metrics"].as_array().unwrap().iter().collect();
        metrics.sort_by_key(|m| m["series"].as_i64().unwrap());
        let mut kpis: Vec<&Value> = cat["kpis"].as_array().unwrap().iter().collect();
        kpis.sort_by_key(|k| k["sort"].as_i64().unwrap());
        let notes_of = |kind: &str| -> Vec<String> {
            let mut v: Vec<(i64, String)> = report["notes"]
                .as_array()
                .unwrap()
                .iter()
                .filter(|n| n["kind"] == kind)
                .map(|n| {
                    (
                        n["position"].as_i64().unwrap(),
                        n["text"].as_str().unwrap().trim().to_string(),
                    )
                })
                .collect();
            v.sort();
            v.into_iter().map(|n| n.1).collect()
        };
        let (name, role, team) = words(
            &report["reporter"],
            (
                a["person_name"].as_str().unwrap(),
                a["role_title"].as_str().unwrap(),
                a["team_name"].as_str().unwrap(),
            ),
        );
        build(&SnapshotInput {
            assignment_code: a["code"].as_str().unwrap().into(),
            name,
            role,
            team,
            start_month: start,
            metrics: metrics
                .iter()
                .map(|m| {
                    let id = m["id"].as_str().unwrap();
                    MetricIn {
                        key: m["key"].as_str().unwrap().into(),
                        label: m["label"].as_str().unwrap().into(),
                        series: m["series"].as_i64().unwrap() as i16,
                        values: [value_of(id, 0), value_of(id, 1), value_of(id, 2)],
                    }
                })
                .collect(),
            targets: kpis
                .iter()
                .map(|k| {
                    let id = k["id"].as_str().unwrap();
                    let status = report["kpis"]
                        .as_array()
                        .unwrap()
                        .iter()
                        .find(|r| r["kpi_def_id"] == id)
                        .map(|r| r["status"].as_str().unwrap().to_string());
                    (k["text"].as_str().unwrap().to_string(), status)
                })
                .collect(),
            well: notes_of("well"),
            wrong: notes_of("wrong"),
            next: notes_of("next"),
        })
    }
}
