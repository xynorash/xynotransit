//! The manager's summary: pure aggregation over rows the route loads.
//! Only submitted reports are passed in. Volume is the sum of every count.

use std::collections::HashMap;

use chrono::{Datelike, NaiveDate};
use serde_json::{json, Value};
use uuid::Uuid;

use crate::snapshot::{month_at, month_short, period_label};

#[derive(Debug, Clone)]
pub struct TeamIn {
    pub id: i32,
    pub name: String,
}

#[derive(Debug, Clone)]
pub struct SeatIn {
    pub id: Uuid,
    pub name: String,
    pub role: String,
    pub team_id: i32,
    pub active: bool,
}

#[derive(Debug, Clone)]
pub struct PeriodIn {
    pub id: Uuid,
    pub start_month: NaiveDate,
}

/// A submitted report with its answered targets counted.
#[derive(Debug, Clone)]
pub struct ReportIn {
    pub period_id: Uuid,
    pub assignment_id: Uuid,
    pub met: i64,
    pub partly: i64,
    pub missed: i64,
}

/// Sum of one count (by label) in one month of one report.
#[derive(Debug, Clone)]
pub struct ValueIn {
    pub period_id: Uuid,
    pub assignment_id: Uuid,
    pub label: String,
    pub month: usize,
    pub total: i64,
}

pub struct SummaryInput {
    pub shown: PeriodIn,
    /// Oldest first, the shown period last.
    pub periods: Vec<PeriodIn>,
    /// Team sort order.
    pub teams: Vec<TeamIn>,
    /// Deck order, active and inactive.
    pub seats: Vec<SeatIn>,
    pub reports: Vec<ReportIn>,
    /// In deck order, so the first label seen is stable.
    pub values: Vec<ValueIn>,
    /// Total of every count of the submitted reports of a period, for the trend. One entry per
    /// period that has any numbers (the route loads these without the detail, which is only
    /// needed for the shown period).
    pub volumes: Vec<(Uuid, i64)>,
}

fn date(d: NaiveDate) -> String {
    d.format("%Y-%m-%d").to_string()
}

pub fn build(input: &SummaryInput) -> Value {
    let shown = input.shown.id;
    let seat_team: HashMap<Uuid, i32> = input.seats.iter().map(|s| (s.id, s.team_id)).collect();
    let active_total = input.seats.iter().filter(|s| s.active).count();

    let shown_reports: Vec<&ReportIn> = input
        .reports
        .iter()
        .filter(|r| r.period_id == shown)
        .collect();
    let shown_values: Vec<&ValueIn> = input
        .values
        .iter()
        .filter(|v| v.period_id == shown && v.month < 3)
        .collect();

    // Teams: those with active seats, or with something submitted in this period.
    let mut teams = Vec::new();
    for t in &input.teams {
        let expected = input
            .seats
            .iter()
            .filter(|s| s.team_id == t.id && s.active)
            .count();
        let reports: Vec<&&ReportIn> = shown_reports
            .iter()
            .filter(|r| seat_team.get(&r.assignment_id) == Some(&t.id))
            .collect();
        if expected == 0 && reports.is_empty() {
            continue;
        }
        let mut volume = [0i64; 3];
        for v in &shown_values {
            if seat_team.get(&v.assignment_id) == Some(&t.id) {
                volume[v.month] += v.total;
            }
        }
        teams.push(json!({
            "team_id": t.id.to_string(),
            "name": t.name,
            "expected": expected,
            "submitted": reports.len(),
            "met": reports.iter().map(|r| r.met).sum::<i64>(),
            "partly": reports.iter().map(|r| r.partly).sum::<i64>(),
            "missed": reports.iter().map(|r| r.missed).sum::<i64>(),
            "volume_by_month": volume,
        }));
    }

    // Counts grouped by lower(label) across seats, first label seen is displayed.
    struct Group {
        label: String,
        by_month: [i64; 3],
        by_team: Vec<(i32, i64)>,
    }
    let mut groups: Vec<Group> = Vec::new();
    let mut index: HashMap<String, usize> = HashMap::new();
    for v in &shown_values {
        let i = *index.entry(v.label.to_lowercase()).or_insert_with(|| {
            groups.push(Group {
                label: v.label.clone(),
                by_month: [0; 3],
                by_team: Vec::new(),
            });
            groups.len() - 1
        });
        let g = &mut groups[i];
        g.by_month[v.month] += v.total;
        if let Some(&team) = seat_team.get(&v.assignment_id) {
            match g.by_team.iter_mut().find(|(t, _)| *t == team) {
                Some(entry) => entry.1 += v.total,
                None => g.by_team.push((team, v.total)),
            }
        }
    }
    let team_name: HashMap<i32, &str> = input
        .teams
        .iter()
        .map(|t| (t.id, t.name.as_str()))
        .collect();
    let mut metrics: Vec<(i64, Value)> = groups
        .into_iter()
        .map(|mut g| {
            let total: i64 = g.by_month.iter().sum();
            g.by_team.sort_by_key(|(_, t)| std::cmp::Reverse(*t));
            let by_team: Vec<Value> = g
                .by_team
                .iter()
                .map(|(t, n)| json!({"team": team_name.get(t).copied().unwrap_or(""), "total": n}))
                .collect();
            (
                total,
                json!({"label": g.label, "total": total, "by_month": g.by_month, "by_team": by_team}),
            )
        })
        .collect();
    metrics.sort_by_key(|(total, _)| std::cmp::Reverse(*total));

    let trend: Vec<Value> = input
        .periods
        .iter()
        .map(|p| {
            let rs: Vec<&ReportIn> = input
                .reports
                .iter()
                .filter(|r| r.period_id == p.id)
                .collect();
            json!({
                "period_id": p.id.to_string(),
                "label": period_label(p.start_month),
                "start_month": date(p.start_month),
                "expected": active_total,
                "submitted": rs.len(),
                "met": rs.iter().map(|r| r.met).sum::<i64>(),
                "partly": rs.iter().map(|r| r.partly).sum::<i64>(),
                "missed": rs.iter().map(|r| r.missed).sum::<i64>(),
                "volume_total": input.volumes.iter()
                    .filter(|(period, _)| *period == p.id)
                    .map(|(_, total)| *total)
                    .sum::<i64>(),
            })
        })
        .collect();

    let team_by_id: HashMap<i32, &str> = team_name.clone();
    let people: Vec<Value> = input
        .seats
        .iter()
        .filter_map(|s| {
            let report = shown_reports.iter().find(|r| r.assignment_id == s.id);
            if !s.active && report.is_none() {
                return None;
            }
            Some(json!({
                "assignment_id": s.id.to_string(),
                "name": s.name,
                "role": s.role,
                "team": team_by_id.get(&s.team_id).copied().unwrap_or(""),
                "submitted": report.is_some(),
                "met": report.map_or(0, |r| r.met),
                "partly": report.map_or(0, |r| r.partly),
                "missed": report.map_or(0, |r| r.missed),
                "volume_total": shown_values.iter()
                    .filter(|v| v.assignment_id == s.id)
                    .map(|v| v.total)
                    .sum::<i64>(),
            }))
        })
        .collect();

    let months: Vec<Value> = (0..3)
        .map(|o| {
            let d = month_at(input.shown.start_month, o);
            json!({"offset": o, "year": d.year(), "month": d.month(), "short": month_short(d.month())})
        })
        .collect();

    json!({
        "period_id": shown.to_string(),
        "period_label": period_label(input.shown.start_month),
        "months": months,
        "expected": active_total,
        "submitted": shown_reports.len(),
        "teams": teams,
        "metrics": metrics.into_iter().map(|(_, v)| v).collect::<Vec<_>>(),
        "trend": trend,
        "people": people,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn id(n: u128) -> Uuid {
        Uuid::from_u128(n)
    }

    fn d(y: i32, m: u32) -> NaiveDate {
        NaiveDate::from_ymd_opt(y, m, 1).unwrap()
    }

    fn seat(n: u128, name: &str, team: i32, active: bool) -> SeatIn {
        SeatIn {
            id: id(n),
            name: name.into(),
            role: "Role".into(),
            team_id: team,
            active,
        }
    }

    fn val(p: u128, a: u128, label: &str, month: usize, total: i64) -> ValueIn {
        ValueIn {
            period_id: id(p),
            assignment_id: id(a),
            label: label.into(),
            month,
            total,
        }
    }

    fn rep(p: u128, a: u128, met: i64, partly: i64, missed: i64) -> ReportIn {
        ReportIn {
            period_id: id(p),
            assignment_id: id(a),
            met,
            partly,
            missed,
        }
    }

    /// Teams: Tana(1) has seats 1 and 2, Abe(2) has seat 3, seat 4 is inactive in Abe.
    /// Periods: 100 = Nov 2025, 101 = Feb 2026 (shown).
    fn fixture() -> SummaryInput {
        let p_old = PeriodIn {
            id: id(100),
            start_month: d(2025, 11),
        };
        let p_new = PeriodIn {
            id: id(101),
            start_month: d(2026, 2),
        };
        SummaryInput {
            shown: p_new.clone(),
            periods: vec![p_old, p_new],
            teams: vec![
                TeamIn {
                    id: 1,
                    name: "Tana".into(),
                },
                TeamIn {
                    id: 2,
                    name: "Abe".into(),
                },
                TeamIn {
                    id: 3,
                    name: "Empty".into(),
                },
            ],
            seats: vec![
                seat(1, "Ben", 1, true),
                seat(2, "Ana", 1, true),
                seat(3, "Cora", 2, true),
                seat(4, "Dan", 2, false),
            ],
            reports: vec![
                rep(101, 1, 2, 1, 0),
                rep(101, 3, 0, 1, 2),
                rep(100, 1, 1, 0, 1),
                rep(100, 4, 3, 0, 0),
            ],
            values: vec![
                // Feb: Ben counts Files 1,2,3 and Calls 0,0,4.
                val(101, 1, "Files", 0, 1),
                val(101, 1, "Files", 1, 2),
                val(101, 1, "Files", 2, 3),
                val(101, 1, "Calls", 2, 4),
                // Cora counts "files" (other case) 10,0,5.
                val(101, 3, "files", 0, 10),
                val(101, 3, "files", 2, 5),
                // Nov: Ben 7 files in month 1, Dan (inactive now) 100 boxes in month 0.
                val(100, 1, "Files", 1, 7),
                val(100, 4, "Boxes", 0, 100),
            ],
            volumes: vec![(id(100), 107), (id(101), 25)],
        }
    }

    #[test]
    fn headline_numbers() {
        let s = build(&fixture());
        assert_eq!(s["period_label"], "Feb to Apr 2026");
        assert_eq!(s["expected"], 3);
        assert_eq!(s["submitted"], 2);
        assert_eq!(
            s["months"],
            json!([
                {"offset": 0, "year": 2026, "month": 2, "short": "Feb"},
                {"offset": 1, "year": 2026, "month": 3, "short": "Mar"},
                {"offset": 2, "year": 2026, "month": 4, "short": "Apr"},
            ])
        );
    }

    #[test]
    fn teams_in_order_without_empty_ones() {
        let s = build(&fixture());
        let teams = s["teams"].as_array().unwrap();
        assert_eq!(teams.len(), 2);
        assert_eq!(
            teams[0],
            json!({"team_id": "1", "name": "Tana", "expected": 2, "submitted": 1,
                   "met": 2, "partly": 1, "missed": 0, "volume_by_month": [1, 2, 7]})
        );
        assert_eq!(
            teams[1],
            json!({"team_id": "2", "name": "Abe", "expected": 1, "submitted": 1,
                   "met": 0, "partly": 1, "missed": 2, "volume_by_month": [10, 0, 5]})
        );
    }

    #[test]
    fn counts_group_by_lowercase_label() {
        let s = build(&fixture());
        let m = s["metrics"].as_array().unwrap();
        assert_eq!(m.len(), 2);
        // Files: 1+2+3 from Tana, 10+5 from Abe = 21. Calls = 4.
        assert_eq!(
            m[0],
            json!({"label": "Files", "total": 21, "by_month": [11, 2, 8],
                   "by_team": [{"team": "Abe", "total": 15}, {"team": "Tana", "total": 6}]})
        );
        assert_eq!(
            m[1],
            json!({"label": "Calls", "total": 4, "by_month": [0, 0, 4],
                   "by_team": [{"team": "Tana", "total": 4}]})
        );
    }

    #[test]
    fn trend_is_oldest_first_and_keeps_old_reports() {
        let s = build(&fixture());
        let t = s["trend"].as_array().unwrap();
        assert_eq!(t.len(), 2);
        assert_eq!(
            t[0],
            json!({"period_id": id(100).to_string(), "label": "Nov 2025 to Jan 2026",
                   "start_month": "2025-11-01", "expected": 3, "submitted": 2,
                   "met": 4, "partly": 0, "missed": 1, "volume_total": 107})
        );
        assert_eq!(t[1]["label"], "Feb to Apr 2026");
        assert_eq!(t[1]["submitted"], 2);
        assert_eq!(t[1]["met"], 2);
        assert_eq!(t[1]["partly"], 2);
        assert_eq!(t[1]["missed"], 2);
        assert_eq!(t[1]["volume_total"], 25);
    }

    #[test]
    fn people_in_deck_order_active_seats_only_unless_submitted() {
        let s = build(&fixture());
        let p = s["people"].as_array().unwrap();
        let names: Vec<&str> = p.iter().map(|x| x["name"].as_str().unwrap()).collect();
        assert_eq!(names, ["Ben", "Ana", "Cora"]);
        assert_eq!(p[0]["submitted"], true);
        assert_eq!(p[0]["volume_total"], 10);
        assert_eq!(p[1]["submitted"], false);
        assert_eq!(p[1]["met"], 0);
        assert_eq!(p[2]["missed"], 2);
        assert_eq!(p[2]["volume_total"], 15);
    }

    #[test]
    fn empty_input_is_all_zero() {
        let p = PeriodIn {
            id: id(1),
            start_month: d(2026, 11),
        };
        let s = build(&SummaryInput {
            shown: p.clone(),
            periods: vec![p],
            teams: vec![],
            seats: vec![],
            reports: vec![],
            values: vec![],
            volumes: vec![],
        });
        assert_eq!(s["expected"], 0);
        assert_eq!(s["period_label"], "Nov 2026 to Jan 2027");
        assert_eq!(s["teams"], json!([]));
        assert_eq!(s["metrics"], json!([]));
        assert_eq!(s["trend"][0]["volume_total"], 0);
    }
}
