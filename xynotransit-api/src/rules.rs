//! Pure rules for the things a manager types: names, emails, slugs, counts and targets.
//! Every message is plain words, the same style as `validate`.

use std::collections::HashSet;

use uuid::Uuid;

use crate::error::ApiError;

pub const MAX_METRICS: usize = 8;
pub const MAX_KPIS: usize = 10;
pub const MAX_LABEL: usize = 60;
pub const MAX_KPI_TEXT: usize = 200;
pub const MAX_ROLE_TITLE: usize = 80;
pub const MAX_NAME: usize = 80;
pub const MAX_TEAM_NAME: usize = 60;
pub const MAX_SORT: i32 = 10_000;

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

/// Trim, then require 1..=max characters on one line.
pub fn clean_line(s: &str, max: usize, empty: &str, long: &str) -> Result<String, ApiError> {
    let t = s.trim();
    if t.is_empty() {
        return Err(ApiError::bad(empty));
    }
    if t.chars().count() > max {
        return Err(ApiError::bad(long));
    }
    if t.chars().any(|c| c.is_control() || is_invisible(c)) {
        return Err(ApiError::bad("Use plain text on one line."));
    }
    Ok(t.to_string())
}

pub fn clean_team_name(s: &str) -> Result<String, ApiError> {
    clean_line(
        s,
        MAX_TEAM_NAME,
        "Enter a team name.",
        "A team name can have at most 60 characters.",
    )
}

pub fn clean_person_name(s: &str) -> Result<String, ApiError> {
    clean_line(
        s,
        MAX_NAME,
        "Enter a name.",
        "A name can have at most 80 characters.",
    )
}

pub fn clean_role_title(s: &str) -> Result<String, ApiError> {
    clean_line(
        s,
        MAX_ROLE_TITLE,
        "Enter a role title.",
        "A role title can have at most 80 characters.",
    )
}

/// Trimmed, lowercased, and shaped like name@domain.tld.
pub fn clean_email(s: &str) -> Result<String, ApiError> {
    let e = s.trim().to_lowercase();
    let bad = || ApiError::bad("Enter a valid email address.");
    if e.is_empty()
        || e.len() > 254
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
    if local.is_empty() || local.len() > 64 || domain.contains('@') || !dotted {
        return Err(bad());
    }
    Ok(e)
}

pub fn clean_app_role(s: &str) -> Result<String, ApiError> {
    match s.trim() {
        r @ ("contributor" | "controller") => Ok(r.to_string()),
        _ => Err(ApiError::bad("Choose employee or manager.")),
    }
}

pub fn check_sort(n: i64) -> Result<i32, ApiError> {
    if (0..=i64::from(MAX_SORT)).contains(&n) {
        Ok(n as i32)
    } else {
        Err(ApiError::bad("Enter an order between 0 and 10000."))
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
            return Err(ApiError::bad(format!("The same {what} is listed twice.")));
        }
    }
    Ok(())
}

/// 0..=8 counts, each named 1..=60 characters, names unique ignoring case.
pub fn check_metrics(raw: &[(Option<Uuid>, String)]) -> Result<Vec<Entry>, ApiError> {
    if raw.len() > MAX_METRICS {
        return Err(ApiError::bad("A seat can have at most 8 counts."));
    }
    let mut out = Vec::with_capacity(raw.len());
    let mut names = HashSet::new();
    for (id, label) in raw {
        let text = clean_line(
            label,
            MAX_LABEL,
            "Give every count a name.",
            "A count name can have at most 60 characters.",
        )?;
        if !names.insert(text.to_lowercase()) {
            return Err(ApiError::bad(
                "Two counts have the same name. Give each count its own name.",
            ));
        }
        out.push(Entry { id: *id, text });
    }
    check_ids(&out, "count")?;
    Ok(out)
}

/// 0..=10 targets, each 1..=200 characters.
pub fn check_kpis(raw: &[(Option<Uuid>, String)]) -> Result<Vec<Entry>, ApiError> {
    if raw.len() > MAX_KPIS {
        return Err(ApiError::bad("A seat can have at most 10 targets."));
    }
    let mut out = Vec::with_capacity(raw.len());
    for (id, text) in raw {
        let text = clean_line(
            text,
            MAX_KPI_TEXT,
            "Write every target in words.",
            "A target can have at most 200 characters.",
        )?;
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
}
