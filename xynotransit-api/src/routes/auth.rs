use axum::{extract::State, http::StatusCode, routing::post, Json, Router};
use chrono::SecondsFormat;
use serde::Deserialize;
use serde_json::{json, Value};
use uuid::Uuid;

use crate::{
    auth::{hash_token, issue_jwt_via, random_token, Role, SessionUser, Via, SIGN_IN_AGAIN_MSG},
    error::{ApiError, ApiJson},
    loginlimit::{self, msg as limit_msg, ClientAddr, Kind, Who},
    password::{self, msg as pw_msg, Subject},
    passwords,
    state::AppState,
};

pub fn router() -> Router<AppState> {
    Router::new()
        .route("/auth/magic-link", post(magic_link))
        .route("/auth/verify", post(verify))
        .route("/auth/login", post(login))
        .route("/auth/password", post(change_password))
}

pub use crate::rules::MAX_LINKS_PER_HOUR;
use crate::rules::{EMAIL_MAX, LINK_MINUTES};

#[derive(Deserialize)]
struct MagicLinkBody {
    email: String,
}

async fn magic_link(
    State(st): State<AppState>,
    ApiJson(body): ApiJson<MagicLinkBody>,
) -> Result<(StatusCode, Json<Value>), ApiError> {
    let email = body.email.trim().to_lowercase();
    if email.len() > EMAIL_MAX || !email.contains('@') || email.chars().any(char::is_control) {
        return Err(ApiError::bad(crate::rules::msg::EMAIL_INVALID));
    }

    // The limit is keyed by the normalised email string, not by the person, so a known and an
    // unknown address behave exactly the same (same 202s, same 429) and the answer never
    // reveals whether an address is registered.
    let mut tx = st.pool.begin().await?;
    // Serialise per address so parallel requests cannot all pass the count.
    sqlx::query("select pg_advisory_xact_lock(hashtextextended($1::text, 0))")
        .bind(&email)
        .execute(&mut *tx)
        .await?;
    let counted = sqlx::query(
        "insert into login_attempt (email)
         select $1
         where (select count(*) from login_attempt
                where email = $1 and at > now() - interval '1 hour') < $2",
    )
    .bind(&email)
    .bind(MAX_LINKS_PER_HOUR)
    .execute(&mut *tx)
    .await?
    .rows_affected();
    if counted == 0 {
        // Seconds until the window frees a place: when the attempt that holds the last
        // place (the oldest one beyond the limit) is an hour old.
        let wait: Option<i64> = sqlx::query_scalar(
            "select ceil(extract(epoch from (at + interval '1 hour' - now())))::bigint
             from login_attempt where email = $1 and at > now() - interval '1 hour'
             order by at
             offset greatest((select count(*) from login_attempt
                              where email = $1 and at > now() - interval '1 hour') - $2, 0)
             limit 1",
        )
        .bind(&email)
        .bind(MAX_LINKS_PER_HOUR)
        .fetch_optional(&mut *tx)
        .await?;
        tx.commit().await?;
        return Err(ApiError::TooManyRequests(
            crate::rules::msg::TOO_MANY_LINKS.into(),
            wait.unwrap_or(3600).clamp(1, 3600) as u64,
        ));
    }
    // Housekeeping: attempts older than a day no longer matter.
    sqlx::query("delete from login_attempt where email = $1 and at < now() - interval '1 day'")
        .bind(&email)
        .execute(&mut *tx)
        .await?;

    let person: Option<(Uuid,)> =
        sqlx::query_as("select id from person where active and lower(email) = $1")
            .bind(&email)
            .fetch_optional(&mut *tx)
            .await?;
    // Unknown address: same answer as a known one, nothing sent.
    let Some((person_id,)) = person else {
        tx.commit().await?;
        return Ok((StatusCode::ACCEPTED, Json(json!({}))));
    };

    // Spent links of this person are not needed after a day.
    sqlx::query(
        "delete from login_token where person_id = $1 and expires_at < now() - interval '1 day'",
    )
    .bind(person_id)
    .execute(&mut *tx)
    .await?;

    let token = random_token();
    sqlx::query(
        "insert into login_token (token_hash, person_id, expires_at, origin, allow_recovery)
         values ($1, $2, now() + make_interval(mins => $3), 'email', true)",
    )
    .bind(hash_token(&token))
    .bind(person_id)
    .bind(LINK_MINUTES)
    .execute(&mut *tx)
    .await?;
    tx.commit().await?;

    let link = format!("{}/auth/verify?token={}", st.config.public_url, token);
    if st.config.log_magic_links {
        tracing::info!(%email, %link, "magic link (LOG_MAGIC_LINKS is on)");
    }
    // An internal address never receives mail: no send, so no SMTP error either. The answer,
    // the rate limit and the work above are the same as for any other address.
    if st.config.is_internal_email(&email) {
        return Ok((StatusCode::ACCEPTED, Json(json!({}))));
    }
    // Real SMTP can take seconds; do it in the background so response time does
    // not tell a caller whether the address exists. The test mailbox is instant.
    let mailer = st.mailer.clone();
    let send = async move {
        if let Err(e) = mailer.send_login_link(&email, &link).await {
            // The caller still gets 202: the answer must not depend on the address.
            tracing::error!(error = %e, "could not send sign-in email");
        }
    };
    if matches!(st.mailer, crate::mail::Mailer::Smtp { .. }) {
        tokio::spawn(send);
    } else {
        send.await;
    }
    Ok((StatusCode::ACCEPTED, Json(json!({}))))
}

#[derive(Deserialize)]
struct VerifyBody {
    token: String,
}

async fn verify(
    State(st): State<AppState>,
    client: ClientAddr,
    ApiJson(body): ApiJson<VerifyBody>,
) -> Result<Json<Value>, ApiError> {
    let expired =
        || ApiError::unauthorized("This link has expired or was already used. Ask for a new one.");

    // One atomic statement: only the first caller gets the row back.
    let used: Option<(Uuid, bool)> = sqlx::query_as(
        "update login_token set used_at = now()
         where token_hash = $1 and used_at is null and expires_at > now()
         returning person_id, allow_recovery",
    )
    .bind(hash_token(body.token.trim()))
    .fetch_optional(&st.pool)
    .await?;
    let (person_id, allow_recovery) = used.ok_or_else(expired)?;

    let user = crate::auth::load_user(&st.pool, person_id)
        .await?
        .ok_or_else(expired)?;
    // A link is a sign-in too: this address is trusted for the name, and the pair starts from zero.
    loginlimit::succeed(
        &st.pool,
        &Who::new(&st.limit_keys, &user.username, &client),
        true,
    )
    .await;
    let (access_token, exp) = issue_jwt_via(
        &st.config.jwt_secret,
        person_id,
        user.role,
        user.epoch,
        if allow_recovery {
            Via::Link
        } else {
            Via::LinkPlain
        },
    )?;
    Ok(Json(json!({
        "access_token": access_token,
        "expires_at": exp.to_rfc3339_opts(SecondsFormat::Secs, true),
        "user": user_json(&user),
        "has_password": user.has_password,
        "must_change_password": user.must_change_password,
    })))
}

#[derive(Deserialize)]
struct LoginBody {
    username: String,
    password: String,
}

/// Sign in with a username and a password. Every way to fail (no such name, wrong password,
/// switched off, no password set) gives the same 401 after the same work.
async fn login(
    State(st): State<AppState>,
    client: ClientAddr,
    ApiJson(body): ApiJson<LoginBody>,
) -> Result<Json<Value>, ApiError> {
    let wrong = || ApiError::unauthorized(limit_msg::WRONG);
    let who = Who::new(&st.limit_keys, &body.username, &client);
    let attempt = loginlimit::begin_attempt(&st.pool, &who, Kind::Login).await?;

    let key = crate::username::lookup_key(&body.username);
    let found: Option<(Uuid, Option<String>, bool)> = match sqlx::query_as(
        "select id, password_hash, active from person where lower(username) = $1",
    )
    .bind(&key)
    .fetch_optional(&st.pool)
    .await
    {
        Ok(r) => r,
        Err(e) => {
            loginlimit::forgive(&st.pool, attempt).await;
            return Err(e.into());
        }
    };
    let (person_id, stored) = match found {
        Some((id, hash, true)) => (Some(id), hash),
        _ => (None, None),
    };
    // No hash to check against: the dummy hash costs the same time and never says yes.
    let verdict = if password::too_long(&body.password) {
        // Cannot be anyone's password; do not spend memory on it.
        None
    } else {
        match st.hasher.verify(&body.password, stored.as_deref()).await {
            Ok(v) => Some(v),
            Err(e) => {
                loginlimit::forgive(&st.pool, attempt).await;
                return Err(e.into());
            }
        }
    };
    let (Some(person_id), Some(verdict)) = (person_id, verdict) else {
        return Err(wrong());
    };
    if !verdict.ok {
        return Err(wrong());
    }
    loginlimit::succeed(&st.pool, &who, true).await;

    let user = crate::auth::load_user(&st.pool, person_id)
        .await?
        .ok_or_else(wrong)?;
    if verdict.needs_rehash {
        rehash(&st, person_id, stored.as_deref(), &body.password).await;
    }
    let (access_token, exp) = issue_jwt_via(
        &st.config.jwt_secret,
        person_id,
        user.role,
        user.epoch,
        Via::Password,
    )?;
    Ok(Json(json!({
        "access_token": access_token,
        "expires_at": exp.to_rfc3339_opts(SecondsFormat::Secs, true),
        "user": user_json(&user),
        "must_change_password": user.must_change_password,
        "has_password": true,
    })))
}

/// The stored hash used older parameters: store a new one. Best effort; the old one still works.
async fn rehash(st: &AppState, person_id: Uuid, old: Option<&str>, password: &str) {
    let Ok(new) = st.hasher.hash(password).await else {
        return;
    };
    let r =
        sqlx::query("update person set password_hash = $2 where id = $1 and password_hash = $3")
            .bind(person_id)
            .bind(new)
            .bind(old)
            .execute(&st.pool)
            .await;
    if let Err(e) = r {
        tracing::warn!(error = %e, "could not store a rehashed password");
    }
}

#[derive(Deserialize)]
struct ChangeBody {
    #[serde(default)]
    current_password: Option<String>,
    new_password: String,
}

/// Choose or change the password of the person who is signed in. A person who has one must give
/// it (a wrong one is counted per pair, per address and per person, apart from sign-in failures;
/// the 10th in 15 minutes ends all their sessions, audit kind `change-lock`), with one exception:
/// a session that began at most 15 minutes ago with a sign-in link that allows recovery (asked
/// for by email, or made with the recovery option) needs no current password (the way back for
/// someone who forgot it; audit kind `change-via-link`). Other links give a session that must
/// give the current password like any other. A person who has none
/// (first password after a link) does not need it either. All older sessions end and the answer
/// carries a fresh one, which counts as a password session.
async fn change_password(
    SessionUser(user): SessionUser,
    State(st): State<AppState>,
    client: ClientAddr,
    ApiJson(body): ApiJson<ChangeBody>,
) -> Result<Json<Value>, ApiError> {
    if body.new_password.is_empty() {
        return Err(ApiError::bad(pw_msg::NEW_REQUIRED));
    }
    let (stored, email, full_name): (Option<String>, Option<String>, String) =
        sqlx::query_as("select password_hash, email, full_name from person where id = $1")
            .bind(user.person_id)
            .fetch_one(&st.pool)
            .await?;

    let mut kind = "change";
    if let Some(hash) = &stored {
        if user.fresh_link_session() {
            // Signed in by a link a moment ago: the link proves it is them. The old password is
            // neither asked for nor looked at (so this cannot be used to test guesses).
            kind = "change-via-link";
        } else {
            let current = body
                .current_password
                .as_deref()
                .filter(|c| !c.is_empty())
                .ok_or_else(|| ApiError::bad(pw_msg::CURRENT_REQUIRED))?;
            let who = Who::for_change(&st.limit_keys, &user.person_id.to_string(), &client);
            let attempt = loginlimit::begin_attempt(&st.pool, &who, Kind::Change).await?;
            let ok = if password::too_long(current) {
                false
            } else {
                match st.hasher.verify(current, Some(hash)).await {
                    Ok(v) => v.ok,
                    Err(e) => {
                        loginlimit::forgive(&st.pool, attempt).await;
                        return Err(e.into());
                    }
                }
            };
            if !ok {
                // The 10th wrong one in the window ends this person's sessions, this one too.
                if loginlimit::end_sessions_at_cap(
                    &st.pool,
                    &who,
                    attempt,
                    user.person_id,
                    user.epoch,
                )
                .await?
                {
                    return Err(ApiError::unauthorized(limit_msg::SIGNED_OUT_FOR_SAFETY));
                }
                return Err(ApiError::forbidden(pw_msg::CURRENT_WRONG));
            }
            loginlimit::succeed(&st.pool, &who, false).await;
            if password::normalize(current) == password::normalize(&body.new_password) {
                return Err(ApiError::bad(pw_msg::SAME));
            }
        }
    }

    password::check(
        &body.new_password,
        Subject {
            username: &user.username,
            email: email.as_deref().unwrap_or(""),
            full_name: &full_name,
        },
    )
    .map_err(ApiError::bad)?;
    let new_hash = st.hasher.hash(&body.new_password).await?;

    let mut tx = st.pool.begin().await?;
    let now: Option<(Option<String>,)> =
        sqlx::query_as("select password_hash from person where id = $1 and active for update")
            .bind(user.person_id)
            .fetch_optional(&mut *tx)
            .await?;
    // Someone changed it while we were hashing: this session is over.
    if now.map(|r| r.0) != Some(stored) {
        return Err(ApiError::unauthorized(SIGN_IN_AGAIN_MSG));
    }
    let epoch =
        passwords::store_password(&mut tx, user.person_id, Some(&new_hash), false, kind, None)
            .await?
            .ok_or(ApiError::Internal)?;
    tx.commit().await?;
    let (access_token, exp) = issue_jwt_via(
        &st.config.jwt_secret,
        user.person_id,
        user.role,
        epoch,
        Via::Password,
    )?;
    Ok(Json(json!({
        "access_token": access_token,
        "expires_at": exp.to_rfc3339_opts(SecondsFormat::Secs, true),
    })))
}

/// `GET /api/me`: the user plus what the app needs to offer password screens.
pub fn me_json(u: &crate::auth::AuthUser) -> Value {
    let mut v = user_json(u);
    v["username"] = json!(u.username);
    v["has_password"] = json!(u.has_password);
    v["must_change_password"] = json!(u.must_change_password);
    // True for a person with a password whose session began with a link a moment ago: the
    // change-password form may leave out the current password.
    v["recent_link_session"] = json!(u.recent_link_session());
    v
}

pub fn user_json(u: &crate::auth::AuthUser) -> Value {
    json!({
        "person_id": u.person_id,
        "role": match u.role { Role::Controller => "controller", Role::Contributor => "contributor" },
        "label": u.label,
    })
}
