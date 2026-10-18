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

pub const MAX_LINKS_PER_HOUR: i64 = 5;
const LINK_MINUTES: i32 = 15;

#[derive(Deserialize)]
struct MagicLinkBody {
    email: String,
}

async fn magic_link(
    State(st): State<AppState>,
    ApiJson(body): ApiJson<MagicLinkBody>,
) -> Result<(StatusCode, Json<Value>), ApiError> {
    let email = body.email.trim().to_lowercase();
    if email.len() > 254 || !email.contains('@') || email.chars().any(char::is_control) {
        return Err(ApiError::bad("Enter a valid email address."));
    }

    let person: Option<(Uuid,)> =
        sqlx::query_as("select id from person where active and lower(email) = $1")
            .bind(&email)
            .fetch_optional(&st.pool)
            .await?;
    // Unknown address: same answer as a known one, nothing sent.
    let Some((person_id,)) = person else {
        return Ok((StatusCode::ACCEPTED, Json(json!({}))));
    };

    let token = random_token();
    // Serialise per person so parallel requests cannot all pass the count.
    let mut tx = st.pool.begin().await?;
    sqlx::query("select pg_advisory_xact_lock(hashtextextended($1::text, 0))")
        .bind(person_id.to_string())
        .execute(&mut *tx)
        .await?;
    // Insert only while fewer than the allowed number were created in the last hour.
    let inserted = sqlx::query(
        "insert into login_token (token_hash, person_id, expires_at)
         select $1, $2, now() + make_interval(mins => $3)
         where (select count(*) from login_token
                where person_id = $2 and created_at > now() - interval '1 hour') < $4",
    )
    .bind(hash_token(&token))
    .bind(person_id)
    .bind(LINK_MINUTES)
    .bind(MAX_LINKS_PER_HOUR)
    .execute(&mut *tx)
    .await?
    .rows_affected();
    tx.commit().await?;
    if inserted == 0 {
        return Err(ApiError::TooManyRequests(
            "Too many links requested. Try again later.".into(),
        ));
    }

    let link = format!("{}/auth/verify?token={}", st.config.public_url, token);
    if st.config.log_magic_links {
        tracing::info!(%email, %link, "magic link (LOG_MAGIC_LINKS is on)");
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
