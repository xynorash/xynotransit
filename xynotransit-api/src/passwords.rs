//! Storing, replacing and removing passwords, and the `set-password` server command.
//! Never a password or a hash in a log line, an error or the audit table.

use sqlx::PgConnection;
use uuid::Uuid;

use crate::{
    hashing::{HashError, Hasher},
    password::{self, Subject},
};

/// Set (`Some(hash)`) or remove (`None`) a person's password in the caller's transaction.
/// Adds 1 to the session epoch, so every older session ends, and writes the audit row.
/// Returns the new epoch, or `None` when the person does not exist.
/// `kind` is change, reset, remove or cli; `issued_by` is the manager for reset and remove.
pub async fn store_password(
    conn: &mut PgConnection,
    person_id: Uuid,
    hash: Option<&str>,
    must_change: bool,
    kind: &str,
    issued_by: Option<Uuid>,
) -> Result<Option<i32>, sqlx::Error> {
    let epoch: Option<i32> = sqlx::query_scalar(
        "update person set password_hash = $2, must_change_password = $3,
                session_epoch = session_epoch + 1, password_changed_at = now()
         where id = $1 returning session_epoch",
    )
    .bind(person_id)
    .bind(hash)
    .bind(must_change)
    .fetch_optional(&mut *conn)
    .await?;
    if epoch.is_some() {
        sqlx::query("insert into password_audit (person_id, issued_by, kind) values ($1, $2, $3)")
            .bind(person_id)
            .bind(issued_by)
            .bind(kind)
            .execute(&mut *conn)
            .await?;
    }
    Ok(epoch)
}

/// Why `set-password` could not finish.
#[derive(Debug)]
pub enum CliError {
    Usage(String),
    NoSuchPerson(String),
    SwitchedOff(String),
    /// The new password breaks the policy (the plain message), or the two typed ones differ.
    Rejected(String),
    Busy,
    Database(String),
}

impl CliError {
    /// 2 for wrong usage, 1 for everything else that stops it.
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
            CliError::Usage(m) | CliError::Rejected(m) | CliError::Database(m) => f.write_str(m),
            CliError::NoSuchPerson(i) => write!(f, "No person has the username or email {i}."),
            CliError::SwitchedOff(i) => write!(f, "The person {i} is switched off."),
            CliError::Busy => f.write_str("The machine is busy. Try again in a moment."),
        }
    }
}

pub const CLI_USAGE: &str =
    "Usage: xynotransit-api set-password <username-or-email>  (the new password is read from standard input)";

/// Arguments after `set-password`: exactly one username or email.
pub fn parse_cli_args(args: &[String]) -> Result<String, CliError> {
    let usage = |m: &str| CliError::Usage(format!("{m}\n{CLI_USAGE}"));
    let mut who: Option<String> = None;
    for a in args {
        if a.starts_with("--") {
            return Err(usage(&format!("Unknown option {a}.")));
        } else if who.is_none() {
            who = Some(a.trim().to_lowercase());
        } else {
            return Err(usage("Give one username or email address."));
        }
    }
    who.filter(|w| !w.is_empty())
        .ok_or_else(|| usage("Give the username or email address of the person."))
}

/// A person found for the command.
#[derive(Debug, Clone)]
pub struct CliPerson {
    pub id: Uuid,
    pub username: String,
    pub email: String,
    pub full_name: String,
}

/// Find the active person by username or by email (no username holds an @, so there is no mix-up).
pub async fn find_person(pool: &sqlx::PgPool, who: &str) -> Result<CliPerson, CliError> {
    let db = |e: sqlx::Error| CliError::Database(format!("Database error: {e}"));
    let who = who.trim().to_lowercase();
    let row: Option<(Uuid, String, Option<String>, String, bool)> = sqlx::query_as(
        "select id, username, email, full_name, active from person
         where lower(username) = $1 or lower(email) = $1",
    )
    .bind(&who)
    .fetch_optional(pool)
    .await
    .map_err(db)?;
    let (id, username, email, full_name, active) =
        row.ok_or_else(|| CliError::NoSuchPerson(who.clone()))?;
    if !active {
        return Err(CliError::SwitchedOff(who));
    }
    Ok(CliPerson {
        id,
        username,
        email: email.unwrap_or_default(),
        full_name,
    })
}

/// Check the policy, hash and store the password the way `POST /api/auth/password` does, with
/// audit kind `cli`. The person is no longer asked to change it.
pub async fn set_password_for(
    pool: &sqlx::PgPool,
    hasher: &Hasher,
    person: &CliPerson,
    new_password: &str,
) -> Result<(), CliError> {
    let db = |e: sqlx::Error| CliError::Database(format!("Database error: {e}"));
    password::check(
        new_password,
        Subject {
            username: &person.username,
            email: &person.email,
            full_name: &person.full_name,
        },
    )
    .map_err(|m| CliError::Rejected(m.to_string()))?;
    let hash = hasher.hash(new_password).await.map_err(|e| match e {
        HashError::Busy => CliError::Busy,
        HashError::Failed => CliError::Database("Could not hash the password.".into()),
    })?;
    let mut tx = pool.begin().await.map_err(db)?;
    let done = store_password(&mut tx, person.id, Some(&hash), false, "cli", None)
        .await
        .map_err(db)?;
    if done.is_none() {
        return Err(CliError::NoSuchPerson(person.username.clone()));
    }
    tx.commit().await.map_err(db)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn a(v: &[&str]) -> Vec<String> {
        v.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn cli_arguments() {
        assert_eq!(parse_cli_args(&a(&["Manager"])).unwrap(), "manager");
        assert_eq!(parse_cli_args(&a(&[" A@B.org "])).unwrap(), "a@b.org");
        for bad in [&[][..], &["x", "y"], &["--force"], &["  "]] {
            let e = parse_cli_args(&a(bad)).unwrap_err();
            assert_eq!(e.exit_code(), 2, "{bad:?}");
            assert!(e.to_string().contains("Usage:"));
        }
        assert_eq!(CliError::NoSuchPerson("x".into()).exit_code(), 1);
        assert_eq!(CliError::Rejected("x".into()).exit_code(), 1);
    }
}
