//! The words of a deck that a manager can change. Pure rules; the database part lives in
//! `routes::decks`. Keys, defaults, tokens and limits come from `deck_text_defaults.json`, the same
//! file the app reads (xynotransit_app/docs/reference/deck_text_defaults.json).

use std::sync::OnceLock;

use serde_json::{Map, Value};

use crate::rules::is_invisible;

pub const DEFAULTS_JSON: &str = include_str!("deck_text_defaults.json");

/// Names shown in messages. The app uses the same labels in its editor.
const LABELS: &[(&str, &str)] = &[
    ("title", "Meeting title"),
    ("subtitle", "Subtitle"),
    ("dateText", "Date line"),
    ("orgName", "Organisation name"),
    ("coverPill", "Team label on the cover"),
    ("kpiEyebrow", "KPI slide, small line"),
    ("kpiTitle", "KPI slide, title"),
    ("kpiBadge", "KPI slide, badge"),
    ("resultsEyebrow", "Results slide, small line"),
    ("resultsTitle", "Results slide, title"),
    ("highlightsTitle", "First column title"),
    ("lowlightsTitle", "Second column title"),
    ("nextTitle", "Third column title"),
    ("emptyNote", "Text for an empty column"),
    ("footer", "Footer"),
    ("dividerEyebrow", "Divider, small line"),
    ("dividerTitle", "Divider, title"),
    ("dividerSubtitle", "Divider, line under the title"),
    ("suggestionsTitle", "Page title"),
    ("suggestionsBody", "Page text"),
];

/// Only this field may hold line breaks.
const MULTILINE: &[&str] = &["suggestionsBody"];

#[derive(Debug, Clone)]
pub struct Field {
    pub key: String,
    pub label: String,
    pub default: String,
    pub tokens: Vec<String>,
    pub max_length: usize,
    pub can_be_empty: bool,
    pub multiline: bool,
}

pub fn fields() -> &'static [Field] {
    static FIELDS: OnceLock<Vec<Field>> = OnceLock::new();
    FIELDS.get_or_init(|| {
        let v: Value = serde_json::from_str(DEFAULTS_JSON).expect("deck text defaults are JSON");
        v["fields"]
            .as_array()
            .expect("fields array")
            .iter()
            .map(|f| {
                let key = f["key"].as_str().expect("key").to_string();
                let label = LABELS
                    .iter()
                    .find(|(k, _)| *k == key)
                    .unwrap_or_else(|| panic!("no label for deck text {key}"))
                    .1
                    .to_string();
                Field {
                    multiline: MULTILINE.contains(&key.as_str()),
                    label,
                    default: f["default"].as_str().expect("default").to_string(),
                    tokens: f["tokens"]
                        .as_array()
                        .expect("tokens")
                        .iter()
                        .map(|t| t.as_str().expect("token").to_string())
                        .collect(),
                    max_length: f["max_length"].as_u64().expect("max_length") as usize,
                    can_be_empty: f["can_be_empty"].as_bool().expect("can_be_empty"),
                    key,
                }
            })
            .collect()
    })
}

pub fn field(key: &str) -> Option<&'static Field> {
    fields().iter().find(|f| f.key == key)
}

/// Every key with its built-in words.
pub fn defaults() -> Map<String, Value> {
    fields()
        .iter()
        .map(|f| (f.key.clone(), Value::String(f.default.clone())))
        .collect()
}

/// `stored` completed with the defaults: missing, unknown or non-text entries are dropped.
pub fn complete(stored: &Value) -> Map<String, Value> {
    fields()
        .iter()
        .map(|f| {
            let v = stored
                .get(&f.key)
                .and_then(Value::as_str)
                .unwrap_or(&f.default);
            (f.key.clone(), Value::String(v.to_string()))
        })
        .collect()
}

/// Placeholder names in `s`, in order of first use. A placeholder is `{letters}`.
pub fn tokens_in(s: &str) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    let mut rest = s;
    while let Some(i) = rest.find('{') {
        let after = &rest[i + 1..];
        match after.find('}') {
            Some(j) if j > 0 && after[..j].chars().all(|c| c.is_ascii_alphabetic()) => {
                let t = after[..j].to_string();
                if !out.contains(&t) {
                    out.push(t);
                }
                rest = &after[j + 1..];
            }
            _ => rest = after,
        }
    }
    out
}

/// Trim and check one value. Plain-words message on failure.
pub fn check(field: &Field, value: &str) -> Result<String, String> {
    // Line breaks are stored as plain line feeds, so a CR never reaches a slide.
    let normalised;
    let value = if field.multiline && value.contains('\r') {
        normalised = value.replace("\r\n", "\n").replace('\r', "\n");
        normalised.as_str()
    } else {
        value
    };
    let folded = crate::rules::fold_spaces(value);
    let v = folded.as_str();
    if v.is_empty() && !field.can_be_empty {
        return Err(format!("{} cannot be empty.", field.label));
    }
    if v.chars().count() > field.max_length {
        return Err(format!(
            "{} can be at most {} characters.",
            field.label, field.max_length
        ));
    }
    let bad = |c: char| {
        is_invisible(c) || (c.is_control() && !(field.multiline && (c == '\n' || c == '\r')))
    };
    if v.chars().any(bad) {
        return Err(format!("Use plain text in {}.", field.label));
    }
    for t in tokens_in(v) {
        if !field.tokens.contains(&t) {
            let allowed = if field.tokens.is_empty() {
                "no placeholders".to_string()
            } else {
                field
                    .tokens
                    .iter()
                    .map(|x| format!("{{{x}}}"))
                    .collect::<Vec<_>>()
                    .join(", ")
            };
            return Err(format!(
                "{{{t}}} cannot be used in {}. It allows {allowed}.",
                field.label
            ));
        }
    }
    Ok(v.to_string())
}

/// Check a whole `settings` object from a request. Missing keys take the defaults.
/// Unknown keys and non-text values are errors.
pub fn check_all(input: &Map<String, Value>) -> Result<Map<String, Value>, String> {
    if let Some(k) = input.keys().find(|k| field(k).is_none()) {
        return Err(format!("{k} is not a text setting."));
    }
    let mut out = Map::new();
    for f in fields() {
        let v = match input.get(&f.key) {
            None => f.default.clone(),
            Some(Value::String(s)) => check(f, s)?,
            Some(_) => return Err(format!("{} must be text.", f.label)),
        };
        out.insert(f.key.clone(), Value::String(v));
    }
    Ok(out)
}

const MONTHS: [&str; 12] = [
    "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
];

/// "Feb to Apr 2026", or "Nov 2026 to Jan 2027" across a year end. Same as the app.
pub fn period_label(year: i32, month: u32) -> String {
    let m0 = month as i32 - 1;
    let last = m0 + 2;
    let (ly, lm) = (year + last / 12, (last % 12) as usize);
    let a = MONTHS[m0 as usize];
    let b = MONTHS[lm];
    if ly == year {
        format!("{a} to {b} {ly}")
    } else {
        format!("{a} {year} to {b} {ly}")
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn f(key: &str) -> &'static Field {
        field(key).unwrap()
    }

    #[test]
    fn every_field_has_a_label_and_valid_default() {
        assert_eq!(fields().len(), 20);
        for fl in fields() {
            assert_eq!(
                check(fl, &fl.default).as_deref(),
                Ok(fl.default.as_str()),
                "{}",
                fl.key
            );
        }
    }

    #[test]
    fn table_of_checks() {
        let cases: Vec<(&str, String, Result<String, &str>)> =
            vec![
            (
                "title",
                "  Q2 Review {period}  ".into(),
                Ok("Q2 Review {period}".to_string()),
            ),
            ("title", "   ".into(), Err("Meeting title cannot be empty.")),
            ("dateText", "".into(), Ok("".to_string())),
            ("dateText", "  ".into(), Ok("".to_string())),
            ("suggestionsBody", "".into(), Ok("".to_string())),
            ("title", "x".repeat(80), Ok("x".repeat(80))),
            (
                "title",
                "x".repeat(81),
                Err("Meeting title can be at most 80 characters."),
            ),
            // characters, not bytes: 80 multi-byte letters are fine
            ("title", "é".repeat(80), Ok("é".repeat(80))),
            (
                "title",
                "é".repeat(81),
                Err("Meeting title can be at most 80 characters."),
            ),
            ("title", "😀".repeat(80), Ok("😀".repeat(80))),
            (
                "title",
                "😀".repeat(81),
                Err("Meeting title can be at most 80 characters."),
            ),
            (
                "title",
                "{name} review".into(),
                Err("{name} cannot be used in Meeting title. It allows {period}."),
            ),
            (
                "orgName",
                "{org}".into(),
                Err("{org} cannot be used in Organisation name. It allows no placeholders."),
            ),
            ("coverPill", "{count} {team}".into(), Ok("{count} {team}".to_string())),
            (
                "coverPill",
                "{team} {met}".into(),
                Err("{met} cannot be used in Team label on the cover. It allows {team}, {count}."),
            ),
            (
                "coverPill",
                "{Team}".into(),
                Err("{Team} cannot be used in Team label on the cover. It allows {team}, {count}."),
            ),
            (
                "dividerSubtitle",
                "{k} {reports} of {team}".into(),
                Ok("{k} {reports} of {team}".to_string()),
            ),
            (
                "kpiBadge",
                "{met}/{total} {i}".into(),
                Err("{i} cannot be used in KPI slide, badge. It allows {met}, {total}."),
            ),
            (
                "footer",
                "{ not a token } and {1}".into(),
                Ok("{ not a token } and {1}".to_string()),
            ),
            (
                "title",
                "a\u{200b}b".into(),
                Err("Use plain text in Meeting title."),
            ),
            (
                "title",
                "a\u{202e}b".into(),
                Err("Use plain text in Meeting title."),
            ),
            (
                "title",
                "a\nb".into(),
                Err("Use plain text in Meeting title."),
            ),
            (
                "title",
                "a\u{0}b".into(),
                Err("Use plain text in Meeting title."),
            ),
            ("suggestionsBody", "a\nb".into(), Ok("a\nb".to_string())),
            (
                "suggestionsBody",
                "a\u{7}b".into(),
                Err("Use plain text in Page text."),
            ),
            (
                "suggestionsBody",
                "x".repeat(401),
                Err("Page text can be at most 400 characters."),
            ),
        ];
        for (key, value, want) in cases {
            let got = check(f(key), &value);
            let got = got.map_err(|e| e.leak() as &str);
            assert_eq!(got, want, "{key}: {value:?}");
        }
    }

    #[test]
    fn whole_object_rules() {
        let none = Map::new();
        let all = check_all(&none).unwrap();
        assert_eq!(all, defaults());

        let mut m = Map::new();
        m.insert("title".into(), json!(" New "));
        let all = check_all(&m).unwrap();
        assert_eq!(all["title"], "New");
        assert_eq!(all["footer"], f("footer").default.as_str());

        let mut m = Map::new();
        m.insert("nope".into(), json!("x"));
        assert_eq!(check_all(&m).unwrap_err(), "nope is not a text setting.");

        let mut m = Map::new();
        m.insert("title".into(), json!(5));
        assert_eq!(check_all(&m).unwrap_err(), "Meeting title must be text.");
    }

    #[test]
    fn complete_fills_gaps() {
        let c = complete(&json!({"title": "A", "footer": 3, "zzz": "x"}));
        assert_eq!(c.len(), 20);
        assert_eq!(c["title"], "A");
        assert_eq!(c["footer"], f("footer").default.as_str());
        assert_eq!(complete(&json!({})), defaults());
    }

    #[test]
    fn tokens_are_found_in_order() {
        assert_eq!(tokens_in("{b} {a} {b} {} {a1}"), vec!["b", "a"]);
        assert!(tokens_in("{{x}").contains(&"x".to_string()));
    }

    #[test]
    fn labels() {
        assert_eq!(period_label(2026, 2), "Feb to Apr 2026");
        assert_eq!(period_label(2026, 11), "Nov 2026 to Jan 2027");
        assert_eq!(period_label(2026, 10), "Oct to Dec 2026");
    }

    #[test]
    fn copies_of_the_defaults_agree() {
        let own = include_str!("../tests/fixtures/deck_text_defaults.json");
        assert_eq!(DEFAULTS_JSON, own, "src and tests/fixtures copies differ");
        let app = concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../xynotransit_app/docs/reference/deck_text_defaults.json"
        );
        match std::fs::read(app) {
            Ok(bytes) => assert_eq!(
                bytes,
                DEFAULTS_JSON.as_bytes(),
                "copy the file from {app} into src/ and tests/fixtures/"
            ),
            Err(_) => eprintln!("SKIPPED: the Flutter project is not next to the API ({app})"),
        }
    }
}
