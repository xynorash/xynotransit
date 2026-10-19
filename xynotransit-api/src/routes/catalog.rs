use std::collections::HashMap;

use sqlx::PgConnection;

use axum::{
    extract::{Query, State},
    routing::get,
    Json, Router,
};
use serde_json::{json, Value};
use sqlx::FromRow;
use uuid::Uuid;

use crate::{auth::AuthUser, error::ApiError, state::AppState};

pub fn router() -> Router<AppState> {
    Router::new()
        .route("/me", get(me))
        .route("/catalog", get(catalog))
}

async fn me(user: AuthUser) -> Json<Value> {
    Json(super::auth::user_json(&user))
}

#[derive(FromRow)]
pub struct TeamRow {
    id: i32,
    code: String,
    name: String,
    sort: i32,
}

#[derive(FromRow)]
pub struct PersonRow {
    pub id: Uuid,
    pub full_name: String,
    pub email: Option<String>,
    pub app_role: String,
    pub active: bool,
}

#[derive(FromRow)]
struct AssignmentRow {
    id: Uuid,
    code: String,
    person_id: Uuid,
    team_id: i32,
    role_title: String,
    sort: i32,
    active: bool,
}

#[derive(FromRow)]
struct MetricRow {
    id: Uuid,
    assignment_id: Uuid,
    key: String,
    label: String,
    series: i32,
}

#[derive(FromRow)]
struct KpiRow {
    id: Uuid,
    assignment_id: Uuid,
    sort: i32,
    text: String,
}

pub fn person_json(p: &PersonRow, show_email: bool) -> Value {
    json!({
        "id": p.id.to_string(), "full_name": p.full_name,
        "email": if show_email { json!(p.email) } else { Value::Null },
        "app_role": p.app_role, "active": p.active,
    })
}

pub async fn load_person(conn: &mut PgConnection, id: Uuid) -> Result<Option<PersonRow>, ApiError> {
    Ok(sqlx::query_as(
        "select id, full_name, email, app_role::text as app_role, active from person where id = $1",
    )
    .bind(id)
    .fetch_optional(conn)
    .await?)
}

/// Seats with their live counts and targets, as the catalog shows them.
/// `only` limits the result to one seat.
pub async fn assignments_json(
    conn: &mut PgConnection,
    only: Option<Uuid>,
    include_inactive: bool,
) -> Result<Vec<Value>, ApiError> {
    let assignments: Vec<AssignmentRow> = sqlx::query_as(
        "select a.id, a.code, a.person_id, a.team_id::int as team_id, a.role_title, a.sort::int as sort, a.active
         from assignment a join team t on t.id = a.team_id join person pe on pe.id = a.person_id
         where ($1::uuid is null or a.id = $1) and ((a.active and pe.active) or $2)
         order by t.sort, t.id, a.sort, a.code",
    )
    .bind(only)
    .bind(include_inactive)
    .fetch_all(&mut *conn)
    .await?;

    let metrics: Vec<MetricRow> = sqlx::query_as(
        "select m.id, m.assignment_id, m.key, m.label, m.series::int as series
         from metric_def m join assignment a on a.id = m.assignment_id join person pe on pe.id = a.person_id
         where ($1::uuid is null or a.id = $1) and ((a.active and pe.active) or $2) and m.retired_at is null
         order by m.series, m.key",
    )
    .bind(only)
    .bind(include_inactive)
    .fetch_all(&mut *conn)
    .await?;

    let kpis: Vec<KpiRow> = sqlx::query_as(
        "select k.id, k.assignment_id, k.sort::int as sort, k.text
         from kpi_def k join assignment a on a.id = k.assignment_id join person pe on pe.id = a.person_id
         where ($1::uuid is null or a.id = $1) and ((a.active and pe.active) or $2) and k.retired_at is null
         order by k.sort, k.id",
    )
    .bind(only)
    .bind(include_inactive)
    .fetch_all(&mut *conn)
    .await?;

    let mut metrics_by: HashMap<Uuid, Vec<Value>> = HashMap::new();
    for m in metrics {
        metrics_by.entry(m.assignment_id).or_default().push(json!({
            "id": m.id.to_string(), "key": m.key, "label": m.label, "series": m.series,
        }));
    }
    let mut kpis_by: HashMap<Uuid, Vec<Value>> = HashMap::new();
    for k in kpis {
        kpis_by.entry(k.assignment_id).or_default().push(json!({
            "id": k.id.to_string(), "sort": k.sort, "text": k.text,
        }));
    }
    Ok(assignments
        .iter()
        .map(|a| {
            json!({
                "id": a.id.to_string(),
                "code": a.code,
                "person_id": a.person_id.to_string(),
                "team_id": a.team_id.to_string(),
                "role_title": a.role_title,
                "sort": a.sort,
                "active": a.active,
                "metrics": metrics_by.remove(&a.id).unwrap_or_default(),
                "kpis": kpis_by.remove(&a.id).unwrap_or_default(),
            })
        })
        .collect())
}

pub fn team_json(id: i32, code: &str, name: &str, sort: i32) -> Value {
    json!({"id": id.to_string(), "code": code, "name": name, "sort": sort})
}

async fn catalog(
    user: AuthUser,
    State(st): State<AppState>,
    Query(q): Query<HashMap<String, String>>,
) -> Result<Json<Value>, ApiError> {
    // Only a controller may see inactive people and seats.
    let all = user.is_controller() && q.get("include_inactive").is_some_and(|v| v == "true");
    let mut conn = st.pool.acquire().await?;

    let teams: Vec<TeamRow> = sqlx::query_as(
        "select id::int as id, code, name, sort::int as sort from team order by sort, id",
    )
    .fetch_all(&mut *conn)
    .await?;

    let persons: Vec<PersonRow> = sqlx::query_as(
        "select id, full_name, email, app_role::text as app_role, active
         from person where active or $1 order by full_name, id",
    )
    .bind(all)
    .fetch_all(&mut *conn)
    .await?;

    let assignments = assignments_json(&mut conn, None, all).await?;

    Ok(Json(json!({
        "teams": teams.iter().map(|t| team_json(t.id, &t.code, &t.name, t.sort)).collect::<Vec<_>>(),
        "persons": persons.iter()
            .map(|p| person_json(p, user.is_controller() || p.id == user.person_id))
            .collect::<Vec<_>>(),
        "assignments": assignments,
    })))
}
