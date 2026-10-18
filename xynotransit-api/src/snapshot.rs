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
}
