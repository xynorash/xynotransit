use std::{collections::HashMap, convert::Infallible, time::Duration};

use axum::{
    extract::{Query, State},
    http::{header::HeaderName, HeaderValue},
    response::{
        sse::{Event, KeepAlive, Sse},
        IntoResponse, Response,
    },
    routing::{get, post},
    Json, Router,
};
use serde_json::{json, Value};
use tokio::sync::broadcast::error::RecvError;

use crate::{
    auth::{load_user, AuthUser},
    error::{parse_id, ApiError},
    state::{AppState, ChangeEvent},
};

pub fn router() -> Router<AppState> {
    Router::new()
        .route("/events/ticket", post(ticket))
        .route("/events", get(stream))
}

async fn ticket(user: AuthUser, State(st): State<AppState>) -> Result<Json<Value>, ApiError> {
    user.require_controller()?;
    Ok(Json(json!({ "ticket": st.issue_ticket(user.person_id) })))
}

async fn stream(
    State(st): State<AppState>,
    Query(q): Query<HashMap<String, String>>,
) -> Result<Response, ApiError> {
    let ticket = q.get("ticket").map(String::as_str).unwrap_or("");
    let person = st
        .redeem_ticket(ticket)
        .ok_or_else(|| ApiError::unauthorized("Please sign in."))?;
    // The person must still be active.
    let user = load_user(&st.pool, person)
        .await?
        .ok_or_else(|| ApiError::unauthorized("Please sign in."))?;
    // A ticket made before the person had to choose a new password opens nothing.
    if user.must_change_password {
        return Err(ApiError::unauthorized("Please sign in."));
    }
    user.require_controller()?;
    let period_id = parse_id(q.get("period_id").map(String::as_str).unwrap_or(""))?;

    let mut rx = st.events.subscribe();
    let mut stopping = st.shutdown.subscribe();
    let events = async_stream::stream! {
        loop {
            let next = tokio::select! {
                r = rx.recv() => r,
                // The server is shutting down: end the stream so the connection can close.
                _ = stopping.wait_for(|v| *v) => break,
            };
            match next {
                Ok(ev) if ev.period_id == period_id => {
                    yield Ok::<Event, Infallible>(Event::default().data(
                        serde_json::to_string(&ev).unwrap_or_default(),
                    ));
                }
                Ok(_) => {}
                // We missed messages: tell the page to refresh both things.
                Err(RecvError::Lagged(_)) => {
                    for kind in ["reports", "deck"] {
                        let ev = ChangeEvent { kind: kind.into(), period_id };
                        yield Ok(Event::default().data(serde_json::to_string(&ev).unwrap_or_default()));
                    }
                }
                Err(RecvError::Closed) => break,
            }
        }
    };

    let mut res = Sse::new(events)
        .keep_alive(
            KeepAlive::new()
                .interval(Duration::from_secs(20))
                .text("ping"),
        )
        .into_response();
    res.headers_mut().insert(
        HeaderName::from_static("x-accel-buffering"),
        HeaderValue::from_static("no"),
    );
    Ok(res)
}
