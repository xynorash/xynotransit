use axum::{
    extract::{Path, State},
    routing::{patch, post},
    Json, Router,
};
use chrono::{Datelike, NaiveDate};
use serde::Deserialize;
use serde_json::{json, Value};
use uuid::Uuid;

use crate::{
    auth::AuthUser,
    error::{parse_id, ApiError, ApiJson},
    state::AppState,
};

pub fn router() -> Router<AppState> {
    Router::new()
        .route("/periods/ensure", post(ensure))
        .route("/periods/{id}", patch(update))
}

#[derive(sqlx::FromRow)]
pub struct PeriodRow {
    pub id: Uuid,
    pub start_month: NaiveDate,
    pub meeting_date: Option<NaiveDate>,
    pub status: String,
}

impl PeriodRow {
    pub fn json(&self) -> Value {
        json!({
            "id": self.id.to_string(),
            "start_month": self.start_month.format("%Y-%m-%d").to_string(),
            "meeting_date": self.meeting_date.map(|d| d.format("%Y-%m-%d").to_string()),
            "status": self.status,
        })
    }
}

const PERIOD_COLS: &str = "id, start_month, meeting_date, status::text as status";

pub async fn find_period(conn: &mut sqlx::PgConnection, id: Uuid) -> Result<PeriodRow, ApiError> {
    sqlx::query_as::<_, PeriodRow>(&format!("select {PERIOD_COLS} from period where id = $1"))
        .bind(id)
        .fetch_optional(conn)
        .await?
        .ok_or_else(|| ApiError::not_found("That period does not exist."))
}

fn parse_date(s: &str) -> Result<NaiveDate, ApiError> {
    let date = NaiveDate::parse_from_str(s.trim(), "%Y-%m-%d")
        .map_err(|_| ApiError::bad("Enter a date like 2026-02-01."))?;
    // Keep dates in a sane range so nobody can fill the table with nonsense.
    if !(2000..=2100).contains(&date.year()) {
        return Err(ApiError::bad("Enter a date between 2000 and 2100."));
    }
    Ok(date)
}

#[derive(Deserialize)]
struct EnsureBody {
    start_month: String,
}

async fn ensure(
    _user: AuthUser,
    State(st): State<AppState>,
    ApiJson(body): ApiJson<EnsureBody>,
) -> Result<Json<Value>, ApiError> {
    let date = parse_date(&body.start_month)?;
    let first = date.with_day(1).unwrap_or(date);
    sqlx::query(
        "insert into period (start_month) values ($1) on conflict (start_month) do nothing",
    )
    .bind(first)
    .execute(&st.pool)
    .await?;
    let row: PeriodRow = sqlx::query_as(&format!(
        "select {PERIOD_COLS} from period where start_month = $1"
    ))
    .bind(first)
    .fetch_one(&st.pool)
    .await?;
    Ok(Json(row.json()))
}

#[derive(Deserialize)]
struct UpdateBody {
    #[serde(default)]
    meeting_date: Option<String>,
}

async fn update(
    user: AuthUser,
    State(st): State<AppState>,
    Path(id): Path<String>,
    ApiJson(body): ApiJson<UpdateBody>,
) -> Result<Json<Value>, ApiError> {
    user.require_controller()?;
    let id = parse_id(&id)?;
    let date = body.meeting_date.as_deref().map(parse_date).transpose()?;
    let row: Option<PeriodRow> = sqlx::query_as(&format!(
        "update period set meeting_date = $2 where id = $1 returning {PERIOD_COLS}"
    ))
    .bind(id)
    .bind(date)
    .fetch_optional(&st.pool)
    .await?;
    Ok(Json(
        row.ok_or_else(|| ApiError::not_found("That period does not exist."))?
            .json(),
    ))
}
