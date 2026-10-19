//! Signing in without a real email: internal addresses and one-time sign-in links.
//!
//! An internal address (name@xynotransit.internal) never receives mail. A manager, or the server
//! command `xynotransit-api sign-in-link`, creates a single-use link instead. The link is a normal
//! `login_token` row (only the SHA-256 of the token is stored) and goes through the same
//! `/api/auth/verify` exchange as a magic link; only its life is longer.

use chrono::{DateTime, SecondsFormat, Utc};
use sqlx::PgConnection;
use uuid::Uuid;

use crate::auth::{hash_token, random_token};

/// Hours a sign-in link may live: shortest and longest, and the default.
pub const LINK_HOURS_MIN: i64 = 1;
pub const LINK_HOURS_MAX: i64 = 168;
pub const LINK_HOURS_DEFAULT: i64 = 24;
/// Sign-in links one manager may create per hour.
pub const MAX_SIGN_IN_LINKS_PER_HOUR: i64 = 30;
/// Characters of the part before the @ in a generated address.
pub const GENERATED_LOCAL_MAX: usize = 40;

pub mod msg {
    pub const HOURS_INVALID: &str = "Choose a validity from 1 hour to 168 hours.";
    pub const TOO_MANY: &str = "Too many sign-in links created. Try again later.";
    pub const SWITCHED_OFF: &str = "This person is switched off.";
}

/// A letter with its accent taken off, or `None` when the character has no plain form.
fn fold_char(c: char) -> Option<&'static str> {
    let s = match c {
        'à' | 'á' | 'â' | 'ã' | 'ä' | 'å' | 'ā' | 'ă' | 'ą' | 'ǎ' => "a",
        'æ' | 'ǣ' => "ae",
        'ç' | 'ć' | 'ĉ' | 'ċ' | 'č' => "c",
        'ď' | 'đ' | 'ð' => "d",
        'è' | 'é' | 'ê' | 'ë' | 'ē' | 'ĕ' | 'ė' | 'ę' | 'ě' => "e",
        'ĝ' | 'ğ' | 'ġ' | 'ģ' => "g",
        'ĥ' | 'ħ' => "h",
        'ì' | 'í' | 'î' | 'ï' | 'ĩ' | 'ī' | 'ĭ' | 'į' | 'ı' | 'ǐ' => "i",
        'ĵ' => "j",
        'ķ' => "k",
        'ĺ' | 'ļ' | 'ľ' | 'ŀ' | 'ł' => "l",
        'ñ' | 'ń' | 'ņ' | 'ň' => "n",
        'ò' | 'ó' | 'ô' | 'õ' | 'ö' | 'ø' | 'ō' | 'ŏ' | 'ő' | 'ǒ' => "o",
        'œ' => "oe",
        'ŕ' | 'ŗ' | 'ř' => "r",
        'ś' | 'ŝ' | 'ş' | 'š' | 'ș' => "s",
        'ß' => "ss",
        'ţ' | 'ť' | 'ŧ' | 'ț' => "t",
        'þ' => "th",
        'ù' | 'ú' | 'û' | 'ü' | 'ũ' | 'ū' | 'ŭ' | 'ů' | 'ű' | 'ų' | 'ǔ' => "u",
        'ŵ' => "w",
        'ý' | 'ÿ' | 'ŷ' => "y",
        'ź' | 'ż' | 'ž' => "z",
        _ => return None,
    };
    Some(s)
}

/// The part before the @ of a generated internal address, made from a full name:
/// lowercase ASCII letters and digits with single dots between words, accents folded to plain
/// letters (ü to u, ß to ss), everything else dropped (apostrophes and hyphens too), at most
/// 40 characters. A name that leaves nothing (for example only CJK letters) gives "user".
/// Pure and shared in spirit with the Flutter demo repository, which follows the same rules.
pub fn internal_local_part(full_name: &str) -> String {
    let mut out = String::new();
    for c in full_name.chars().flat_map(char::to_lowercase) {
        if c.is_ascii_alphanumeric() {
            out.push(c);
        } else if c.is_whitespace() || c == '.' {
            out.push('.');
        } else if let Some(f) = fold_char(c) {
            out.push_str(f);
        }
        // Anything else (punctuation, symbols, other scripts) is dropped.
    }
    let mut collapsed = String::with_capacity(out.len());
    for c in out.chars() {
        if c == '.' && collapsed.ends_with('.') {
            continue;
        }
        collapsed.push(c);
    }
    let trimmed = collapsed.trim_matches('.');
    let cut: String = trimmed.chars().take(GENERATED_LOCAL_MAX).collect();
    let cut = cut.trim_end_matches('.');
    if cut.is_empty() {
        "user".into()
    } else {
        cut.to_string()
    }
}

/// The local part for attempt `n`: 1 is the plain one, 2 and up get the number appended
/// (rosa.rakoto, rosa.rakoto2, ...). The whole local part stays within 40 characters.
pub fn numbered_local_part(base: &str, n: u32) -> String {
    if n <= 1 {
        return base.to_string();
    }
    let suffix = n.to_string();
    let room = GENERATED_LOCAL_MAX.saturating_sub(suffix.len());
    let head: String = base.chars().take(room).collect();
    format!("{}{}", head.trim_end_matches('.'), suffix)
}

/// The first free generated address: `taken` holds the lowercase addresses in use.
pub fn first_free_internal_email(
    full_name: &str,
    domain: &str,
    taken: &std::collections::HashSet<String>,
) -> String {
    let base = internal_local_part(full_name);
    (1u32..)
        .map(|n| format!("{}@{}", numbered_local_part(&base, n), domain))
        .find(|e| !taken.contains(e))
        .expect("an endless range always has a free address")
}

/// Pick a free internal address for a new person. Callers hold a transaction and have taken the
/// advisory lock `xt_person_email`, so two requests cannot choose the same one.
pub async fn free_internal_email(
    conn: &mut PgConnection,
    full_name: &str,
    domain: &str,
) -> Result<String, sqlx::Error> {
    let base = internal_local_part(full_name);
    let like = format!("{base}%@{domain}");
    let rows: Vec<String> =
        sqlx::query_scalar("select lower(email) from person where lower(email) like $1")
            .bind(like)
            .fetch_all(&mut *conn)
            .await?;
    let taken = rows.into_iter().collect();
    Ok(first_free_internal_email(full_name, domain, &taken))
}

/// A link that was just created.
#[derive(Debug, Clone)]
pub struct SignInLink {
    pub url: String,
    pub expires_at: DateTime<Utc>,
    pub person_id: Uuid,
}

impl SignInLink {
    pub fn expires_at_rfc3339(&self) -> String {
        self.expires_at.to_rfc3339_opts(SecondsFormat::Secs, true)
    }
}

/// Create one single-use sign-in link and its audit row, inside the caller's transaction.
/// The person must exist (the caller checked that they are active). `issued_by` is the manager,
/// or `None` for the server command.
pub async fn create_sign_in_link(
    conn: &mut PgConnection,
    public_url: &str,
    person_id: Uuid,
    hours: i64,
    issued_by: Option<Uuid>,
) -> Result<SignInLink, sqlx::Error> {
    let token = random_token();
    let expires_at: DateTime<Utc> = sqlx::query_scalar(
        "insert into login_token (token_hash, person_id, expires_at)
         values ($1, $2, now() + make_interval(hours => $3::int))
         returning expires_at",
    )
    .bind(hash_token(&token))
    .bind(person_id)
    .bind(hours as i32)
    .fetch_one(&mut *conn)
    .await?;
    // The audit row never holds the token or its hash.
    sqlx::query(
        "insert into sign_in_link_audit (person_id, issued_by, expires_at) values ($1, $2, $3)",
    )
    .bind(person_id)
    .bind(issued_by)
    .bind(expires_at)
    .execute(&mut *conn)
    .await?;
    Ok(SignInLink {
        url: format!("{public_url}/auth/verify?token={token}"),
        expires_at,
        person_id,
    })
}

/// Why the server command could not make a link.
#[derive(Debug)]
pub enum CliError {
    Usage(String),
    NoSuchPerson(String),
    SwitchedOff(String),
    Database(String),
}

impl CliError {
    pub fn exit_code(&self) -> i32 {
        match self {
            CliError::Usage(_) => 2,
            _ => 1,
        }
    }
}

impl std::fmt::Display for CliError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            CliError::Usage(m) | CliError::Database(m) => f.write_str(m),
            CliError::NoSuchPerson(e) => write!(f, "No person has the email {e}."),
            CliError::SwitchedOff(e) => write!(f, "The person with the email {e} is switched off."),
        }
    }
}

pub const CLI_USAGE: &str =
    "Usage: xynotransit-api sign-in-link <email> [--hours N]  (N from 1 to 168, default 24)";

/// Arguments after `sign-in-link`: the email and the optional `--hours N` / `--hours=N`.
pub fn parse_cli_args(args: &[String]) -> Result<(String, i64), CliError> {
    let usage = |m: &str| CliError::Usage(format!("{m}\n{CLI_USAGE}"));
    let mut email: Option<String> = None;
    let mut hours = LINK_HOURS_DEFAULT;
    let mut it = args.iter();
    while let Some(a) = it.next() {
        let value = if a == "--hours" {
            Some(
                it.next()
                    .ok_or_else(|| usage("--hours needs a number."))?
                    .as_str(),
            )
        } else {
            a.strip_prefix("--hours=")
        };
        if let Some(v) = value {
            hours = v
                .trim()
                .parse::<i64>()
                .ok()
                .filter(|h| (LINK_HOURS_MIN..=LINK_HOURS_MAX).contains(h))
                .ok_or_else(|| usage(msg::HOURS_INVALID))?;
        } else if a.starts_with("--") {
            return Err(usage(&format!("Unknown option {a}.")));
        } else if email.is_none() {
            email = Some(a.trim().to_lowercase());
        } else {
            return Err(usage("Give one email address."));
        }
    }
    match email.filter(|e| !e.is_empty()) {
        Some(e) => Ok((e, hours)),
        None => Err(usage("Give the email address of the person.")),
    }
}

/// What the server command does: find the active person by email and create a link (audit
/// row with no issuer). Returns the link; the caller prints only its URL.
pub async fn sign_in_link_for_email(
    pool: &sqlx::PgPool,
    public_url: &str,
    email: &str,
    hours: i64,
) -> Result<SignInLink, CliError> {
    let db = |e: sqlx::Error| CliError::Database(format!("Database error: {e}"));
    let email = email.trim().to_lowercase();
    let mut tx = pool.begin().await.map_err(db)?;
    let person: Option<(Uuid, bool)> =
        sqlx::query_as("select id, active from person where lower(email) = $1")
            .bind(&email)
            .fetch_optional(&mut *tx)
            .await
            .map_err(db)?;
    let (id, active) = person.ok_or_else(|| CliError::NoSuchPerson(email.clone()))?;
    if !active {
        return Err(CliError::SwitchedOff(email));
    }
    let link = create_sign_in_link(&mut tx, public_url, id, hours, None)
        .await
        .map_err(db)?;
    tx.commit().await.map_err(db)?;
    Ok(link)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashSet;

    #[test]
    fn local_parts() {
        let long = "Maximilian Bartholomew Montgomery Featherstonehaugh";
        let cases: &[(&str, &str)] = &[
            ("Rosa Rakoto", "rosa.rakoto"),
            ("  Rosa   Rakoto  ", "rosa.rakoto"),
            ("ROSA RAKOTO", "rosa.rakoto"),
            ("José Müller", "jose.muller"),
            ("Zoë Åberg", "zoe.aberg"),
            ("Łukasz Dvořák", "lukasz.dvorak"),
            ("Straße Œuvre", "strasse.oeuvre"),
            ("Mireille N'Diaye", "mireille.ndiaye"),
            ("Mireille N\u{2019}Diaye", "mireille.ndiaye"),
            ("Anne-Marie Dupont", "annemarie.dupont"),
            ("Anne - Marie", "anne.marie"),
            ("Dr. J. R. R. Tolkien", "dr.j.r.r.tolkien"),
            ("a..b...c", "a.b.c"),
            (".leading and trailing.", "leading.and.trailing"),
            ("Agent 007", "agent.007"),
            ("Rosa_Rakoto!", "rosarakoto"),
            ("Tab\tand\nnewline", "tab.and.newline"),
            ("\u{ff32}osa", "osa"),
            ("田中太郎", "user"),
            ("田中 Taro", "taro"),
            ("", "user"),
            ("...", "user"),
            ("!?-'", "user"),
            ("😀 Rosa 😀", "rosa"),
            ("İstanbul", "istanbul"),
        ];
        for (name, want) in cases {
            assert_eq!(internal_local_part(name), *want, "{name:?}");
        }
        let l = internal_local_part(long);
        assert!(l.len() <= GENERATED_LOCAL_MAX, "{l}");
        assert_eq!(l, "maximilian.bartholomew.montgomery.feathe");
        // A cut that lands on a dot does not leave it dangling.
        let name = format!("{} z", "a".repeat(39));
        assert_eq!(internal_local_part(&name), "a".repeat(39));
        assert_eq!(internal_local_part(&"x".repeat(500)).len(), 40);
        for name in cases.iter().map(|c| c.0).chain([long]) {
            let l = internal_local_part(name);
            assert!(
                l.chars()
                    .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '.'),
                "{l}"
            );
            assert!(
                !l.starts_with('.') && !l.ends_with('.') && !l.contains(".."),
                "{l}"
            );
        }
    }

    #[test]
    fn numbering_and_collisions() {
        assert_eq!(numbered_local_part("rosa.rakoto", 1), "rosa.rakoto");
        assert_eq!(numbered_local_part("rosa.rakoto", 2), "rosa.rakoto2");
        assert_eq!(numbered_local_part("rosa.rakoto", 10), "rosa.rakoto10");
        let long = "a".repeat(40);
        let n = numbered_local_part(&long, 12);
        assert_eq!(n.len(), 40);
        assert!(n.ends_with("12"));
        // The cut never leaves a dot in front of the number.
        let base = format!("{}.b", "a".repeat(37));
        assert_eq!(
            numbered_local_part(&base, 2),
            format!("{}.b2", "a".repeat(37))
        );
        let base = format!("{}.bcd", "a".repeat(36));
        assert_eq!(
            numbered_local_part(&base, 11),
            format!("{}.b11", "a".repeat(36))
        );
        let base = format!("{}.bcd", "a".repeat(37));
        assert_eq!(
            numbered_local_part(&base, 123),
            format!("{}123", "a".repeat(37))
        );

        let d = "xynotransit.internal";
        let mut taken: HashSet<String> = HashSet::new();
        assert_eq!(
            first_free_internal_email("Rosa Rakoto", d, &taken),
            "rosa.rakoto@xynotransit.internal"
        );
        taken.insert("rosa.rakoto@xynotransit.internal".into());
        assert_eq!(
            first_free_internal_email("Rosa Rakoto", d, &taken),
            "rosa.rakoto2@xynotransit.internal"
        );
        taken.insert("rosa.rakoto2@xynotransit.internal".into());
        // A hole is filled before a higher number is used.
        taken.insert("rosa.rakoto4@xynotransit.internal".into());
        assert_eq!(
            first_free_internal_email("rosa  RAKOTO", d, &taken),
            "rosa.rakoto3@xynotransit.internal"
        );
        assert_eq!(
            first_free_internal_email("田中", d, &taken),
            "user@xynotransit.internal"
        );
    }

    #[test]
    fn cli_arguments() {
        let a = |v: &[&str]| v.iter().map(|s| s.to_string()).collect::<Vec<_>>();
        assert_eq!(
            parse_cli_args(&a(&["Boss@X.internal"])).unwrap(),
            ("boss@x.internal".into(), 24)
        );
        assert_eq!(
            parse_cli_args(&a(&["b@x.i", "--hours", "168"])).unwrap().1,
            168
        );
        assert_eq!(parse_cli_args(&a(&["--hours=1", "b@x.i"])).unwrap().1, 1);
        for bad in [
            &[][..],
            &["--hours", "3"],
            &["b@x.i", "--hours"],
            &["b@x.i", "--hours", "0"],
            &["b@x.i", "--hours", "169"],
            &["b@x.i", "--hours", "soon"],
            &["b@x.i", "c@x.i"],
            &["b@x.i", "--now"],
            &[" "],
        ] {
            let e = parse_cli_args(&a(bad)).unwrap_err();
            assert_eq!(e.exit_code(), 2, "{bad:?}");
            assert!(e.to_string().contains("Usage"), "{bad:?}");
        }
    }
}
