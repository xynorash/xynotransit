use std::collections::HashMap;

use axum::{
    extract::{Path, State},
    routing::get,
    Json, Router,
};
use chrono::{DateTime, SecondsFormat, Utc};
use serde_json::{json, Value};
use sqlx::PgConnection;
use uuid::Uuid;

use super::periods::find_period;
use crate::{
    auth::AuthUser,
    error::{parse_id, ApiError, ApiJson},
    state::AppState,
    validate::{validate, MetricRef, ReportInput},
};

pub fn router() -> Router<AppState> {
    Router::new()
        .route("/periods/{id}/reports", get(list))
        .route("/periods/{id}/reports/{assignment_id}", get(one).put(send))
}

/// Reports of a period (optionally one assignment, optionally only submitted ones),
/// as the JSON the app expects.
pub async fn load_reports(
    conn: &mut PgConnection,
    period_id: Uuid,
    assignment: Option<Uuid>,
    only_submitted: bool,
) -> Result<Vec<Value>, ApiError> {
    #[allow(clippy::type_complexity)]
    let rows: Vec<(
        Uuid,
        Uuid,
        String,
        Option<DateTime<Utc>>,
        Option<String>,
        Option<String>,
        Option<String>,
    )> = sqlx::query_as(
        "select id, assignment_id, status::text, submitted_at,
                reporter_name, reporter_country, reporter_role from report
         where period_id = $1 and ($2::uuid is null or assignment_id = $2)
           and (not $3 or status = 'submitted')
         order by created_at, id",
    )
    .bind(period_id)
    .bind(assignment)
    .bind(only_submitted)
    .fetch_all(&mut *conn)
    .await?;
    let ids: Vec<Uuid> = rows.iter().map(|r| r.0).collect();

    let values: Vec<(Uuid, Uuid, i16, i32)> = sqlx::query_as(
        "select report_id, metric_def_id, month_offset, value from report_metric_value
         where report_id = any($1) order by metric_def_id, month_offset",
    )
    .bind(&ids)
    .fetch_all(&mut *conn)
    .await?;
    let kpis: Vec<(Uuid, Uuid, String, Option<String>)> = sqlx::query_as(
        "select report_id, kpi_def_id, status::text, comment from report_kpi_result
         where report_id = any($1) order by kpi_def_id",
    )
    .bind(&ids)
    .fetch_all(&mut *conn)
    .await?;
    let notes: Vec<(Uuid, String, i16, String)> = sqlx::query_as(
        "select report_id, kind::text, position, text from report_note
         where report_id = any($1) order by report_note.kind, position",
    )
    .bind(&ids)
    .fetch_all(&mut *conn)
    .await?;

    let mut v_by: HashMap<Uuid, Vec<Value>> = HashMap::new();
    for (r, m, o, v) in values {
        v_by.entry(r)
            .or_default()
            .push(json!({"metric_def_id": m.to_string(), "month_offset": o, "value": v}));
    }
    let mut k_by: HashMap<Uuid, Vec<Value>> = HashMap::new();
    for (r, k, s, c) in kpis {
        k_by.entry(r)
            .or_default()
            .push(json!({"kpi_def_id": k.to_string(), "status": s, "comment": c}));
    }
    let mut n_by: HashMap<Uuid, Vec<Value>> = HashMap::new();
    for (r, kind, p, t) in notes {
        n_by.entry(r)
            .or_default()
            .push(json!({"kind": kind, "position": p, "text": t}));
    }

    Ok(rows
        .into_iter()
        .map(|(id, assignment_id, status, submitted_at, rn, rc, rr)| {
            // Reports sent before reporter words existed have none: null, and the deck falls
            // back to the catalog profile.
            let reporter = match (rn, rc, rr) {
                (Some(name), Some(country), Some(role)) => {
                    json!({"name": name, "country": country, "role": role})
                }
                _ => Value::Null,
            };
            json!({
                "id": id.to_string(),
                "period_id": period_id.to_string(),
                "assignment_id": assignment_id.to_string(),
                "status": status,
                "reporter": reporter,
                "submitted_at": submitted_at.map(|t| t.to_rfc3339_opts(SecondsFormat::Millis, true)),
                "values": v_by.remove(&id).unwrap_or_default(),
                "kpis": k_by.remove(&id).unwrap_or_default(),
                "notes": n_by.remove(&id).unwrap_or_default(),
            })
        })
        .collect())
}

async fn list(
    user: AuthUser,
    State(st): State<AppState>,
    Path(period_id): Path<String>,
) -> Result<Json<Vec<Value>>, ApiError> {
    user.require_controller()?;
    let period_id = parse_id(&period_id)?;
    let mut conn = st.pool.acquire().await?;
    find_period(&mut conn, period_id).await?;
    Ok(Json(load_reports(&mut conn, period_id, None, false).await?))
}

async fn one(
    user: AuthUser,
    State(st): State<AppState>,
    Path((period_id, assignment_id)): Path<(String, String)>,
) -> Result<Json<Value>, ApiError> {
    let (period_id, assignment_id) = (parse_id(&period_id)?, parse_id(&assignment_id)?);
    let mut conn = st.pool.acquire().await?;
    if !user.is_controller() {
        let owner: Option<(Uuid,)> =
            sqlx::query_as("select person_id from assignment where id = $1")
                .bind(assignment_id)
                .fetch_optional(&mut *conn)
                .await?;
        if owner.map(|o| o.0) != Some(user.person_id) {
            return Err(ApiError::forbidden("You can only see your own report."));
        }
    }
    load_reports(&mut conn, period_id, Some(assignment_id), false)
        .await?
        .into_iter()
        .next()
        .map(Json)
        .ok_or_else(|| ApiError::not_found("No report has been started for this seat."))
}

async fn send(
    user: AuthUser,
    State(st): State<AppState>,
    Path((period_id, assignment_id)): Path<(String, String)>,
    ApiJson(body): ApiJson<ReportInput>,
) -> Result<Json<Value>, ApiError> {
    let (period_id, assignment_id) = (parse_id(&period_id)?, parse_id(&assignment_id)?);
    let mut tx = st.pool.begin().await?;

    let period = find_period(&mut tx, period_id).await?;
    let owner: Option<(Uuid,)> =
        sqlx::query_as("select person_id from assignment where id = $1 and active")
            .bind(assignment_id)
            .fetch_optional(&mut *tx)
            .await?;
    let (owner,) = owner.ok_or_else(|| ApiError::not_found("That seat does not exist."))?;

    if owner != user.person_id && !user.is_controller() {
        return Err(ApiError::forbidden("You can only send your own report."));
    }
    if period.status == "closed" && !user.is_controller() {
        return Err(ApiError::forbidden("This period is closed."));
    }

    let metrics: Vec<(Uuid, String)> = sqlx::query_as(
        "select id, label from metric_def
         where assignment_id = $1 and retired_at is null order by series",
    )
    .bind(assignment_id)
    .fetch_all(&mut *tx)
    .await?;
    let metrics: Vec<MetricRef> = metrics
        .into_iter()
        .map(|(id, label)| MetricRef { id, label })
        .collect();
    let kpi_ids: Vec<(Uuid,)> = sqlx::query_as(
        "select id from kpi_def where assignment_id = $1 and retired_at is null order by sort, id",
    )
    .bind(assignment_id)
    .fetch_all(&mut *tx)
    .await?;
    let kpi_ids: Vec<Uuid> = kpi_ids.into_iter().map(|r| r.0).collect();

    if let Some(first) = validate(&body, &metrics, &kpi_ids, period.start_month)
        .into_iter()
        .next()
    {
        return Err(ApiError::BadRequest(first));
    }

    // validate() accepted it, so the block exists.
    let reporter = body.reporter.as_ref().ok_or(ApiError::Internal)?.trimmed();
    let (report_id,): (Uuid,) = sqlx::query_as(
        "insert into report (period_id, assignment_id, status, reporter_name, reporter_country, reporter_role)
         values ($1, $2, 'draft', $3, $4, $5)
         on conflict (period_id, assignment_id)
         do update set status = 'draft', submitted_at = null,
           reporter_name = excluded.reporter_name,
           reporter_country = excluded.reporter_country,
           reporter_role = excluded.reporter_role
         returning id",
    )
    .bind(period_id)
    .bind(assignment_id)
    .bind(&reporter.0)
    .bind(&reporter.1)
    .bind(&reporter.2)
    .fetch_one(&mut *tx)
    .await?;

    for table in ["report_metric_value", "report_kpi_result", "report_note"] {
        sqlx::query(&format!("delete from {table} where report_id = $1"))
            .bind(report_id)
            .execute(&mut *tx)
            .await?;
    }
    for v in &body.values {
        sqlx::query(
            "insert into report_metric_value (report_id, assignment_id, metric_def_id, month_offset, value)
             values ($1, $2, $3, $4, $5)",
        )
        .bind(report_id)
        .bind(assignment_id)
        .bind(v.metric_def_id)
        .bind(v.month_offset)
        .bind(v.value.unwrap_or(0) as i32)
        .execute(&mut *tx)
        .await?;
    }
    for k in &body.kpis {
        let comment = k
            .comment
            .as_deref()
            .map(crate::rules::fold_spaces)
            .filter(|c| !c.is_empty());
        sqlx::query(
            "insert into report_kpi_result (report_id, assignment_id, kpi_def_id, status, comment)
             values ($1, $2, $3, $4::kpi_status, $5)",
        )
        .bind(report_id)
        .bind(assignment_id)
        .bind(k.kpi_def_id)
        .bind(&k.status)
        .bind(comment.as_deref())
        .execute(&mut *tx)
        .await?;
    }
    for n in &body.notes {
        sqlx::query(
            "insert into report_note (report_id, kind, position, text) values ($1, $2::note_kind, $3, $4)",
        )
        .bind(report_id)
        .bind(&n.kind)
        .bind(n.position)
        .bind(crate::rules::fold_spaces(&n.text))
        .execute(&mut *tx)
        .await?;
    }

    sqlx::query("select submit_report($1)")
        .bind(report_id)
        .execute(&mut *tx)
        .await?;

    let report = load_reports(&mut tx, period_id, Some(assignment_id), false)
        .await?
        .into_iter()
        .next()
        .ok_or(ApiError::Internal)?;
    tx.commit().await?;
    Ok(Json(report))
}
