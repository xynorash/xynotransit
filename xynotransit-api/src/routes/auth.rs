use axum::{extract::State, http::StatusCode, routing::post, Json, Router};
use chrono::SecondsFormat;
use serde::Deserialize;
use serde_json::{json, Value};
use uuid::Uuid;

use crate::{
    auth::{hash_token, issue_jwt, random_token, Role},
    error::{ApiError, ApiJson},
    state::AppState,
};

pub fn router() -> Router<AppState> {
    Router::new()
        .route("/auth/magic-link", post(magic_link))
        .route("/auth/verify", post(verify))
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
        tx.commit().await?;
        return Err(ApiError::TooManyRequests(
            crate::rules::msg::TOO_MANY_LINKS.into(),
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
        "insert into login_token (token_hash, person_id, expires_at)
         values ($1, $2, now() + make_interval(mins => $3))",
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
    ApiJson(body): ApiJson<VerifyBody>,
) -> Result<Json<Value>, ApiError> {
    let expired =
        || ApiError::unauthorized("This link has expired or was already used. Ask for a new one.");

    // One atomic statement: only the first caller gets the row back.
    let used: Option<(Uuid,)> = sqlx::query_as(
        "update login_token set used_at = now()
         where token_hash = $1 and used_at is null and expires_at > now()
         returning person_id",
    )
    .bind(hash_token(body.token.trim()))
    .fetch_optional(&st.pool)
    .await?;
    let (person_id,) = used.ok_or_else(expired)?;

    let user = crate::auth::load_user(&st.pool, person_id)
        .await?
        .ok_or_else(expired)?;
    let (access_token, exp) = issue_jwt(&st.config.jwt_secret, person_id, user.role)?;
    Ok(Json(json!({
        "access_token": access_token,
        "expires_at": exp.to_rfc3339_opts(SecondsFormat::Secs, true),
        "user": user_json(&user),
    })))
}

pub fn user_json(u: &crate::auth::AuthUser) -> Value {
    json!({
        "person_id": u.person_id,
        "role": match u.role { Role::Controller => "controller", Role::Contributor => "contributor" },
        "label": u.label,
    })
}
