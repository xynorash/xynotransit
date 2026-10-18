//! The manager's summary dashboard numbers. Controller only.

use std::collections::HashMap;

use axum::{
    extract::{Query, State},
    routing::get,
    Json, Router,
};
use chrono::NaiveDate;
use serde_json::Value;
use uuid::Uuid;

use crate::{
    auth::AuthUser,
    error::ApiError,
    state::AppState,
    summary::{self, PeriodIn, ReportIn, SeatIn, SummaryInput, TeamIn, ValueIn},
};

pub fn router() -> Router<AppState> {
    Router::new().route("/summary", get(get_summary))
}

const DEFAULT_TREND: i64 = 6;
const MAX_TREND: i64 = 24;

async fn get_summary(
    user: AuthUser,
    State(st): State<AppState>,
    Query(q): Query<HashMap<String, String>>,
) -> Result<Json<Value>, ApiError> {
    user.require_controller()?;
    let period_id = q
        .get("period_id")
        .and_then(|s| Uuid::parse_str(s.trim()).ok())
        .ok_or_else(|| ApiError::bad("Choose a period."))?;
    let trend = match q.get("trend") {
        None => DEFAULT_TREND,
        Some(s) => s
            .trim()
            .parse::<i64>()
            .ok()
            .filter(|n| (1..=MAX_TREND).contains(n))
            .ok_or_else(|| ApiError::bad("The trend must be a number from 1 to 24."))?,
    };

    let shown: Option<(Uuid, NaiveDate)> =
        sqlx::query_as("select id, start_month from period where id = $1")
            .bind(period_id)
            .fetch_optional(&st.pool)
            .await?;
    let (shown_id, shown_start) =
        shown.ok_or_else(|| ApiError::not_found("That period does not exist."))?;

    // The shown period and up to trend-1 earlier ones, oldest first.
    let mut periods: Vec<(Uuid, NaiveDate)> = sqlx::query_as(
        "select id, start_month from period where start_month <= $1
         order by start_month desc limit $2",
    )
    .bind(shown_start)
    .bind(trend)
    .fetch_all(&st.pool)
    .await?;
    periods.reverse();
    let period_ids: Vec<Uuid> = periods.iter().map(|p| p.0).collect();

    let teams: Vec<(i32, String)> =
        sqlx::query_as("select id::int, name from team order by sort, id")
            .fetch_all(&st.pool)
            .await?;
    let seats: Vec<(Uuid, String, String, i32, bool)> = sqlx::query_as(
        "select a.id, p.full_name, a.role_title, a.team_id::int, a.active
         from assignment a
         join team t on t.id = a.team_id
         join person p on p.id = a.person_id
         order by t.sort, t.id, a.sort, a.code",
    )
    .fetch_all(&st.pool)
    .await?;
    let reports: Vec<(Uuid, Uuid, i64, i64, i64)> = sqlx::query_as(
        "select r.period_id, r.assignment_id,
                count(k.*) filter (where k.status = 'met'),
                count(k.*) filter (where k.status = 'partly'),
                count(k.*) filter (where k.status = 'missed')
         from report r
         left join report_kpi_result k on k.report_id = r.id
         where r.status = 'submitted' and r.period_id = any($1)
         group by r.id, r.period_id, r.assignment_id",
    )
    .bind(&period_ids)
    .fetch_all(&st.pool)
    .await?;
    let values: Vec<(Uuid, Uuid, String, i32, i64)> = sqlx::query_as(
        "select r.period_id, r.assignment_id, min(m.label), v.month_offset::int, sum(v.value)::bigint
         from report r
         join report_metric_value v on v.report_id = r.id
         join metric_def m on m.id = v.metric_def_id
         join assignment a on a.id = r.assignment_id
         join team t on t.id = a.team_id
         where r.status = 'submitted' and r.period_id = any($1)
         group by r.period_id, r.assignment_id, lower(m.label), v.month_offset,
                  t.sort, t.id, a.sort, a.code
         order by t.sort, t.id, a.sort, a.code, min(m.series), lower(m.label), v.month_offset",
    )
    .bind(&period_ids)
    .fetch_all(&st.pool)
    .await?;

    let period = |p: &(Uuid, NaiveDate)| PeriodIn {
        id: p.0,
        start_month: p.1,
    };
    let input = SummaryInput {
        shown: PeriodIn {
            id: shown_id,
            start_month: shown_start,
        },
        periods: periods.iter().map(period).collect(),
        teams: teams
            .into_iter()
            .map(|(id, name)| TeamIn { id, name })
            .collect(),
        seats: seats
            .into_iter()
            .map(|(id, name, role, team_id, active)| SeatIn {
                id,
                name,
                role,
                team_id,
                active,
            })
            .collect(),
        reports: reports
            .into_iter()
            .map(|(period_id, assignment_id, met, partly, missed)| ReportIn {
                period_id,
                assignment_id,
                met,
                partly,
                missed,
            })
            .collect(),
        values: values
            .into_iter()
            .map(|(period_id, assignment_id, label, month, total)| ValueIn {
                period_id,
                assignment_id,
                label,
                month: month.clamp(0, 2) as usize,
                total,
            })
            .collect(),
    };
    Ok(Json(summary::build(&input)))
}
