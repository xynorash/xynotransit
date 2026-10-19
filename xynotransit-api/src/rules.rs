//! Pure rules for the things a manager types: names, emails, slugs, counts and targets.
//! Every message is plain words, the same style as `validate`.

use std::collections::HashSet;

use uuid::Uuid;

use crate::error::ApiError;

// ---------------------------------------------------------------------------------------------
// The single source of every limit and fixed message the API enforces.
// `tests/fixtures/rules.json` repeats them for the other side (the Flutter tests read it) and
// `rules_json_matches_code` fails when the two drift apart. Change both together.
// ---------------------------------------------------------------------------------------------

/// Counts (metrics) per seat.
pub const MAX_METRICS: usize = 8;
/// Targets (KPIs) per seat.
pub const MAX_KPIS: usize = 10;
/// Characters of a count name.
pub const MAX_LABEL: usize = 60;
/// Characters of a target text.
pub const MAX_KPI_TEXT: usize = 200;
/// Characters of a seat role title.
pub const MAX_ROLE_TITLE: usize = 80;
/// Characters of a person name.
pub const MAX_NAME: usize = 80;
/// Characters of a team name.
pub const MAX_TEAM_NAME: usize = 60;
/// Highest manual order number of a team or seat.
pub const MAX_SORT: i32 = 10_000;
/// Characters of the reporter name, country and role on a report.
pub const REPORTER_MAX_CHARS: usize = 80;
/// Characters of one note.
pub const NOTE_MAX_CHARS: usize = 70;
/// Notes per box (well, wrong, next).
pub const NOTES_PER_KIND: usize = 3;
/// Characters of a target comment.
pub const COMMENT_MAX_CHARS: usize = 200;
/// Lowest and highest value of a monthly count.
pub const VALUE_MIN: i64 = 0;
pub const VALUE_MAX: i64 = 1_000_000_000;
/// Characters of a whole email address, and of the part before the @.
pub const EMAIL_MAX: usize = 254;
pub const EMAIL_LOCAL_MAX: usize = 64;
/// Meeting dates and period start months must be in these years.
pub const PERIOD_MIN_YEAR: i32 = 2000;
pub const PERIOD_MAX_YEAR: i32 = 2100;
/// A period is three months.
pub const MONTHS_PER_PERIOD: usize = 3;
/// Summary trend: default and highest number of periods.
pub const TREND_DEFAULT: i64 = 6;
pub const TREND_MAX: i64 = 24;
/// Magic links per email per hour, and how long one works.
pub const MAX_LINKS_PER_HOUR: i64 = 5;
pub const LINK_MINUTES: i32 = 15;
/// A session that began with a sign-in link may choose a new password without the old one for
/// this many minutes.
pub const LINK_RECOVERY_MINUTES: i64 = 15;
/// Largest request body.
pub const MAX_BODY_BYTES: usize = 256 * 1024;
pub const NOTE_KINDS: [&str; 3] = ["well", "wrong", "next"];
pub const KPI_STATUSES: [&str; 3] = ["met", "partly", "missed"];
pub const APP_ROLES: [&str; 2] = ["contributor", "controller"];

/// Fixed messages. The ones with `{...}` are templates, filled by the code that raises them.
pub mod msg {
    pub const TEAM_EMPTY: &str = "Enter a team name.";
    pub const TEAM_LONG: &str = "A team name can have at most 60 characters.";
    pub const NAME_EMPTY: &str = "Enter a name.";
    pub const NAME_LONG: &str = "A name can have at most 80 characters.";
    pub const ROLE_TITLE_EMPTY: &str = "Enter a role title.";
    pub const ROLE_TITLE_LONG: &str = "A role title can have at most 80 characters.";
    pub const PLAIN_LINE: &str = "Use plain text on one line.";
    pub const EMAIL_INVALID: &str = "Enter a valid email address.";
    pub const APP_ROLE_INVALID: &str = "Choose employee or manager.";
    pub const SORT_RANGE: &str = "Enter an order between 0 and 10000.";
    pub const METRICS_TOO_MANY: &str = "A seat can have at most 8 counts.";
    pub const METRIC_EMPTY: &str = "Give every count a name.";
    pub const METRIC_LONG: &str = "A count name can have at most 60 characters.";
    pub const METRIC_DUPLICATE: &str =
        "Two counts have the same name. Give each count its own name.";
    pub const KPIS_TOO_MANY: &str = "A seat can have at most 10 targets.";
    pub const KPI_EMPTY: &str = "Write every target in words.";
    pub const KPI_LONG: &str = "A target can have at most 200 characters.";
    pub const LISTED_TWICE: &str = "The same {what} is listed twice.";
    pub const REPORTER_EMPTY: &str = "Enter your {what}.";
    pub const REPORTER_LONG: &str = "Your {what} can be at most 80 characters.";
    pub const REPORTER_PLAIN: &str = "Your {what} must be plain text on one line.";
    pub const VALUE_NOT_YOURS: &str = "One of the numbers does not belong to this report.";
    pub const KPI_NOT_YOURS: &str = "One of the targets does not belong to this report.";
    pub const MONTH_OUTSIDE: &str = "A number is for a month outside this period.";
    pub const VALUE_TWICE: &str = "A number was entered twice for the same month.";
    pub const KPI_TWICE: &str = "A target was answered twice.";
    pub const KPI_STATUS: &str = "Answer each target with met, partly or missed.";
    pub const VALUE_MISSING: &str = "Enter a number for \"{label}\" in {month}.";
    pub const VALUE_TOO_BIG: &str = "A number can be at most 1000000000.";
    pub const KPIS_LEFT: &str = "Answer all targets in step 3 ({left} left).";
    pub const COMMENT_LONG: &str = "A comment can be at most 200 characters.";
    pub const NUL_TEXT: &str = "Text cannot contain control characters.";
    pub const NOTE_BOX: &str = "A note is in a box that does not exist.";
    pub const NOTES_TOO_MANY: &str = "Write at most 3 notes per box.";
    pub const NOTE_NUMBER: &str = "Notes are numbered 1 to 3.";
    pub const NOTE_SAME_NUMBER: &str = "Two notes in the same box have the same number.";
    pub const NOTE_EMPTY: &str = "A note cannot be empty.";
    pub const NOTE_LONG: &str = "A note can be at most 70 characters.";
    pub const DATE_FORMAT: &str = "Enter a date like 2026-02-01.";
    pub const DATE_RANGE: &str = "Enter a date between 2000 and 2100.";
    pub const TREND_RANGE: &str = "The trend must be a number from 1 to 24.";
    pub const CHOOSE_PERIOD: &str = "Choose a period.";
    pub const TOO_MANY_LINKS: &str = "Too many links requested. Try again later.";
}

fn fold(c: char) -> Option<char> {
    Some(match c {
        'à' | 'á' | 'â' | 'ã' | 'ä' | 'å' => 'a',
        'ç' => 'c',
        'è' | 'é' | 'ê' | 'ë' => 'e',
        'ì' | 'í' | 'î' | 'ï' => 'i',
        'ñ' => 'n',
        'ò' | 'ó' | 'ô' | 'õ' | 'ö' => 'o',
        'ù' | 'ú' | 'û' | 'ü' => 'u',
        'ý' | 'ÿ' => 'y',
        _ => return None,
    })
}

/// Lowercase ASCII letters and digits joined by single dashes. Never empty.
pub fn slug(s: &str) -> String {
    let mut out = String::new();
    let mut dash = false;
    for c in s.chars().flat_map(char::to_lowercase) {
        let c = fold(c).unwrap_or(c);
        if c.is_ascii_alphanumeric() {
            if dash && !out.is_empty() {
                out.push('-');
            }
            dash = false;
            out.push(c);
        } else {
            dash = true;
        }
    }
    out.truncate(40);
    while out.ends_with('-') {
        out.pop();
    }
    if out.is_empty() {
        "item".to_string()
    } else {
        out
    }
}

/// `base`, then `base-2`, `base-3` ... the first one not in `taken`.
pub fn unique_slug(base: &str, taken: &HashSet<String>) -> String {
    if !taken.contains(base) {
        return base.to_string();
    }
    (2..)
        .map(|n| format!("{base}-{n}"))
        .find(|c| !taken.contains(c))
        .unwrap_or_else(|| base.to_string())
}

/// Characters that show nothing or flip the reading direction. They would let two
/// names look the same, or a name look empty, so they are never accepted.
pub fn is_invisible(c: char) -> bool {
    matches!(c,
        '\u{00AD}' | '\u{034F}' | '\u{061C}' | '\u{115F}' | '\u{1160}' | '\u{17B4}' | '\u{17B5}'
        | '\u{180B}'..='\u{180F}' | '\u{200B}'..='\u{200F}' | '\u{2028}'..='\u{202E}'
        | '\u{2060}'..='\u{206F}' | '\u{3164}' | '\u{FE00}'..='\u{FE0F}' | '\u{FEFF}'
        | '\u{FFA0}' | '\u{FFF9}'..='\u{FFFB}' | '\u{E0000}'..='\u{E0FFF}')
}

/// Unicode space separators (category Zs): no-break space, ideographic space, en/em spaces ...
fn is_space_separator(c: char) -> bool {
    matches!(
        c,
        '\u{0020}' | '\u{00A0}' | '\u{1680}' | '\u{2000}'
            ..='\u{200A}' | '\u{202F}' | '\u{205F}' | '\u{3000}'
    )
}

/// Trim, turn every Unicode space separator into a plain space and collapse runs of spaces to
/// one, so "Ana  Rova" and "Ana\u{00A0}Rova" are the same name. Line breaks are left alone.
pub fn fold_spaces(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut prev_space = false;
    for c in s.trim().chars() {
        if is_space_separator(c) {
            if !prev_space {
                out.push(' ');
            }
            prev_space = true;
        } else {
            out.push(c);
            prev_space = false;
        }
    }
    out
}

/// Fold spaces, then require 1..=max characters on one line.
pub fn clean_line(s: &str, max: usize, empty: &str, long: &str) -> Result<String, ApiError> {
    let folded = fold_spaces(s);
    let t = folded.as_str();
    if t.is_empty() {
        return Err(ApiError::bad(empty));
    }
    if t.chars().count() > max {
        return Err(ApiError::bad(long));
    }
    if t.chars().any(|c| c.is_control() || is_invisible(c)) {
        return Err(ApiError::bad(msg::PLAIN_LINE));
    }
    Ok(t.to_string())
}

pub fn clean_team_name(s: &str) -> Result<String, ApiError> {
    clean_line(s, MAX_TEAM_NAME, msg::TEAM_EMPTY, msg::TEAM_LONG)
}

pub fn clean_person_name(s: &str) -> Result<String, ApiError> {
    clean_line(s, MAX_NAME, msg::NAME_EMPTY, msg::NAME_LONG)
}

pub fn clean_role_title(s: &str) -> Result<String, ApiError> {
    clean_line(
        s,
        MAX_ROLE_TITLE,
        msg::ROLE_TITLE_EMPTY,
        msg::ROLE_TITLE_LONG,
    )
}

/// Trimmed, lowercased, and shaped like name@domain.tld.
pub fn clean_email(s: &str) -> Result<String, ApiError> {
    let e = s.trim().to_lowercase();
    let bad = || ApiError::bad(msg::EMAIL_INVALID);
    if e.is_empty()
        || e.len() > EMAIL_MAX
        || e.chars().any(|c| {
            c.is_control()
                || c.is_whitespace()
                || is_invisible(c)
                || matches!(
                    c,
                    '<' | '>' | '(' | ')' | ',' | ';' | ':' | '\\' | '"' | '[' | ']'
                )
        })
    {
        return Err(bad());
    }
    let (local, domain) = e.split_once('@').ok_or_else(bad)?;
    let dotted = domain.contains('.')
        && !domain.starts_with('.')
        && !domain.ends_with('.')
        && !domain.contains("..");
    if local.is_empty() || local.len() > EMAIL_LOCAL_MAX || domain.contains('@') || !dotted {
        return Err(bad());
    }
    Ok(e)
}

pub fn clean_app_role(s: &str) -> Result<String, ApiError> {
    match s.trim() {
        r if APP_ROLES.contains(&r) => Ok(r.to_string()),
        _ => Err(ApiError::bad(msg::APP_ROLE_INVALID)),
    }
}

pub fn check_sort(n: i64) -> Result<i32, ApiError> {
    if (0..=i64::from(MAX_SORT)).contains(&n) {
        Ok(n as i32)
    } else {
        Err(ApiError::bad(msg::SORT_RANGE))
    }
}

/// One count or target as sent by the app. `id` is set when it already exists.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Entry {
    pub id: Option<Uuid>,
    pub text: String,
}

fn check_ids(entries: &[Entry], what: &str) -> Result<(), ApiError> {
    let mut seen = HashSet::new();
    for id in entries.iter().filter_map(|e| e.id) {
        if !seen.insert(id) {
            return Err(ApiError::bad(msg::LISTED_TWICE.replace("{what}", what)));
        }
    }
    Ok(())
}

/// 0..=8 counts, each named 1..=60 characters, names unique ignoring case.
pub fn check_metrics(raw: &[(Option<Uuid>, String)]) -> Result<Vec<Entry>, ApiError> {
    if raw.len() > MAX_METRICS {
        return Err(ApiError::bad(msg::METRICS_TOO_MANY));
    }
    let mut out = Vec::with_capacity(raw.len());
    let mut names = HashSet::new();
    for (id, label) in raw {
        let text = clean_line(label, MAX_LABEL, msg::METRIC_EMPTY, msg::METRIC_LONG)?;
        if !names.insert(text.to_lowercase()) {
            return Err(ApiError::bad(msg::METRIC_DUPLICATE));
        }
        out.push(Entry { id: *id, text });
    }
    check_ids(&out, "count")?;
    Ok(out)
}

/// 0..=10 targets, each 1..=200 characters.
pub fn check_kpis(raw: &[(Option<Uuid>, String)]) -> Result<Vec<Entry>, ApiError> {
    if raw.len() > MAX_KPIS {
        return Err(ApiError::bad(msg::KPIS_TOO_MANY));
    }
    let mut out = Vec::with_capacity(raw.len());
    for (id, text) in raw {
        let text = clean_line(text, MAX_KPI_TEXT, msg::KPI_EMPTY, msg::KPI_LONG)?;
        out.push(Entry { id: *id, text });
    }
    check_ids(&out, "target")?;
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn slugs_are_plain() {
        assert_eq!(slug("Antsirabe"), "antsirabe");
        assert_eq!(slug("  Déclarant export (Abe) "), "declarant-export-abe");
        assert_eq!(slug("Files / Calls!!"), "files-calls");
        assert_eq!(slug("!!!"), "item");
        assert_eq!(slug("日本"), "item");
        assert_eq!(slug("a".repeat(100).as_str()).len(), 40);
        assert!(!slug(&format!("{} b", "a".repeat(39))).ends_with('-'));
    }

    #[test]
    fn unique_slug_counts_up() {
        let mut taken = HashSet::new();
        assert_eq!(unique_slug("files", &taken), "files");
        taken.insert("files".to_string());
        assert_eq!(unique_slug("files", &taken), "files-2");
        taken.insert("files-2".to_string());
        assert_eq!(unique_slug("files", &taken), "files-3");
    }

    #[test]
    fn emails() {
        assert_eq!(
            clean_email("  Ana@Example.ORG ").unwrap(),
            "ana@example.org"
        );
        for bad in [
            "",
            "ana",
            "@x.org",
            "ana@",
            "ana@x",
            "ana@.org",
            "ana@x..org",
            "a b@x.org",
            "a@b@x.org",
            "<a@x.org>",
            "a,b@x.org",
            "a\u{200B}@x.org",
        ] {
            assert!(clean_email(bad).is_err(), "{bad}");
        }
        assert!(clean_email(&format!("{}@x.org", "a".repeat(65))).is_err());
    }

    #[test]
    fn lines_count_characters_not_bytes() {
        assert!(clean_line(&"é".repeat(60), 60, "e", "l").is_ok());
        assert!(clean_line(&"é".repeat(61), 60, "e", "l").is_err());
        assert!(clean_line("   ", 60, "e", "l").is_err());
        assert!(clean_line("a\nb", 60, "e", "l").is_err());
        assert_eq!(clean_line("  hi  ", 60, "e", "l").unwrap(), "hi");
        assert_eq!(
            clean_line("Ana\u{00A0}\u{3000} Rova\u{2003}", 60, "e", "l").unwrap(),
            "Ana Rova"
        );
        assert!(clean_line("\u{00A0}\u{3000}", 60, "e", "l").is_err());
        assert_eq!(fold_spaces(" a\u{2009}\u{2009}b\nc  d "), "a b\nc d");
    }

    #[test]
    fn roles() {
        assert!(clean_app_role("controller").is_ok());
        assert!(clean_app_role("contributor").is_ok());
        assert!(clean_app_role("admin").is_err());
    }

    fn m(labels: &[&str]) -> Vec<(Option<Uuid>, String)> {
        labels.iter().map(|l| (None, l.to_string())).collect()
    }

    #[test]
    fn metrics_rules() {
        assert_eq!(check_metrics(&m(&[])).unwrap().len(), 0);
        let ok = check_metrics(&m(&[" Files ", "Calls"])).unwrap();
        assert_eq!(ok[0].text, "Files");
        assert!(check_metrics(&m(&["a", "b", "c", "d", "e", "f", "g", "h"])).is_ok());
        assert!(check_metrics(&m(&["a", "b", "c", "d", "e", "f", "g", "h", "i"])).is_err());
        assert!(check_metrics(&m(&["Files", "files"])).is_err());
        assert!(check_metrics(&m(&["Files", " "])).is_err());
        assert!(check_metrics(&m(&[&"x".repeat(61)])).is_err());
        let id = Uuid::new_v4();
        let twice = vec![(Some(id), "a".to_string()), (Some(id), "b".to_string())];
        assert!(check_metrics(&twice).is_err());
    }

    #[test]
    fn kpi_rules() {
        let many: Vec<_> = (0..10).map(|i| (None, format!("t{i}"))).collect();
        assert!(check_kpis(&many).is_ok());
        let too_many: Vec<_> = (0..11).map(|i| (None, format!("t{i}"))).collect();
        assert!(check_kpis(&too_many).is_err());
        assert!(check_kpis(&[(None, "x".repeat(200))]).is_ok());
        assert!(check_kpis(&[(None, "x".repeat(201))]).is_err());
        assert!(check_kpis(&[(None, "  ".into())]).is_err());
        // Two targets may share wording.
        assert!(check_kpis(&[(None, "same".into()), (None, "same".into())]).is_ok());
    }

    const RULES_JSON: &str = include_str!("../tests/fixtures/rules.json");

    #[test]
    fn rules_json_matches_code() {
        let j: serde_json::Value = serde_json::from_str(RULES_JSON).unwrap();
        let l = &j["limits"];
        let expect: &[(&str, i64)] = &[
            ("person_name", MAX_NAME as i64),
            ("role_title", MAX_ROLE_TITLE as i64),
            ("reporter_name", REPORTER_MAX_CHARS as i64),
            ("reporter_country", REPORTER_MAX_CHARS as i64),
            ("reporter_role", REPORTER_MAX_CHARS as i64),
            ("team_name", MAX_TEAM_NAME as i64),
            ("metric_label", MAX_LABEL as i64),
            ("kpi_text", MAX_KPI_TEXT as i64),
            ("max_metrics", MAX_METRICS as i64),
            ("max_kpis", MAX_KPIS as i64),
            ("note_chars", NOTE_MAX_CHARS as i64),
            ("notes_per_kind", NOTES_PER_KIND as i64),
            ("comment_chars", COMMENT_MAX_CHARS as i64),
            ("value_min", VALUE_MIN),
            ("value_max", VALUE_MAX),
            ("email_chars", EMAIL_MAX as i64),
            ("email_local_chars", EMAIL_LOCAL_MAX as i64),
            ("sort_max", MAX_SORT as i64),
            ("period_min_year", PERIOD_MIN_YEAR as i64),
            ("period_max_year", PERIOD_MAX_YEAR as i64),
            ("months_per_period", MONTHS_PER_PERIOD as i64),
            ("trend_default", TREND_DEFAULT),
            ("trend_max", TREND_MAX),
            ("magic_links_per_hour", MAX_LINKS_PER_HOUR),
            ("magic_link_minutes", LINK_MINUTES as i64),
            ("max_body_bytes", MAX_BODY_BYTES as i64),
        ];
        for (k, v) in expect {
            assert_eq!(l[*k].as_i64(), Some(*v), "limit {k}");
        }
        assert_eq!(
            l.as_object().unwrap().len(),
            expect.len(),
            "extra limit in json"
        );
        let list = |v: &serde_json::Value| -> Vec<String> {
            v.as_array()
                .unwrap()
                .iter()
                .map(|x| x.as_str().unwrap().to_string())
                .collect()
        };
        assert_eq!(list(&j["enums"]["note_kinds"]), NOTE_KINDS);
        assert_eq!(list(&j["enums"]["kpi_statuses"]), KPI_STATUSES);
        assert_eq!(list(&j["enums"]["app_roles"]), APP_ROLES);
    }

    #[test]
    fn rules_json_messages_match_code_and_limits() {
        use super::msg::*;
        let j: serde_json::Value = serde_json::from_str(RULES_JSON).unwrap();
        let m = j["messages"].as_object().unwrap();
        let expect: &[(&str, &str)] = &[
            ("team_empty", TEAM_EMPTY),
            ("team_long", TEAM_LONG),
            ("name_empty", NAME_EMPTY),
            ("name_long", NAME_LONG),
            ("role_title_empty", ROLE_TITLE_EMPTY),
            ("role_title_long", ROLE_TITLE_LONG),
            ("plain_line", PLAIN_LINE),
            ("email_invalid", EMAIL_INVALID),
            ("app_role_invalid", APP_ROLE_INVALID),
            ("sort_range", SORT_RANGE),
            ("metrics_too_many", METRICS_TOO_MANY),
            ("metric_empty", METRIC_EMPTY),
            ("metric_long", METRIC_LONG),
            ("metric_duplicate", METRIC_DUPLICATE),
            ("kpis_too_many", KPIS_TOO_MANY),
            ("kpi_empty", KPI_EMPTY),
            ("kpi_long", KPI_LONG),
            ("listed_twice", LISTED_TWICE),
            ("reporter_empty", REPORTER_EMPTY),
            ("reporter_long", REPORTER_LONG),
            ("reporter_plain", REPORTER_PLAIN),
            ("value_not_yours", VALUE_NOT_YOURS),
            ("kpi_not_yours", KPI_NOT_YOURS),
            ("month_outside", MONTH_OUTSIDE),
            ("value_twice", VALUE_TWICE),
            ("kpi_twice", KPI_TWICE),
            ("kpi_status", KPI_STATUS),
            ("value_missing", VALUE_MISSING),
            ("value_too_big", VALUE_TOO_BIG),
            ("kpis_left", KPIS_LEFT),
            ("comment_long", COMMENT_LONG),
            ("nul_text", NUL_TEXT),
            ("note_box", NOTE_BOX),
            ("notes_too_many", NOTES_TOO_MANY),
            ("note_number", NOTE_NUMBER),
            ("note_same_number", NOTE_SAME_NUMBER),
            ("note_empty", NOTE_EMPTY),
            ("note_long", NOTE_LONG),
            ("date_format", DATE_FORMAT),
            ("date_range", DATE_RANGE),
            ("trend_range", TREND_RANGE),
            ("choose_period", CHOOSE_PERIOD),
            ("too_many_links", TOO_MANY_LINKS),
        ];
        for (k, v) in expect {
            assert_eq!(m[*k].as_str(), Some(*v), "message {k}");
        }
        assert_eq!(m.len(), expect.len(), "extra message in json");
        // The numbers written in the words are the limits.
        let has = |s: &str, n: i64| assert!(s.contains(&n.to_string()), "{s} should say {n}");
        has(TEAM_LONG, MAX_TEAM_NAME as i64);
        has(NAME_LONG, MAX_NAME as i64);
        has(ROLE_TITLE_LONG, MAX_ROLE_TITLE as i64);
        has(SORT_RANGE, MAX_SORT as i64);
        has(METRICS_TOO_MANY, MAX_METRICS as i64);
        has(METRIC_LONG, MAX_LABEL as i64);
        has(KPIS_TOO_MANY, MAX_KPIS as i64);
        has(KPI_LONG, MAX_KPI_TEXT as i64);
        has(REPORTER_LONG, REPORTER_MAX_CHARS as i64);
        has(VALUE_TOO_BIG, VALUE_MAX);
        has(COMMENT_LONG, COMMENT_MAX_CHARS as i64);
        has(NOTES_TOO_MANY, NOTES_PER_KIND as i64);
        has(NOTE_NUMBER, NOTES_PER_KIND as i64);
        has(NOTE_LONG, NOTE_MAX_CHARS as i64);
        has(DATE_RANGE, PERIOD_MIN_YEAR as i64);
        has(DATE_RANGE, PERIOD_MAX_YEAR as i64);
        has(TREND_RANGE, TREND_MAX);
    }

    #[test]
    fn rules_json_passwords_section_matches_code() {
        use crate::{loginlimit, password, username};
        let j: serde_json::Value = serde_json::from_str(RULES_JSON).unwrap();
        let p = &j["passwords"];
        let l = &p["limits"];
        let expect: &[(&str, i64)] = &[
            ("username_min", username::USERNAME_MIN as i64),
            ("username_max", username::USERNAME_MAX as i64),
            ("password_min", password::MIN_CHARS as i64),
            ("password_max", password::MAX_CHARS as i64),
            // Kept for older readers: the same number as the pair limit.
            (
                "login_failures_per_username",
                loginlimit::MAX_FAILURES_PER_PAIR,
            ),
            ("login_failures_per_pair", loginlimit::MAX_FAILURES_PER_PAIR),
            (
                "login_failures_per_username_backstop",
                loginlimit::MAX_FAILURES_PER_USER,
            ),
            (
                "login_failures_per_address",
                loginlimit::MAX_FAILURES_PER_IP,
            ),
            ("login_window_minutes", loginlimit::WINDOW_MINUTES),
            ("trusted_address_days", loginlimit::TRUSTED_DAYS),
            ("link_recovery_minutes", LINK_RECOVERY_MINUTES),
            (
                "events_recheck_seconds",
                crate::state::STREAM_RECHECK_SECS as i64,
            ),
            (
                "resets_per_manager_per_hour",
                loginlimit::MAX_RESETS_PER_HOUR,
            ),
            ("temporary_password_chars", 16),
            ("session_days", crate::auth::JWT_DAYS),
        ];
        for (k, v) in expect {
            assert_eq!(l[*k].as_i64(), Some(*v), "limit {k}");
        }
        assert_eq!(l.as_object().unwrap().len(), expect.len());
        assert_eq!(
            p["username_pattern"].as_str().unwrap(),
            format!(
                "^[a-z0-9._-]{{{},{}}}$",
                username::USERNAME_MIN,
                username::USERNAME_MAX
            )
        );
        assert_eq!(password::temporary().len(), 16);
        let m = p["messages"].as_object().unwrap();
        let msgs: &[(&str, &str)] = &[
            ("username_invalid", username::msg::INVALID),
            ("username_taken", username::msg::TAKEN),
            ("login_wrong", loginlimit::msg::WRONG),
            ("login_too_many", loginlimit::msg::TOO_MANY),
            ("busy", loginlimit::msg::BUSY),
            ("password_control", password::msg::CONTROL),
            ("password_short", password::msg::SHORT),
            ("password_long", password::msg::LONG),
            ("password_personal", password::msg::PERSONAL),
            ("password_repeated", password::msg::REPEATED),
            ("password_run", password::msg::RUN),
            ("password_common", password::msg::COMMON),
            ("password_new_required", password::msg::NEW_REQUIRED),
            ("password_current_required", password::msg::CURRENT_REQUIRED),
            ("password_current_wrong", password::msg::CURRENT_WRONG),
            ("password_same", password::msg::SAME),
            ("choose_new_password", crate::auth::CHOOSE_NEW_PASSWORD_MSG),
            ("sign_in_again", crate::auth::SIGN_IN_AGAIN_MSG),
            ("too_many_resets", loginlimit::msg::TOO_MANY_RESETS),
            ("switched_off", crate::signin::msg::SWITCHED_OFF),
            ("manager_only", "Only the manager can do this."),
        ];
        for (k, v) in msgs {
            assert_eq!(m[*k].as_str(), Some(*v), "message {k}");
        }
        assert_eq!(m.len(), msgs.len(), "extra message in json");
        let has = |s: &str, n: i64| assert!(s.contains(&n.to_string()), "{s} should say {n}");
        has(password::msg::SHORT, password::MIN_CHARS as i64);
        has(password::msg::LONG, password::MAX_CHARS as i64);
        has(username::msg::INVALID, username::USERNAME_MIN as i64);
        has(username::msg::INVALID, username::USERNAME_MAX as i64);
    }
}
