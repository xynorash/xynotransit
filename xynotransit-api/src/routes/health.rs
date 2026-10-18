use axum::{extract::State, routing::get, Json, Router};
use serde_json::{json, Value};

use crate::{error::ApiError, state::AppState};

pub fn router() -> Router<AppState> {
    Router::new().route("/health", get(health))
}

async fn health(State(st): State<AppState>) -> Result<Json<Value>, ApiError> {
    sqlx::query("select 1")
        .execute(&st.pool)
        .await
        .map_err(|e| {
            tracing::error!(error = %e, "health check failed");
            ApiError::Unavailable
        })?;
    Ok(Json(json!({ "ok": true })))
}
