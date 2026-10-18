//! Xynotransit API: the only thing that talks to Postgres.

pub mod auth;
pub mod config;
pub mod deck_text;
pub mod error;
pub mod listener;
pub mod mail;
pub mod routes;
pub mod rules;
pub mod snapshot;
pub mod state;
pub mod summary;
pub mod validate;

use std::time::Duration;

use axum::{extract::DefaultBodyLimit, http::StatusCode, Router};
use tower_http::{compression::CompressionLayer, timeout::TimeoutLayer, trace::TraceLayer};

use crate::{error::ApiError, state::AppState};

pub const MAX_BODY_BYTES: usize = 256 * 1024;

async fn not_found() -> ApiError {
    ApiError::not_found("Not found.")
}

/// The whole API under /api. No CORS layer: the app and the API share an origin.
pub fn build_router(state: AppState) -> Router {
    let api = Router::new()
        .merge(routes::health::router())
        .merge(routes::auth::router())
        .merge(routes::catalog::router())
        .merge(routes::admin::router())
        .merge(routes::summary::router())
        .merge(routes::periods::router())
        .merge(routes::reports::router())
        .merge(routes::decks::router())
        .merge(routes::events::router())
        .fallback(not_found);

    Router::new()
        .nest("/api", api)
        .fallback(not_found)
        .layer(DefaultBodyLimit::max(MAX_BODY_BYTES))
        // Applies until the response starts, so open event streams are not cut.
        .layer(TimeoutLayer::with_status_code(
            StatusCode::REQUEST_TIMEOUT,
            Duration::from_secs(30),
        ))
        .layer(CompressionLayer::new())
        .layer(TraceLayer::new_for_http())
        .with_state(state)
}

/// The name for a bootstrap manager who is created: the given one, or the part of
/// the email before the @ with a capital first letter.
pub fn bootstrap_name(email: &str, name: Option<&str>) -> String {
    if let Some(n) = name.map(str::trim).filter(|n| !n.is_empty()) {
        return n.to_string();
    }
    let local = email.split('@').next().unwrap_or("").trim();
    let mut chars = local.chars();
    match chars.next() {
        Some(c) => c.to_uppercase().chain(chars).collect(),
        None => "Manager".to_string(),
    }
}

/// Make the configured person an active controller. A missing person is created.
/// Returns how many rows changed (0 when nothing needed doing).
pub async fn bootstrap_controller(
    pool: &sqlx::PgPool,
    email: &str,
    name: Option<&str>,
) -> Result<u64, sqlx::Error> {
    let email = email.trim().to_lowercase();
    let changed = sqlx::query(
        "update person set app_role = 'controller', active = true
         where lower(email) = $1 and (app_role <> 'controller' or not active)",
    )
    .bind(&email)
    .execute(pool)
    .await?
    .rows_affected();
    if changed > 0 {
        return Ok(changed);
    }
    let created = sqlx::query(
        "insert into person (full_name, email, app_role, active)
         select $2, $1, 'controller', true
         where not exists (select 1 from person where lower(email) = $1)",
    )
    .bind(&email)
    .bind(bootstrap_name(&email, name))
    .execute(pool)
    .await?
    .rows_affected();
    Ok(created)
}

#[cfg(test)]
mod tests {
    use super::bootstrap_name;

    #[test]
    fn bootstrap_names() {
        assert_eq!(bootstrap_name("shalini@x.org", None), "Shalini");
        assert_eq!(bootstrap_name("shalini@x.org", Some("  ")), "Shalini");
        assert_eq!(
            bootstrap_name("shalini@x.org", Some(" Boss Lady ")),
            "Boss Lady"
        );
        assert_eq!(bootstrap_name("@x.org", None), "Manager");
    }
}
