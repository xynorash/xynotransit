use std::collections::HashMap;

use axum::{
    extract::{Path, State},
    http::StatusCode,
    routing::get,
    Json, Router,
};
use chrono::{DateTime, Datelike, NaiveDate, SecondsFormat, Utc};
use serde::Deserialize;
use serde_json::{json, Map, Value};
use sqlx::PgConnection;
use uuid::Uuid;

use super::{periods::find_period, reports::load_reports};
use crate::{
    auth::AuthUser,
    deck_text,
    error::{parse_id, ApiError, ApiJson},
    snapshot::{self, MetricIn, SnapshotInput},
    state::AppState,
};

pub fn router() -> Router<AppState> {
    Router::new()
        .route("/periods/{id}/deck", get(latest).post(generate))
        .route("/periods/{id}/deck-text", get(get_texts).put(put_texts))
}

/// The words in force for a period: its own, else the latest earlier period's, else the defaults.
/// Returns (settings completed with defaults, inherited_from, updated_at).
async fn effective_texts(
    conn: &mut PgConnection,
    period_id: Uuid,
    start: NaiveDate,
) -> Result<(Map<String, Value>, Value, Value), ApiError> {
    let own: Option<(Value, DateTime<Utc>)> =
        sqlx::query_as("select settings, updated_at from deck_text where period_id = $1")
            .bind(period_id)
            .fetch_optional(&mut *conn)
            .await?;
    if let Some((settings, at)) = own {
        let at = at.to_rfc3339_opts(SecondsFormat::Millis, true);
        return Ok((deck_text::complete(&settings), Value::Null, json!(at)));
    }
    let earlier: Option<(Value, NaiveDate)> = sqlx::query_as(
        "select t.settings, p.start_month from deck_text t join period p on p.id = t.period_id
         where p.start_month < $1 order by p.start_month desc limit 1",
    )
    .bind(start)
    .fetch_optional(&mut *conn)
    .await?;
    Ok(match earlier {
        Some((settings, from)) => (
            deck_text::complete(&settings),
            json!(deck_text::period_label(from.year(), from.month())),
            Value::Null,
        ),
        None => (deck_text::defaults(), json!("defaults"), Value::Null),
    })
}

fn texts_json(settings: Map<String, Value>, inherited: Value, updated: Value) -> Value {
    json!({ "settings": settings, "inherited_from": inherited, "updated_at": updated })
}

async fn get_texts(
    _user: AuthUser,
    State(st): State<AppState>,
    Path(period_id): Path<String>,
) -> Result<Json<Value>, ApiError> {
    // Every signed-in active person: employees need the words for their live preview.
    let period_id = parse_id(&period_id)?;
    let mut conn = st.pool.acquire().await?;
    let period = find_period(&mut conn, period_id).await?;
    let (s, i, u) = effective_texts(&mut conn, period_id, period.start_month).await?;
    Ok(Json(texts_json(s, i, u)))
}

#[derive(Deserialize)]
struct PutTexts {
    settings: Map<String, Value>,
}

async fn put_texts(
    user: AuthUser,
    State(st): State<AppState>,
    Path(period_id): Path<String>,
    ApiJson(body): ApiJson<PutTexts>,
) -> Result<Json<Value>, ApiError> {
    user.require_controller()?;
    let period_id = parse_id(&period_id)?;
    let mut tx = st.pool.begin().await?;
    find_period(&mut tx, period_id).await?;
    let settings = deck_text::check_all(&body.settings).map_err(ApiError::bad)?;
    let (at,): (DateTime<Utc>,) = sqlx::query_as(
        "insert into deck_text (period_id, settings, updated_by) values ($1, $2, $3)
         on conflict (period_id) do update
           set settings = excluded.settings, updated_at = now(), updated_by = excluded.updated_by
         returning updated_at",
    )
    .bind(period_id)
    .bind(Value::Object(settings.clone()))
    .bind(user.person_id)
    .fetch_one(&mut *tx)
    .await?;
    tx.commit().await?;
    Ok(Json(texts_json(
        settings,
        Value::Null,
        json!(at.to_rfc3339_opts(SecondsFormat::Millis, true)),
    )))
}

async fn deck_json(conn: &mut PgConnection, run_id: Uuid) -> Result<Value, ApiError> {
    let run: (Uuid, Uuid, DateTime<Utc>, i32, i32, Value) = sqlx::query_as(
        "select id, period_id, generated_at, expected_count, included_count, texts
         from deck_run where id = $1",
    )
    .bind(run_id)
    .fetch_one(&mut *conn)
    .await?;
    let items: Vec<(Uuid, i32, Value)> = sqlx::query_as(
        "select report_id, sort, snapshot from deck_run_item where deck_run_id = $1 order by sort",
    )
    .bind(run_id)
    .fetch_all(&mut *conn)
    .await?;
    Ok(json!({
        "id": run.0.to_string(),
        "period_id": run.1.to_string(),
        "generated_at": run.2.to_rfc3339_opts(SecondsFormat::Millis, true),
        "expected_count": run.3,
        "included_count": run.4,
        "texts": deck_text::complete(&run.5),
        "items": items.into_iter().map(|(r, s, snap)| json!({
            "report_id": r.to_string(), "sort": s, "snapshot": snap,
        })).collect::<Vec<_>>(),
    }))
}

async fn latest(
    user: AuthUser,
    State(st): State<AppState>,
    Path(period_id): Path<String>,
) -> Result<Json<Value>, ApiError> {
    user.require_controller()?;
    let period_id = parse_id(&period_id)?;
    let mut conn = st.pool.acquire().await?;
    find_period(&mut conn, period_id).await?;
    let run: Option<(Uuid,)> = sqlx::query_as(
        "select id from deck_run where period_id = $1 order by generated_at desc, id desc limit 1",
    )
    .bind(period_id)
    .fetch_optional(&mut *conn)
    .await?;
    match run {
        Some((id,)) => Ok(Json(deck_json(&mut conn, id).await?)),
        None => Ok(Json(Value::Null)),
    }
}

#[derive(sqlx::FromRow)]
struct SeatRow {
    report_id: Uuid,
    assignment_id: Uuid,
    code: String,
    full_name: String,
    role_title: String,
    team: String,
}

async fn generate(
    user: AuthUser,
    State(st): State<AppState>,
    Path(period_id): Path<String>,
) -> Result<(StatusCode, Json<Value>), ApiError> {
    user.require_controller()?;
    let period_id = parse_id(&period_id)?;
    let mut tx = st.pool.begin().await?;
    let period = find_period(&mut tx, period_id).await?;
    let start: NaiveDate = period.start_month;

    let (expected,): (i64,) = sqlx::query_as("select count(*) from assignment where active")
        .fetch_one(&mut *tx)
        .await?;

    // Submitted reports in deck order: team, then seat.
    let seats: Vec<SeatRow> = sqlx::query_as(
        "select r.id as report_id, a.id as assignment_id, a.code, p.full_name, a.role_title, t.name as team
         from report r
         join assignment a on a.id = r.assignment_id
         join person p on p.id = a.person_id
         join team t on t.id = a.team_id
         where r.period_id = $1 and r.status = 'submitted' and a.active
         order by t.sort, t.id, a.sort, a.code",
    )
    .bind(period_id)
    .fetch_all(&mut *tx)
    .await?;
    let assignment_ids: Vec<Uuid> = seats.iter().map(|s| s.assignment_id).collect();

    let metric_defs: Vec<(Uuid, Uuid, String, String, i16)> = sqlx::query_as(
        "select id, assignment_id, key, label, series from metric_def
         where assignment_id = any($1) and retired_at is null order by series",
    )
    .bind(&assignment_ids)
    .fetch_all(&mut *tx)
    .await?;
    let kpi_defs: Vec<(Uuid, Uuid, String)> = sqlx::query_as(
        "select id, assignment_id, text from kpi_def
         where assignment_id = any($1) and retired_at is null order by sort, id",
    )
    .bind(&assignment_ids)
    .fetch_all(&mut *tx)
    .await?;

    // Reuse the report loader so values, answers and notes read exactly as the app sees them.
    let reports = load_reports(&mut tx, period_id, None, true).await?;
    let report_by_id: HashMap<String, &Value> = reports
        .iter()
        .filter_map(|r| Some((r["id"].as_str()?.to_string(), r)))
        .collect();

    let mut snapshots = Vec::new();
    for seat in &seats {
        let report = report_by_id
            .get(&seat.report_id.to_string())
            .ok_or(ApiError::Internal)?;
        let value_of = |metric: Uuid, offset: i64| -> i64 {
            report["values"]
                .as_array()
                .into_iter()
                .flatten()
                .find(|v| {
                    v["metric_def_id"].as_str() == Some(metric.to_string().as_str())
                        && v["month_offset"].as_i64() == Some(offset)
                })
                .and_then(|v| v["value"].as_i64())
                .unwrap_or(0)
        };
        let status_of = |kpi: Uuid| -> Option<String> {
            report["kpis"]
                .as_array()
                .into_iter()
                .flatten()
                .find(|k| k["kpi_def_id"].as_str() == Some(kpi.to_string().as_str()))
                .and_then(|k| k["status"].as_str().map(str::to_string))
        };
        let notes_of = |kind: &str| -> Vec<String> {
            let mut v: Vec<(i64, String)> = report["notes"]
                .as_array()
                .into_iter()
                .flatten()
                .filter(|n| n["kind"].as_str() == Some(kind))
                .map(|n| {
                    (
                        n["position"].as_i64().unwrap_or(0),
                        n["text"].as_str().unwrap_or("").to_string(),
                    )
                })
                .collect();
            v.sort_by_key(|n| n.0);
            v.into_iter().map(|n| n.1).collect()
        };

        let (name, role, team) = snapshot::words(
            &report["reporter"],
            (&seat.full_name, &seat.role_title, &seat.team),
        );
        let input = SnapshotInput {
            assignment_code: seat.code.clone(),
            name,
            role,
            team,
            start_month: start,
            metrics: metric_defs
                .iter()
                .filter(|m| m.1 == seat.assignment_id)
                .map(|m| MetricIn {
                    key: m.2.clone(),
                    label: m.3.clone(),
                    series: m.4,
                    values: [value_of(m.0, 0), value_of(m.0, 1), value_of(m.0, 2)],
                })
                .collect(),
            targets: kpi_defs
                .iter()
                .filter(|k| k.1 == seat.assignment_id)
                .map(|k| (k.2.clone(), status_of(k.0)))
                .collect(),
            well: notes_of("well"),
            wrong: notes_of("wrong"),
            next: notes_of("next"),
        };
        snapshots.push(snapshot::build(&input));
    }

    // Freeze the words in force now, in the same transaction as the data.
    let (texts, _, _) = effective_texts(&mut tx, period_id, start).await?;

    let (run_id,): (Uuid,) = sqlx::query_as(
        "insert into deck_run (period_id, generated_by, expected_count, included_count, texts)
         values ($1, $2, $3, $4, $5) returning id",
    )
    .bind(period_id)
    .bind(user.person_id)
    .bind(expected as i32)
    .bind(seats.len() as i32)
    .bind(Value::Object(texts))
    .fetch_one(&mut *tx)
    .await?;
    for (i, (seat, snap)) in seats.iter().zip(snapshots).enumerate() {
        sqlx::query(
            "insert into deck_run_item (deck_run_id, report_id, sort, snapshot) values ($1, $2, $3, $4)",
        )
        .bind(run_id)
        .bind(seat.report_id)
        .bind(i as i32 + 1)
        .bind(snap)
        .execute(&mut *tx)
        .await?;
    }

    let out = deck_json(&mut tx, run_id).await?;
    tx.commit().await?;
    Ok((StatusCode::CREATED, Json(out)))
}
