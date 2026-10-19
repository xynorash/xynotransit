//! A tiny model of the data, a seeded random generator for it, and a brute force reading of it.
//!
//! The brute force code below is deliberately dumb: plain loops over plain vectors, no SQL, no
//! shared code with the API. The tests compare what the API answers with what these loops say.
//! Every rule written here comes from the READMEs ("only submitted reports count", "counts with
//! the same name, ignoring case, are added", "the deck shows what the report answered", ...).

#![allow(dead_code)]

use rand::{rngs::StdRng, Rng, SeedableRng};
use serde_json::{json, Value};
use uuid::Uuid;

pub struct Team {
    pub id: i32,
    pub name: String,
    pub sort: i32,
}
pub struct Seat {
    pub id: Uuid,
    pub code: String,
    pub person: usize,
    pub team: usize,
    pub role: String,
    pub sort: i32,
    pub active: bool,
}
pub struct MDef {
    pub id: Uuid,
    pub seat: usize,
    pub key: String,
    pub label: String,
    pub series: i32,
    pub retired: bool,
}
pub struct KDef {
    pub id: Uuid,
    pub seat: usize,
    pub sort: i32,
    pub text: String,
    pub retired: bool,
}
pub struct Period {
    pub id: Uuid,
    pub year: i32,
    pub month: u32,
}
pub struct Report {
    pub id: Uuid,
    pub period: usize,
    pub seat: usize,
    pub submitted: bool,
    pub reporter: Option<(String, String, String)>,
    /// (metric def index, month 0..2, value)
    pub values: Vec<(usize, usize, i64)>,
    /// (kpi def index, status, comment)
    pub kpis: Vec<(usize, &'static str, Option<String>)>,
    /// (kind, position 1..3, text)
    pub notes: Vec<(&'static str, i16, String)>,
}

pub struct Dataset {
    pub teams: Vec<Team>,
    pub persons: Vec<(Uuid, String)>,
    /// A switched off person cannot sign in, so their seats are not expected.
    pub person_active: Vec<bool>,
    pub seats: Vec<Seat>,
    pub mdefs: Vec<MDef>,
    pub kdefs: Vec<KDef>,
    pub periods: Vec<Period>,
    pub reports: Vec<Report>,
}

const TEAM_NAMES: [&str; 6] = [
    "Tana",
    "Antsirabe",
    "Toamasina",
    "Mahajanga",
    "Fianarantsoa",
    "Cap d'Ambre",
];
const PERSON_NAMES: [&str; 8] = [
    "Ana Rakoto",
    "Ben O'Neil",
    "Cora Boss",
    "Dédé Ñandú",
    "日本 太郎",
    "Zoë \"Z\" Roy",
    "Mia & Co",
    "Nick <b>",
];
const LABELS: [&str; 9] = [
    "Files", "files", "FILES", "Calls", "calls", "Boxes", "Vehicles", "Éclair", "éclair",
];
const WORDS: [&str; 7] = [
    "On time",
    "No errors",
    "Ship fast",
    "Keep calm",
    "Reply in a day",
    "Clean forms",
    "No claims",
];
const COUNTRIES: [&str; 5] = [
    "Madagascar",
    "madagascar",
    "Kenya",
    " Kenya ",
    "Côte d'Ivoire",
];

impl Dataset {
    pub fn generate(seed: u64) -> Dataset {
        let mut r = StdRng::seed_from_u64(seed);
        let n_teams = r.random_range(0..=5usize);
        let teams: Vec<Team> = (0..n_teams)
            .map(|i| Team {
                id: i as i32 + 1,
                name: TEAM_NAMES[i].to_string(),
                sort: r.random_range(0..4),
            })
            .collect();
        let persons: Vec<(Uuid, String)> = (0..r.random_range(1..=6usize))
            .map(|i| (Uuid::from_u128(r.random()), PERSON_NAMES[i].to_string()))
            .collect();

        let person_active: Vec<bool> = persons.iter().map(|_| r.random_bool(0.9)).collect();
        let mut seats = Vec::new();
        if n_teams > 0 {
            for i in 0..r.random_range(0..=12usize) {
                seats.push(Seat {
                    id: Uuid::from_u128(r.random()),
                    code: format!("c{}-{i}", r.random_range(0..3)),
                    person: r.random_range(0..persons.len()),
                    team: r.random_range(0..n_teams),
                    role: format!("Role {i}"),
                    sort: r.random_range(0..3),
                    active: r.random_bool(0.8),
                });
            }
        }

        let mut mdefs = Vec::new();
        let mut kdefs = Vec::new();
        for (si, _) in seats.iter().enumerate() {
            // Live counts have distinct names (ignoring case) and series 0..k.
            let mut used: Vec<String> = Vec::new();
            let mut live = 0;
            for _ in 0..r.random_range(0..=4usize) {
                let label = LABELS[r.random_range(0..LABELS.len())];
                if used.contains(&label.to_lowercase()) {
                    continue;
                }
                used.push(label.to_lowercase());
                mdefs.push(MDef {
                    id: Uuid::from_u128(r.random()),
                    seat: si,
                    key: format!("k{}", mdefs.len()),
                    label: label.to_string(),
                    series: live,
                    retired: false,
                });
                live += 1;
            }
            // Retired ones: any name, any old series, even the name of a live one.
            for _ in 0..r.random_range(0..=2usize) {
                mdefs.push(MDef {
                    id: Uuid::from_u128(r.random()),
                    seat: si,
                    key: format!("k{}", mdefs.len()),
                    label: LABELS[r.random_range(0..LABELS.len())].to_string(),
                    series: r.random_range(0..6),
                    retired: true,
                });
            }
            for k in 0..r.random_range(0..=4usize) {
                kdefs.push(KDef {
                    id: Uuid::from_u128(r.random()),
                    seat: si,
                    sort: k as i32 + 1,
                    text: format!("{} {}", WORDS[r.random_range(0..WORDS.len())], kdefs.len()),
                    retired: r.random_bool(0.25),
                });
            }
        }

        let mut months: Vec<(i32, u32)> = Vec::new();
        for _ in 0..r.random_range(1..=8usize) {
            let m = (2025 + r.random_range(0..3), r.random_range(1..=12u32));
            if !months.contains(&m) {
                months.push(m);
            }
        }
        let periods: Vec<Period> = months
            .into_iter()
            .map(|(year, month)| Period {
                id: Uuid::from_u128(r.random()),
                year,
                month,
            })
            .collect();

        let mut reports = Vec::new();
        for (pi, _) in periods.iter().enumerate() {
            for (si, _) in seats.iter().enumerate() {
                if !r.random_bool(0.6) {
                    continue;
                }
                let mut rep = Report {
                    id: Uuid::from_u128(r.random()),
                    period: pi,
                    seat: si,
                    submitted: r.random_bool(0.8),
                    reporter: if r.random_bool(0.7) {
                        Some((
                            PERSON_NAMES[r.random_range(0..PERSON_NAMES.len())].to_string(),
                            COUNTRIES[r.random_range(0..COUNTRIES.len())]
                                .trim()
                                .to_string(),
                            format!("Role {}", r.random_range(0..9)),
                        ))
                    } else {
                        None
                    },
                    values: vec![],
                    kpis: vec![],
                    notes: vec![],
                };
                for (mi, m) in mdefs.iter().enumerate() {
                    if m.seat != si || !r.random_bool(if m.retired { 0.5 } else { 0.9 }) {
                        continue;
                    }
                    for month in 0..3 {
                        if r.random_bool(0.93) {
                            let v = match r.random_range(0..10) {
                                0 => 0,
                                1 => 1_000_000_000,
                                2 => r.random_range(0..1_000_000_000i64),
                                _ => r.random_range(0..500i64),
                            };
                            rep.values.push((mi, month, v));
                        }
                    }
                }
                for (ki, k) in kdefs.iter().enumerate() {
                    if k.seat == si && r.random_bool(0.85) {
                        let st = ["met", "partly", "missed"][r.random_range(0..3)];
                        let comment = r.random_bool(0.3).then(|| format!("because {ki}"));
                        rep.kpis.push((ki, st, comment));
                    }
                }
                for kind in ["well", "wrong", "next"] {
                    for pos in 1..=3i16 {
                        if r.random_bool(0.3) {
                            rep.notes
                                .push((kind, pos, format!("{kind} {pos} \u{e9}'s")));
                        }
                    }
                }
                reports.push(rep);
            }
        }
        Dataset {
            teams,
            persons,
            person_active,
            seats,
            mdefs,
            kdefs,
            periods,
            reports,
        }
    }

    /// One SQL script that inserts everything (the manager Cora is added by the caller).
    pub fn insert_sql(&self) -> String {
        let q = |s: &str| format!("'{}'", s.replace('\'', "''"));
        let mut o = String::new();
        for t in &self.teams {
            o += &format!(
                "insert into team (code, name, sort) values ({}, {}, {});\n",
                q(&format!("t{}", t.id)),
                q(&t.name),
                t.sort
            );
        }
        for (i, (id, name)) in self.persons.iter().enumerate() {
            o += &format!(
                "insert into person (id, full_name, email, active) values ('{id}', {}, 'p{i}@x.org', {});\n",
                q(name),
                self.person_active[i]
            );
        }
        for s in &self.seats {
            o += &format!(
                "insert into assignment (id, code, person_id, team_id, role_title, sort, active) values ('{}', {}, '{}', {}, {}, {}, {});\n",
                s.id, q(&s.code), self.persons[s.person].0, self.teams[s.team].id, q(&s.role), s.sort, s.active
            );
        }
        for m in &self.mdefs {
            o += &format!(
                "insert into metric_def (id, assignment_id, key, label, series, retired_at) values ('{}', '{}', {}, {}, {}, {});\n",
                m.id, self.seats[m.seat].id, q(&m.key), q(&m.label), m.series,
                if m.retired { "now()" } else { "null" }
            );
        }
        for k in &self.kdefs {
            o += &format!(
                "insert into kpi_def (id, assignment_id, sort, text, retired_at) values ('{}', '{}', {}, {}, {});\n",
                k.id, self.seats[k.seat].id, k.sort, q(&k.text),
                if k.retired { "now()" } else { "null" }
            );
        }
        for (i, p) in self.periods.iter().enumerate() {
            o += &format!(
                "insert into period (id, start_month) values ('{}', '{}-{:02}-01');\n",
                p.id, p.year, p.month
            );
            let _ = i;
        }
        for r in &self.reports {
            let (n, c, role) = match &r.reporter {
                Some((n, c, ro)) => (q(n), q(c), q(ro)),
                None => ("null".into(), "null".into(), "null".into()),
            };
            o += &format!(
                "insert into report (id, period_id, assignment_id, status, submitted_at, reporter_name, reporter_country, reporter_role) values ('{}', '{}', '{}', '{}', {}, {n}, {c}, {role});\n",
                r.id, self.periods[r.period].id, self.seats[r.seat].id,
                if r.submitted { "submitted" } else { "draft" },
                if r.submitted { "now()" } else { "null" }
            );
            for (mi, month, v) in &r.values {
                o += &format!(
                    "insert into report_metric_value (report_id, assignment_id, metric_def_id, month_offset, value) values ('{}', '{}', '{}', {month}, {v});\n",
                    r.id, self.seats[r.seat].id, self.mdefs[*mi].id
                );
            }
            for (ki, st, comment) in &r.kpis {
                o += &format!(
                    "insert into report_kpi_result (report_id, assignment_id, kpi_def_id, status, comment) values ('{}', '{}', '{}', '{st}', {});\n",
                    r.id, self.seats[r.seat].id, self.kdefs[*ki].id,
                    comment.as_deref().map(q).unwrap_or_else(|| "null".into())
                );
            }
            for (kind, pos, text) in &r.notes {
                o += &format!(
                    "insert into report_note (report_id, kind, position, text) values ('{}', '{kind}', {pos}, {});\n",
                    r.id, q(text)
                );
            }
        }
        o
    }

    // ------------------------------------------------------------------ brute force readings

    /// A seat is expected when it and its person are switched on.
    pub fn on(&self, seat: usize) -> bool {
        self.seats[seat].active && self.person_active[self.seats[seat].person]
    }

    fn start(&self, p: usize) -> (i32, u32) {
        (self.periods[p].year, self.periods[p].month)
    }

    fn add_months(&self, (y, m): (i32, u32), n: u32) -> (i32, u32) {
        let total = y * 12 + (m as i32 - 1) + n as i32;
        (total / 12, (total % 12) as u32 + 1)
    }

    fn label_of(&self, p: usize) -> String {
        const S: [&str; 12] = [
            "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
        ];
        let (y, m) = self.start(p);
        let (ly, lm) = self.add_months((y, m), 2);
        if ly == y {
            format!("{} to {} {ly}", S[m as usize - 1], S[lm as usize - 1])
        } else {
            format!("{} {y} to {} {ly}", S[m as usize - 1], S[lm as usize - 1])
        }
    }

    /// Seat indexes in deck order: team sort, team id, seat sort, seat code.
    fn deck_order(&self) -> Vec<usize> {
        let mut idx: Vec<usize> = (0..self.seats.len()).collect();
        idx.sort_by(|&a, &b| {
            let (sa, sb) = (&self.seats[a], &self.seats[b]);
            let (ta, tb) = (&self.teams[sa.team], &self.teams[sb.team]);
            (ta.sort, ta.id, sa.sort, &sa.code).cmp(&(tb.sort, tb.id, sb.sort, &sb.code))
        });
        idx
    }

    fn report_of(&self, p: usize, seat: usize) -> Option<&Report> {
        self.reports
            .iter()
            .find(|r| r.period == p && r.seat == seat && r.submitted)
    }

    fn kpi_counts(&self, r: &Report) -> (i64, i64, i64) {
        let mut c = (0, 0, 0);
        for (_, st, _) in &r.kpis {
            match *st {
                "met" => c.0 += 1,
                "partly" => c.1 += 1,
                _ => c.2 += 1,
            }
        }
        c
    }

    /// The display name of a count in one report and month: a live name wins over a retired one,
    /// then the lower series, then the id.
    fn display_label(&self, seat: usize, lower: &str, r: &Report, month: usize) -> (String, i32) {
        let mut best: Option<&MDef> = None;
        let mut min_series = i32::MAX;
        for (mi, m) in self.mdefs.iter().enumerate() {
            if m.seat != seat || m.label.to_lowercase() != lower {
                continue;
            }
            if !r.values.iter().any(|(i, mo, _)| *i == mi && *mo == month) {
                continue;
            }
            min_series = min_series.min(m.series);
            let better = match best {
                None => true,
                Some(b) => (m.retired, m.series, m.id) < (b.retired, b.series, b.id),
            };
            if better {
                best = Some(m);
            }
        }
        (best.unwrap().label.clone(), min_series)
    }

    /// What GET /api/summary must answer.
    pub fn summary(&self, shown: usize, trend: usize) -> Value {
        // The shown period and up to trend-1 earlier ones, oldest first.
        let mut earlier: Vec<usize> = (0..self.periods.len())
            .filter(|&p| self.start(p) <= self.start(shown))
            .collect();
        earlier.sort_by_key(|&p| std::cmp::Reverse(self.start(p)));
        earlier.truncate(trend);
        earlier.reverse();

        let active_total = (0..self.seats.len()).filter(|&s| self.on(s)).count();
        let order = self.deck_order();
        let mut team_order: Vec<usize> = (0..self.teams.len()).collect();
        team_order.sort_by_key(|&t| (self.teams[t].sort, self.teams[t].id));

        // The shown period: every submitted report with its seat.
        let shown_reports: Vec<&Report> = self
            .reports
            .iter()
            .filter(|r| r.period == shown && r.submitted)
            .collect();
        let seat_total = |r: &Report| -> i64 { r.values.iter().map(|v| v.2).sum() };

        let mut teams = Vec::new();
        for &t in &team_order {
            let expected = (0..self.seats.len())
                .filter(|&s| self.seats[s].team == t && self.on(s))
                .count();
            let reps: Vec<&&Report> = shown_reports
                .iter()
                .filter(|r| self.seats[r.seat].team == t)
                .collect();
            if expected == 0 && reps.is_empty() {
                continue;
            }
            let mut vol = [0i64; 3];
            let (mut met, mut partly, mut missed) = (0, 0, 0);
            for r in &reps {
                for (_, m, v) in &r.values {
                    vol[*m] += v;
                }
                let c = self.kpi_counts(r);
                met += c.0;
                partly += c.1;
                missed += c.2;
            }
            teams.push(json!({
                "team_id": self.teams[t].id.to_string(), "name": self.teams[t].name,
                "expected": expected, "submitted": reps.len(),
                "met": met, "partly": partly, "missed": missed, "volume_by_month": vol,
            }));
        }

        // Counts by name ignoring case. Rows come in deck order, then by lowest series, name, month.
        struct Row {
            seat_pos: usize,
            series: i32,
            lower: String,
            month: usize,
            label: String,
            team: usize,
            total: i64,
        }
        let mut rows: Vec<Row> = Vec::new();
        for r in &shown_reports {
            let mut keys: Vec<(String, usize)> = Vec::new();
            for (mi, m, _) in &r.values {
                let k = (self.mdefs[*mi].label.to_lowercase(), *m);
                if !keys.contains(&k) {
                    keys.push(k);
                }
            }
            for (lower, month) in keys {
                let total: i64 = r
                    .values
                    .iter()
                    .filter(|(mi, m, _)| {
                        *m == month && self.mdefs[*mi].label.to_lowercase() == lower
                    })
                    .map(|v| v.2)
                    .sum();
                let (label, series) = self.display_label(r.seat, &lower, r, month);
                rows.push(Row {
                    seat_pos: order.iter().position(|&s| s == r.seat).unwrap(),
                    series,
                    lower,
                    month,
                    label,
                    team: self.seats[r.seat].team,
                    total,
                });
            }
        }
        rows.sort_by(|a, b| {
            (a.seat_pos, a.series, &a.lower, a.month)
                .cmp(&(b.seat_pos, b.series, &b.lower, b.month))
        });
        struct Group {
            lower: String,
            label: String,
            by_month: [i64; 3],
            by_team: Vec<(usize, i64)>,
        }
        let mut groups: Vec<Group> = Vec::new();
        for row in &rows {
            let gi = match groups.iter().position(|g| g.lower == row.lower) {
                Some(i) => i,
                None => {
                    groups.push(Group {
                        lower: row.lower.clone(),
                        label: row.label.clone(),
                        by_month: [0; 3],
                        by_team: vec![],
                    });
                    groups.len() - 1
                }
            };
            groups[gi].by_month[row.month] += row.total;
            match groups[gi].by_team.iter_mut().find(|(t, _)| *t == row.team) {
                Some(e) => e.1 += row.total,
                None => groups[gi].by_team.push((row.team, row.total)),
            }
        }
        let mut metrics: Vec<(i64, Value)> = groups
            .into_iter()
            .map(|mut g| {
                let total: i64 = g.by_month.iter().sum();
                g.by_team.sort_by_key(|(_, n)| std::cmp::Reverse(*n));
                let by_team: Vec<Value> = g
                    .by_team
                    .iter()
                    .map(|(t, n)| json!({"team": self.teams[*t].name, "total": n}))
                    .collect();
                (
                    total,
                    json!({"label": g.label, "total": total, "by_month": g.by_month, "by_team": by_team}),
                )
            })
            .collect();
        metrics.sort_by_key(|(t, _)| std::cmp::Reverse(*t));

        let trend_rows: Vec<Value> = earlier
            .iter()
            .map(|&p| {
                let reps: Vec<&Report> = self
                    .reports
                    .iter()
                    .filter(|r| r.period == p && r.submitted)
                    .collect();
                let (mut met, mut partly, mut missed) = (0, 0, 0);
                for r in &reps {
                    let c = self.kpi_counts(r);
                    met += c.0;
                    partly += c.1;
                    missed += c.2;
                }
                let (y, m) = self.start(p);
                json!({
                    "period_id": self.periods[p].id.to_string(), "label": self.label_of(p),
                    "start_month": format!("{y}-{m:02}-01"), "expected": active_total,
                    "submitted": reps.len(), "met": met, "partly": partly, "missed": missed,
                    "volume_total": reps.iter().map(|r| seat_total(r)).sum::<i64>(),
                })
            })
            .collect();

        let mut people = Vec::new();
        for &s in &order {
            let rep = shown_reports.iter().find(|r| r.seat == s);
            if !self.on(s) && rep.is_none() {
                continue;
            }
            let c = rep.map(|r| self.kpi_counts(r)).unwrap_or((0, 0, 0));
            people.push(json!({
                "assignment_id": self.seats[s].id.to_string(),
                "name": self.persons[self.seats[s].person].1,
                "role": self.seats[s].role,
                "team": self.teams[self.seats[s].team].name,
                "submitted": rep.is_some(),
                "met": c.0, "partly": c.1, "missed": c.2,
                "volume_total": rep.map(|r| seat_total(r)).unwrap_or(0),
            }));
        }

        let months: Vec<Value> = (0..3u32)
            .map(|o| {
                const S: [&str; 12] = [
                    "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov",
                    "Dec",
                ];
                let (y, m) = self.add_months(self.start(shown), o);
                json!({"offset": o, "year": y, "month": m, "short": S[m as usize - 1]})
            })
            .collect();

        json!({
            "period_id": self.periods[shown].id.to_string(),
            "period_label": self.label_of(shown),
            "months": months,
            "expected": active_total,
            "submitted": shown_reports.len(),
            "teams": teams,
            "metrics": metrics.into_iter().map(|m| m.1).collect::<Vec<_>>(),
            "trend": trend_rows,
            "people": people,
        })
    }

    /// The slides POST /periods/{id}/deck must freeze: one per submitted report of an active seat.
    pub fn deck(&self, p: usize) -> (usize, Vec<(Uuid, Value)>) {
        let expected = (0..self.seats.len()).filter(|&s| self.on(s)).count();
        let (y, m) = self.start(p);
        let mut slides = Vec::new();
        for s in self.deck_order() {
            if !self.on(s) {
                continue;
            }
            let Some(r) = self.report_of(p, s) else {
                continue;
            };
            let seat = &self.seats[s];
            let (name, role, country) = match &r.reporter {
                Some((n, c, ro)) => (n.clone(), ro.clone(), c.clone()),
                None => (
                    self.persons[seat.person].1.clone(),
                    seat.role.clone(),
                    self.teams[seat.team].name.clone(),
                ),
            };
            let value = |mi: usize, month: usize| -> i64 {
                r.values
                    .iter()
                    .find(|(i, mo, _)| *i == mi && *mo == month)
                    .map(|v| v.2)
                    .unwrap_or(0)
            };
            // Counts the report has any number for, by series then id; own colour for each.
            let mut ms: Vec<usize> = (0..self.mdefs.len())
                .filter(|&i| self.mdefs[i].seat == s && r.values.iter().any(|(mi, _, _)| *mi == i))
                .collect();
            ms.sort_by_key(|&i| (self.mdefs[i].series, self.mdefs[i].id));
            let mut series: Vec<i32> = ms.iter().map(|&i| self.mdefs[i].series).collect();
            let mut sorted = series.clone();
            sorted.sort();
            sorted.dedup();
            if sorted.len() != series.len() {
                series = (0..ms.len() as i32).collect();
            }
            let metrics: Vec<Value> = ms
                .iter()
                .zip(series)
                .map(|(&i, se)| {
                    json!({
                        "key": self.mdefs[i].key, "label": self.mdefs[i].label, "series": se,
                        "values": [value(i, 0), value(i, 1), value(i, 2)],
                    })
                })
                .collect();
            let mut ks: Vec<usize> = (0..self.kdefs.len())
                .filter(|&i| self.kdefs[i].seat == s && r.kpis.iter().any(|k| k.0 == i))
                .collect();
            ks.sort_by_key(|&i| (self.kdefs[i].sort, self.kdefs[i].id));
            let targets: Vec<Value> = ks
                .iter()
                .map(|&i| {
                    let st = r.kpis.iter().find(|k| k.0 == i).unwrap().1;
                    json!({"text": self.kdefs[i].text, "status": st})
                })
                .collect();
            let notes = |kind: &str| -> Vec<String> {
                let mut v: Vec<(i16, String)> = r
                    .notes
                    .iter()
                    .filter(|n| n.0 == kind)
                    .map(|n| (n.1, n.2.clone()))
                    .collect();
                v.sort();
                v.into_iter().map(|n| n.1).collect()
            };
            const S: [&str; 12] = [
                "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
            ];
            let months: Vec<Value> = (0..3u32)
                .map(|o| {
                    let (yy, mm) = self.add_months((y, m), o);
                    json!({"offset": o, "year": yy, "month": mm, "short": S[mm as usize - 1]})
                })
                .collect();
            slides.push((
                r.id,
                json!({
                    "assignmentCode": seat.code, "name": name, "role": role, "team": country,
                    "periodLabel": self.label_of(p), "months": months, "metrics": metrics,
                    "targets": targets, "well": notes("well"), "wrong": notes("wrong"),
                    "next": notes("next"),
                }),
            ));
        }
        (expected, slides)
    }
}
