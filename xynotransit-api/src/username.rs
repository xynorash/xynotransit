//! Usernames: the rules, and the default for a new person. Pure, no database.
//!
//! A username is lowercase letters, digits, dot, dash and underscore, 3 to 40 characters, unique
//! ignoring case, stored lowercase. A new person gets the part of the email before the @, cleaned
//! to those characters and numbered on conflict (rosa.rakoto, rosa.rakoto2). The SQL function
//! `xt_make_username` (initdb/12-passwords.sql) does the same for the backfill and for inserts
//! that carry no username; a test keeps the two in step for the characters SQL folds.

use std::collections::HashSet;

use sqlx::PgConnection;

pub const USERNAME_MIN: usize = 3;
pub const USERNAME_MAX: usize = 40;

pub mod msg {
    pub const INVALID: &str =
        "Usernames use letters, digits, dots, dashes and underscores, 3 to 40 characters.";
    pub const TAKEN: &str = "That username is already used.";
}

fn allowed(c: char) -> bool {
    c.is_ascii_lowercase() || c.is_ascii_digit() || matches!(c, '.' | '-' | '_')
}

/// What a manager typed, made into the stored form (trimmed, lowercase) when it is a valid
/// username. Uppercase letters are accepted and lowered; anything else outside the set is not.
pub fn clean(raw: &str) -> Result<String, &'static str> {
    let s = raw.trim().to_lowercase();
    let n = s.chars().count();
    if (USERNAME_MIN..=USERNAME_MAX).contains(&n) && s.chars().all(allowed) {
        Ok(s)
    } else {
        Err(msg::INVALID)
    }
}

/// The key the sign-in limits and the lookup use for whatever was typed: trimmed, lowercase, cut
/// to 64 characters (a longer text cannot be a username anyway).
pub fn lookup_key(raw: &str) -> String {
    // Postgres cannot store a NUL (or anything the app would never accept), so such characters
    // become U+FFFD: the key still differs from every real username and nothing is mistaken
    // for another name.
    raw.trim()
        .to_lowercase()
        .chars()
        .take(64)
        .map(|c| if c.is_control() { '\u{fffd}' } else { c })
        .collect()
}

/// A username base from an email (or any text): the part before the @.
pub fn base_from_email(email: &str) -> String {
    let local = email.split('@').next().unwrap_or("");
    let mut s = String::new();
    for c in local.chars().flat_map(char::to_lowercase) {
        if allowed(c) {
            s.push(c);
        } else if let Some(f) = crate::signin::fold_char(c) {
            s.push_str(f);
        }
    }
    let s = s.trim_matches('.');
    let cut: String = s.chars().take(USERNAME_MAX).collect();
    let cut = cut.trim_matches('.');
    if cut.is_empty() {
        "user".into()
    } else if cut.chars().count() < USERNAME_MIN {
        format!("user.{cut}")
    } else {
        cut.to_string()
    }
}

/// Attempt `n` for a base: 1 is the base, 2 and up get the number appended, within 40 characters.
pub fn numbered(base: &str, n: u32) -> String {
    if n <= 1 {
        return base.to_string();
    }
    let suffix = n.to_string();
    let head: String = base
        .chars()
        .take(USERNAME_MAX.saturating_sub(suffix.len()))
        .collect();
    format!("{}{}", head.trim_end_matches('.'), suffix)
}

/// The first free username for an email; `taken` holds lowercase usernames in use.
pub fn first_free(email: &str, taken: &HashSet<String>) -> String {
    let base = base_from_email(email);
    (1u32..)
        .map(|n| numbered(&base, n))
        .find(|u| !taken.contains(u))
        .expect("an endless range always has a free name")
}

/// Pick a free username for a new person. The caller holds a transaction and the advisory lock
/// `xt_username`, so two requests cannot choose the same one.
pub async fn free_username(conn: &mut PgConnection, email: &str) -> Result<String, sqlx::Error> {
    let base = base_from_email(email);
    let like = format!("{}%", base.replace('_', "\\_").replace('%', "\\%"));
    let rows: Vec<String> =
        sqlx::query_scalar("select lower(username) from person where lower(username) like $1")
            .bind(like)
            .fetch_all(&mut *conn)
            .await?;
    Ok(first_free(email, &rows.into_iter().collect()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn clean_accepts_and_rejects() {
        let ok = [
            ("rosa", None),
            ("rosa.rakoto", Some("rosa.rakoto")),
            ("  Rosa.Rakoto  ", Some("rosa.rakoto")),
            ("a-b_c.d9", Some("a-b_c.d9")),
            ("abc", Some("abc")),
        ];
        for (raw, want) in ok {
            match want {
                Some(w) => assert_eq!(clean(raw).as_deref(), Ok(w), "{raw:?}"),
                None => assert!(clean(raw).is_ok()),
            }
        }
        let long40 = "x".repeat(40);
        assert_eq!(clean(&long40).as_deref(), Ok(long40.as_str()));
        let bad = [
            "",
            "ab",
            "  ab  ",
            "x y z",
            "rosa@x.org",
            "rosa!",
            "été",
            "名前名前",
            "a\tb\tc",
            "ro\nsa",
            "ro sa",
        ];
        for raw in bad {
            assert_eq!(clean(raw), Err(msg::INVALID), "{raw:?}");
        }
        assert_eq!(clean(&"x".repeat(41)), Err(msg::INVALID));
        // Length counts characters, not bytes.
        assert_eq!(clean("éé"), Err(msg::INVALID));
    }

    #[test]
    fn bases_from_emails() {
        let cases = [
            ("rosa.rakoto@x.org", "rosa.rakoto"),
            ("Rosa.Rakoto@X.org", "rosa.rakoto"),
            ("rosa+news@x.org", "rosanews"),
            ("josé.müller@x.org", "jose.muller"),
            ("ab@x.org", "user.ab"),
            ("a@x.org", "user.a"),
            ("@x.org", "user"),
            ("...@x.org", "user"),
            (".rosa.@x.org", "rosa"),
            ("名前@x.org", "user"),
            ("a_b-c@x.org", "a_b-c"),
            ("-@x.org", "user.-"),
            ("noat", "noat"),
        ];
        for (email, want) in cases {
            assert_eq!(base_from_email(email), want, "{email}");
            assert!(clean(&base_from_email(email)).is_ok(), "{email}");
        }
        let long = format!("{}@x.org", "a".repeat(100));
        assert_eq!(base_from_email(&long).len(), 40);
        let dotted = format!("{}.b@x.org", "a".repeat(39));
        assert_eq!(base_from_email(&dotted), "a".repeat(39));
    }

    #[test]
    fn numbering_on_conflict() {
        let mut taken: HashSet<String> = HashSet::new();
        for want in ["rosa.rakoto", "rosa.rakoto2", "rosa.rakoto3"] {
            let u = first_free("rosa.rakoto@x.org", &taken);
            assert_eq!(u, want);
            taken.insert(u);
        }
        // A hole is filled.
        taken.remove("rosa.rakoto2");
        assert_eq!(first_free("rosa.rakoto@y.org", &taken), "rosa.rakoto2");
        // Always within 40 characters, even with a long base.
        let email = format!("{}@x.org", "b".repeat(60));
        let mut taken = HashSet::new();
        for _ in 0..12 {
            let u = first_free(&email, &taken);
            assert!(clean(&u).is_ok(), "{u}");
            assert!(taken.insert(u));
        }
        assert_eq!(numbered("abc", 1), "abc");
        assert_eq!(numbered("abc.", 2), "abc2");
    }

    #[test]
    fn lookup_keys() {
        assert_eq!(lookup_key("  Rosa.Rakoto "), "rosa.rakoto");
        assert_eq!(lookup_key(&"X".repeat(500)).len(), 64);
    }
}
