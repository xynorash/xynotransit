//! Pure validation of a report body, in the same plain words as the app.

use std::collections::{HashMap, HashSet};

use chrono::{Datelike, NaiveDate};
use serde::Deserialize;
use uuid::Uuid;

use crate::snapshot::{month_at, month_long};

use crate::rules::msg;
pub use crate::rules::{
    COMMENT_MAX_CHARS, KPI_STATUSES, NOTES_PER_KIND, NOTE_KINDS, NOTE_MAX_CHARS,
    REPORTER_MAX_CHARS, VALUE_MAX, VALUE_MIN,
};

#[derive(Debug, Clone, Deserialize)]
pub struct ValueIn {
    pub metric_def_id: Uuid,
    pub month_offset: i16,
    pub value: Option<i64>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct KpiIn {
    pub kpi_def_id: Uuid,
    pub status: String,
    #[serde(default)]
    pub comment: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct NoteIn {
    pub kind: String,
    pub position: i16,
    pub text: String,
}

/// Who the report is from, in the reporter's own words.
#[derive(Debug, Clone, Default, Deserialize)]
pub struct ReporterIn {
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub country: String,
    #[serde(default)]
    pub role: String,
}

impl ReporterIn {
    /// The three words, trimmed.
    pub fn trimmed(&self) -> (String, String, String) {
        (
            self.name.trim().to_string(),
            self.country.trim().to_string(),
            self.role.trim().to_string(),
        )
    }
}

/// Problems of one reporter field: empty, too long (in characters), or not plain text.
fn field_problem(value: &str, what: &str) -> Option<String> {
    let t = value.trim();
    if t.is_empty() {
        Some(msg::REPORTER_EMPTY.replace("{what}", what))
    } else if t.chars().count() > REPORTER_MAX_CHARS {
        Some(msg::REPORTER_LONG.replace("{what}", what))
    } else if t
        .chars()
        .any(|c| c.is_control() || crate::rules::is_invisible(c))
    {
        Some(msg::REPORTER_PLAIN.replace("{what}", what))
    } else {
        None
    }
}

/// Problems of the reporter block, in field order. A missing block is three empty fields.
pub fn reporter_problems(r: Option<&ReporterIn>) -> Vec<String> {
    let empty = ReporterIn::default();
    let r = r.unwrap_or(&empty);
    [
        field_problem(&r.name, "name"),
        field_problem(&r.country, "country"),
        field_problem(&r.role, "role"),
    ]
    .into_iter()
    .flatten()
    .collect()
}

#[derive(Debug, Clone, Default, Deserialize)]
pub struct ReportInput {
    #[serde(default)]
    pub reporter: Option<ReporterIn>,
    #[serde(default)]
    pub values: Vec<ValueIn>,
    #[serde(default)]
    pub kpis: Vec<KpiIn>,
    #[serde(default)]
    pub notes: Vec<NoteIn>,
}

pub struct MetricRef {
    pub id: Uuid,
    pub label: String,
}

/// Every problem found, in the order a person should fix them. Empty means valid.
pub fn validate(
    input: &ReportInput,
    metrics: &[MetricRef],
    kpi_ids: &[Uuid],
    start_month: NaiveDate,
) -> Vec<String> {
    let mut problems = reporter_problems(input.reporter.as_ref());

    // Ids must belong to this assignment.
    let metric_ids: HashSet<Uuid> = metrics.iter().map(|m| m.id).collect();
    let kpi_set: HashSet<Uuid> = kpi_ids.iter().copied().collect();
    if input
        .values
        .iter()
        .any(|v| !metric_ids.contains(&v.metric_def_id))
    {
        problems.push(msg::VALUE_NOT_YOURS.to_string());
    }
    if input.kpis.iter().any(|k| !kpi_set.contains(&k.kpi_def_id)) {
        problems.push(msg::KPI_NOT_YOURS.to_string());
    }
    if input
        .values
        .iter()
        .any(|v| !(0..=2).contains(&v.month_offset))
    {
        problems.push(msg::MONTH_OUTSIDE.to_string());
    }
    let mut seen_values = HashSet::new();
    if input
        .values
        .iter()
        .any(|v| !seen_values.insert((v.metric_def_id, v.month_offset)))
    {
        problems.push(msg::VALUE_TWICE.to_string());
    }
    let mut seen_kpis = HashSet::new();
    if input.kpis.iter().any(|k| !seen_kpis.insert(k.kpi_def_id)) {
        problems.push(msg::KPI_TWICE.to_string());
    }
    if input
        .kpis
        .iter()
        .any(|k| !KPI_STATUSES.contains(&k.status.as_str()))
    {
        problems.push(msg::KPI_STATUS.to_string());
    }

    // Step 2: a number for every month of every metric (first gap per metric).
    let given: HashMap<(Uuid, i16), Option<i64>> = input
        .values
        .iter()
        .map(|v| ((v.metric_def_id, v.month_offset), v.value))
        .collect();
    for m in metrics {
        for offset in 0..3i16 {
            let ok =
                matches!(given.get(&(m.id, offset)), Some(Some(x)) if (0..=VALUE_MAX).contains(x));
            if !ok {
                let month = month_at(start_month, offset as u32).month();
                problems.push(
                    msg::VALUE_MISSING
                        .replace("{label}", &m.label)
                        .replace("{month}", month_long(month)),
                );
                break;
            }
        }
    }

    if input
        .values
        .iter()
        .any(|v| v.value.is_some_and(|x| x > VALUE_MAX))
    {
        problems.push(msg::VALUE_TOO_BIG.to_string());
    }

    // Step 3: every active target answered.
    let answered: HashSet<Uuid> = input
        .kpis
        .iter()
        .filter(|k| KPI_STATUSES.contains(&k.status.as_str()))
        .map(|k| k.kpi_def_id)
        .collect();
    let left = kpi_ids.iter().filter(|id| !answered.contains(id)).count();
    if left > 0 {
        problems.push(msg::KPIS_LEFT.replace("{left}", &left.to_string()));
    }
    if input
        .kpis
        .iter()
        .any(|k| k.comment.as_deref().map_or(0, |c| c.trim().chars().count()) > COMMENT_MAX_CHARS)
    {
        problems.push(msg::COMMENT_LONG.to_string());
    }

    // Postgres cannot store NUL in text; refuse it here instead of failing later.
    if input.notes.iter().any(|n| n.text.contains('\0'))
        || input
            .kpis
            .iter()
            .any(|k| k.comment.as_deref().is_some_and(|c| c.contains('\0')))
    {
        problems.push(msg::NUL_TEXT.to_string());
    }

    // Step 4: short notes.
    if input
        .notes
        .iter()
        .any(|n| !NOTE_KINDS.contains(&n.kind.as_str()))
    {
        problems.push(msg::NOTE_BOX.to_string());
    }
    for kind in NOTE_KINDS {
        let of_kind: Vec<&NoteIn> = input.notes.iter().filter(|n| n.kind == kind).collect();
        if of_kind.len() > NOTES_PER_KIND {
            problems.push(msg::NOTES_TOO_MANY.to_string());
        }
        if of_kind
            .iter()
            .any(|n| !(1..=NOTES_PER_KIND as i16).contains(&n.position))
        {
            problems.push(msg::NOTE_NUMBER.to_string());
        }
        let mut seen = HashSet::new();
        if of_kind.iter().any(|n| !seen.insert(n.position)) {
            problems.push(msg::NOTE_SAME_NUMBER.to_string());
        }
    }
    if input.notes.iter().any(|n| n.text.trim().is_empty()) {
        problems.push(msg::NOTE_EMPTY.to_string());
    }
    if input
        .notes
        .iter()
        .any(|n| n.text.trim().chars().count() > NOTE_MAX_CHARS)
    {
        problems.push(msg::NOTE_LONG.to_string());
    }

    problems
}

#[cfg(test)]
mod tests {
    use super::*;

    fn d(y: i32, m: u32) -> NaiveDate {
        NaiveDate::from_ymd_opt(y, m, 1).unwrap()
    }

    struct Fx {
        m1: Uuid,
        m2: Uuid,
        k1: Uuid,
        k2: Uuid,
        metrics: Vec<MetricRef>,
    }

    fn fx() -> Fx {
        let (m1, m2, k1, k2) = (
            Uuid::new_v4(),
            Uuid::new_v4(),
            Uuid::new_v4(),
            Uuid::new_v4(),
        );
        Fx {
            m1,
            m2,
            k1,
            k2,
            metrics: vec![
                MetricRef {
                    id: m1,
                    label: "Files".into(),
                },
                MetricRef {
                    id: m2,
                    label: "Calls".into(),
                },
            ],
        }
    }

    fn good(f: &Fx) -> ReportInput {
        let mut values = vec![];
        for m in [f.m1, f.m2] {
            for o in 0..3 {
                values.push(ValueIn {
                    metric_def_id: m,
                    month_offset: o,
                    value: Some(1),
                });
            }
        }
        ReportInput {
            reporter: Some(ReporterIn {
                name: "Rova R.".into(),
                country: "Madagascar".into(),
                role: "Import".into(),
            }),
            values,
            kpis: vec![
                KpiIn {
                    kpi_def_id: f.k1,
                    status: "met".into(),
                    comment: None,
                },
                KpiIn {
                    kpi_def_id: f.k2,
                    status: "missed".into(),
                    comment: Some("late".into()),
                },
            ],
            notes: vec![NoteIn {
                kind: "well".into(),
                position: 1,
                text: " ok ".into(),
            }],
        }
    }

    fn run(f: &Fx, i: &ReportInput) -> Vec<String> {
        validate(i, &f.metrics, &[f.k1, f.k2], d(2026, 2))
    }

    #[test]
    fn valid_report_has_no_problems() {
        let f = fx();
        assert!(run(&f, &good(&f)).is_empty());
    }

    #[test]
    fn empty_report_lists_every_gap() {
        let f = fx();
        let p = run(&f, &ReportInput::default());
        assert_eq!(
            p,
            vec![
                "Enter your name.".to_string(),
                "Enter your country.".to_string(),
                "Enter your role.".to_string(),
                "Enter a number for \"Files\" in February.".to_string(),
                "Enter a number for \"Calls\" in February.".to_string(),
                "Answer all targets in step 3 (2 left).".to_string(),
            ]
        );
    }

    #[test]
    fn first_missing_month_per_metric_uses_real_month_name() {
        let f = fx();
        let mut i = good(&f);
        i.values
            .retain(|v| !(v.metric_def_id == f.m1 && v.month_offset >= 1));
        assert_eq!(
            run(&f, &i),
            vec!["Enter a number for \"Files\" in March.".to_string()]
        );
        let mut i = good(&f);
        i.values
            .retain(|v| !(v.metric_def_id == f.m2 && v.month_offset == 2));
        let p = validate(&i, &f.metrics, &[f.k1, f.k2], d(2026, 11));
        assert_eq!(
            p,
            vec!["Enter a number for \"Calls\" in January.".to_string()]
        );
    }

    #[test]
    fn negative_or_null_value_counts_as_missing() {
        let f = fx();
        let mut i = good(&f);
        i.values[0].value = Some(-1);
        i.values[4].value = None;
        let p = run(&f, &i);
        assert_eq!(
            p,
            vec![
                "Enter a number for \"Files\" in February.".to_string(),
                "Enter a number for \"Calls\" in March.".to_string(),
            ]
        );
    }

    #[test]
    fn unanswered_targets_are_counted() {
        let f = fx();
        let mut i = good(&f);
        i.kpis.pop();
        assert_eq!(
            run(&f, &i),
            vec!["Answer all targets in step 3 (1 left).".to_string()]
        );
    }

    #[test]
    fn foreign_ids_are_rejected() {
        let f = fx();
        let mut i = good(&f);
        i.values[0].metric_def_id = Uuid::new_v4();
        assert!(run(&f, &i)[0].contains("numbers does not belong"));
        let mut i = good(&f);
        i.kpis[0].kpi_def_id = Uuid::new_v4();
        assert!(run(&f, &i)[0].contains("targets does not belong"));
    }

    #[test]
    fn bad_status_offset_and_duplicates() {
        let f = fx();
        let mut i = good(&f);
        i.kpis[0].status = "great".into();
        assert!(run(&f, &i)
            .iter()
            .any(|p| p.contains("met, partly or missed")));
        let mut i = good(&f);
        i.values[0].month_offset = 3;
        assert!(run(&f, &i)
            .iter()
            .any(|p| p.contains("outside this period")));
        let mut i = good(&f);
        i.values.push(i.values[0].clone());
        assert!(run(&f, &i).iter().any(|p| p.contains("twice")));
    }

    #[test]
    fn comment_cap_is_200() {
        let f = fx();
        let mut i = good(&f);
        i.kpis[0].comment = Some("x".repeat(200));
        assert!(run(&f, &i).is_empty());
        i.kpis[0].comment = Some("x".repeat(201));
        assert_eq!(
            run(&f, &i),
            vec!["A comment can be at most 200 characters.".to_string()]
        );
    }

    fn note(kind: &str, position: i16, text: &str) -> NoteIn {
        NoteIn {
            kind: kind.into(),
            position,
            text: text.into(),
        }
    }

    #[test]
    fn note_cap_is_70_after_trim() {
        let f = fx();
        let mut i = good(&f);
        i.notes = vec![note("well", 1, &format!("  {}  ", "y".repeat(70)))];
        assert!(run(&f, &i).is_empty());
        i.notes = vec![note("well", 1, &"y".repeat(71))];
        assert_eq!(
            run(&f, &i),
            vec!["A note can be at most 70 characters.".to_string()]
        );
        // 70 multibyte characters are fine: we count characters, not bytes.
        i.notes = vec![note("well", 1, &"é".repeat(70))];
        assert!(run(&f, &i).is_empty());
    }

    #[test]
    fn at_most_three_notes_per_kind() {
        let f = fx();
        let mut i = good(&f);
        i.notes = (1..=3).map(|p| note("wrong", p, "a")).collect();
        assert!(run(&f, &i).is_empty());
        i.notes.push(note("wrong", 1, "b"));
        let p = run(&f, &i);
        assert!(p.contains(&"Write at most 3 notes per box.".to_string()));
        // Three per kind across different kinds is fine.
        i.notes = ["well", "wrong", "next"]
            .iter()
            .flat_map(|k| (1..=3).map(move |p| note(k, p, "a")))
            .collect();
        assert!(run(&f, &i).is_empty());
    }

    #[test]
    fn note_positions_kinds_and_empty_text() {
        let f = fx();
        let mut i = good(&f);
        i.notes = vec![note("well", 4, "a")];
        assert_eq!(run(&f, &i), vec!["Notes are numbered 1 to 3.".to_string()]);
        i.notes = vec![note("well", 1, "a"), note("well", 1, "b")];
        assert_eq!(
            run(&f, &i),
            vec!["Two notes in the same box have the same number.".to_string()]
        );
        i.notes = vec![note("other", 1, "a")];
        assert_eq!(
            run(&f, &i),
            vec!["A note is in a box that does not exist.".to_string()]
        );
        i.notes = vec![note("well", 1, "   ")];
        assert_eq!(run(&f, &i), vec!["A note cannot be empty.".to_string()]);
    }

    fn with_reporter(f: &Fx, name: &str, country: &str, role: &str) -> Vec<String> {
        let mut i = good(f);
        i.reporter = Some(ReporterIn {
            name: name.into(),
            country: country.into(),
            role: role.into(),
        });
        run(f, &i)
    }

    #[test]
    fn missing_reporter_asks_for_all_three_first() {
        let f = fx();
        let mut i = good(&f);
        i.reporter = None;
        assert_eq!(
            run(&f, &i),
            vec![
                "Enter your name.".to_string(),
                "Enter your country.".to_string(),
                "Enter your role.".to_string()
            ]
        );
    }

    #[test]
    fn blank_reporter_fields_are_messages_in_field_order() {
        let f = fx();
        assert_eq!(
            with_reporter(&f, "   ", "Madagascar", ""),
            vec![
                "Enter your name.".to_string(),
                "Enter your role.".to_string()
            ]
        );
        assert_eq!(
            with_reporter(&f, "Rova", "\t ", "Import"),
            vec!["Enter your country.".to_string()]
        );
    }

    #[test]
    fn reporter_length_counts_characters_not_bytes() {
        let f = fx();
        // 80 two-byte characters (160 bytes) are fine; 81 are not.
        let ok = "é".repeat(80);
        assert!(with_reporter(&f, &ok, &ok, &ok).is_empty());
        let long = "é".repeat(81);
        assert_eq!(
            with_reporter(&f, &long, "x", &long),
            vec![
                "Your name can be at most 80 characters.".to_string(),
                "Your role can be at most 80 characters.".to_string()
            ]
        );
        // Surrounding spaces do not count.
        let padded = format!("  {}  ", "a".repeat(80));
        assert!(with_reporter(&f, &padded, "x", "y").is_empty());
    }

    #[test]
    fn reporter_must_be_plain_text() {
        let f = fx();
        assert_eq!(
            with_reporter(&f, "Ro\nva", "x", "y"),
            vec!["Your name must be plain text on one line.".to_string()]
        );
        assert_eq!(
            with_reporter(&f, "x", "Mada\u{200B}gascar", "y"),
            vec!["Your country must be plain text on one line.".to_string()]
        );
        assert_eq!(
            with_reporter(&f, "x", "y", "a\0b"),
            vec!["Your role must be plain text on one line.".to_string()]
        );
    }

    #[test]
    fn reporter_is_trimmed() {
        let r = ReporterIn {
            name: " A ".into(),
            country: "B\u{a0}".into(),
            role: "C".into(),
        };
        assert_eq!(r.trimmed(), ("A".into(), "B".into(), "C".into()));
    }
}
