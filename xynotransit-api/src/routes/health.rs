use std::time::Duration;

use axum::{extract::State, http::StatusCode, routing::get, Json, Router};
use serde_json::{json, Value};

use crate::state::AppState;

pub fn router() -> Router<AppState> {
    Router::new().route("/health", get(health))
}

/// 200 `{"ok":true,"db":"up"}` when a query reaches the database within 3 seconds,
/// else 503 `{"ok":false,"db":"down","error":"..."}`. Nothing about the failure leaves the log.
async fn health(State(st): State<AppState>) -> (StatusCode, Json<Value>) {
    let ping = tokio::time::timeout(
        Duration::from_secs(3),
        sqlx::query("select 1").execute(&st.pool),
    )
    .await;
    match ping {
        Ok(Ok(_)) => (StatusCode::OK, Json(json!({ "ok": true, "db": "up" }))),
        other => {
            match other {
                Ok(Err(e)) => tracing::error!(error = %e, "health check failed"),
                _ => tracing::error!("health check timed out"),
            }
            (
                StatusCode::SERVICE_UNAVAILABLE,
                Json(json!({
                    "ok": false,
                    "db": "down",
                    "error": "The service is not ready. Try again in a moment.",
                })),
            )
        }
    }
}
