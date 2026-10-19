//! Xynotransit API: the only thing that talks to Postgres.

pub mod auth;
pub mod config;
pub mod deck_text;
pub mod error;
pub mod hashing;
pub mod http;
pub mod listener;
pub mod loginlimit;
pub mod mail;
pub mod password;
pub mod passwords;
pub mod routes;
pub mod rules;
pub mod signin;
pub mod snapshot;
pub mod state;
pub mod summary;
pub mod username;
pub mod validate;

use std::{future::Future, time::Duration};

use axum::{extract::DefaultBodyLimit, http::StatusCode, middleware, Router};
use tower_http::{
    catch_panic::CatchPanicLayer, compression::CompressionLayer, limit::RequestBodyLimitLayer,
    timeout::TimeoutLayer,
};

use crate::{error::ApiError, state::AppState};

pub use rules::MAX_BODY_BYTES;

/// Longest a request may take from first byte to the start of its answer.
pub const REQUEST_TIMEOUT_SECS: u64 = 30;

async fn not_found() -> ApiError {
    ApiError::not_found("Not found.")
}

async fn method_not_allowed() -> ApiError {
    ApiError::MethodNotAllowed
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
        .method_not_allowed_fallback(method_not_allowed)
        .fallback(not_found);

    let mut app = Router::new()
        .nest("/api", api)
        .fallback(not_found)
        .layer(DefaultBodyLimit::max(MAX_BODY_BYTES))
        .layer(RequestBodyLimitLayer::new(MAX_BODY_BYTES))
        .layer(CatchPanicLayer::custom(http::PanicToJson))
        // Applies until the response starts, so open event streams are not cut.
        .layer(TimeoutLayer::with_status_code(
            StatusCode::REQUEST_TIMEOUT,
            Duration::from_secs(REQUEST_TIMEOUT_SECS),
        ))
        .layer(middleware::from_fn(http::json_errors));
    for layer in http::security_headers() {
        app = app.layer(layer);
    }
    app.layer(CompressionLayer::new())
        .layer(middleware::from_fn(http::request_context))
        .with_state(state)
}

/// Serve until `signal` fires, then stop taking new connections, close the event streams, and give
/// requests that are already running up to `shutdown_grace` to finish before returning.
pub async fn serve(
    listener: tokio::net::TcpListener,
    state: AppState,
    signal: impl Future<Output = ()> + Send + 'static,
) -> std::io::Result<()> {
    let grace = state.config.shutdown_grace;
    let app = build_router(state.clone());
    let mut stopping = state.shutdown.subscribe();
    let st = state.clone();
    let graceful = async move {
        signal.await;
        tracing::info!("shutting down: finishing requests that are running");
        st.begin_shutdown();
    };
    let server = axum::serve(
        listener,
        app.into_make_service_with_connect_info::<std::net::SocketAddr>(),
    )
    .with_graceful_shutdown(graceful);
    tokio::select! {
        r = server => r,
        _ = async move {
            let _ = stopping.wait_for(|v| *v).await;
            tokio::time::sleep(grace).await;
        } => {
            tracing::warn!(secs = grace.as_secs(), "shutdown grace period over, stopping anyway");
            Ok(())
        }
    }
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

/// Make the configured person an active manager. A missing person is created.
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
