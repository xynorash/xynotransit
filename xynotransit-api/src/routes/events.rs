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
    Ok(Json(
        json!({ "ticket": st.issue_ticket(user.person_id, user.epoch) }),
    ))
}

async fn stream(
    State(st): State<AppState>,
    Query(q): Query<HashMap<String, String>>,
) -> Result<Response, ApiError> {
    let ticket = q.get("ticket").map(String::as_str).unwrap_or("");
    let (person, ticket_epoch) = st
        .redeem_ticket(ticket)
        .ok_or_else(|| ApiError::unauthorized("Please sign in."))?;
    // The person must still be active, and nothing may have changed since the ticket was made:
    // a password change, reset, removal or switch-off adds 1 to the epoch (or ends the person),
    // which makes older tickets worthless.
    let user = load_user(&st.pool, person)
        .await?
        .ok_or_else(|| ApiError::unauthorized("Please sign in."))?;
    if user.epoch != ticket_epoch || user.must_change_password {
        return Err(ApiError::unauthorized("Please sign in."));
    }
    user.require_controller()?;
    let period_id = parse_id(q.get("period_id").map(String::as_str).unwrap_or(""))?;

    let mut rx = st.events.subscribe();
    let mut stopping = st.shutdown.subscribe();
    let recheck = st.stream_recheck;
    let pool = st.pool.clone();
    let events = async_stream::stream! {
        enum Step {
            Event(Result<ChangeEvent, RecvError>),
            Check,
            Stop,
        }
        let mut check = tokio::time::interval_at(tokio::time::Instant::now() + recheck, recheck);
        check.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
        loop {
            let step = tokio::select! {
                r = rx.recv() => Step::Event(r),
                _ = check.tick() => Step::Check,
                // The server is shutting down: end the stream so the connection can close.
                _ = stopping.wait_for(|v| *v) => Step::Stop,
            };
            match step {
                Step::Stop => break,
                // Look the person up again: the stream ends when anything that mattered changed.
                Step::Check => match load_user(&pool, person).await {
                    Ok(Some(now))
                        if now.epoch == ticket_epoch
                            && !now.must_change_password
                            && now.is_controller() => {}
                    Ok(_) => break,
                    Err(_) => tracing::warn!("could not re-check the person behind an event stream"),
                },
                Step::Event(Ok(ev)) if ev.period_id == period_id => {
                    yield Ok::<Event, Infallible>(Event::default().data(
                        serde_json::to_string(&ev).unwrap_or_default(),
                    ));
                }
                Step::Event(Ok(_)) => {}
                // We missed messages: tell the page to refresh both things.
                Step::Event(Err(RecvError::Lagged(_))) => {
                    for kind in ["reports", "deck"] {
                        let ev = ChangeEvent { kind: kind.into(), period_id };
                        yield Ok(Event::default().data(serde_json::to_string(&ev).unwrap_or_default()));
                    }
                }
                Step::Event(Err(RecvError::Closed)) => break,
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
