//! Managers shape the catalog here: teams, people, seats and what each seat counts.
//! Every route is manager only.

use std::collections::{HashMap, HashSet};

use axum::{
    extract::{Path, State},
    http::StatusCode,
    routing::{patch, post, put},
    Json, Router,
};
use serde::{Deserialize, Deserializer};
use serde_json::Value;
use sqlx::PgConnection;
use uuid::Uuid;

use super::catalog::{assignments_json, load_person, person_json, team_json};
use crate::{
    auth::AuthUser,
    error::{parse_id, ApiError, ApiJson},
    rules::{self, Entry},
    state::AppState,
};

pub fn router() -> Router<AppState> {
    Router::new()
        .route("/teams", post(create_team))
        .route("/teams/{id}", patch(update_team).delete(delete_team))
        .route("/persons", post(create_person))
        .route("/persons/{id}", patch(update_person))
        .route("/persons/{id}/sign-in-link", post(create_sign_in_link))
        .route("/assignments", post(create_assignment))
        .route("/assignments/{id}", patch(update_assignment))
        .route("/assignments/{id}/definitions", put(save_definitions))
}

/// A number sent as 3 or as "3".
#[derive(Deserialize)]
#[serde(untagged)]
enum Flex {
    Num(i64),
    Text(String),
}

impl Flex {
    fn int(&self) -> Option<i64> {
        match self {
            Flex::Num(n) => Some(*n),
            Flex::Text(s) => s.trim().parse().ok(),
        }
    }
}

fn flex_opt<'de, D: Deserializer<'de>>(d: D) -> Result<Option<Flex>, D::Error> {
    Option::<Flex>::deserialize(d)
}

fn team_id_of(f: &Flex) -> Result<i32, ApiError> {
    f.int()
        .and_then(|n| i32::try_from(n).ok())
        .filter(|n| (1..=i64::from(i16::MAX) as i32).contains(n))
        .ok_or_else(|| ApiError::bad("Choose a team."))
}

fn unique_violation(e: &sqlx::Error) -> bool {
    matches!(e, sqlx::Error::Database(d) if d.is_unique_violation())
}

fn fk_violation(e: &sqlx::Error) -> bool {
    matches!(e, sqlx::Error::Database(d) if d.is_foreign_key_violation())
}

// ---------- teams ----------

#[derive(Deserialize)]
struct TeamBody {
    name: String,
}

type TeamTuple = (i32, String, String, i32);

async fn team_name_taken(
    conn: &mut PgConnection,
    name: &str,
    except: Option<i32>,
) -> Result<bool, ApiError> {
    Ok(sqlx::query_scalar::<_, bool>(
        "select exists(select 1 from team where lower(name) = lower($1) and ($2::int is null or id <> $2))",
    )
    .bind(name)
    .bind(except)
    .fetch_one(conn)
    .await?)
}

const TEAM_NAME_TAKEN: &str = "That team name is already used.";

async fn create_team(
    user: AuthUser,
    State(st): State<AppState>,
    ApiJson(body): ApiJson<TeamBody>,
) -> Result<(StatusCode, Json<Value>), ApiError> {
    user.require_controller()?;
    let name = rules::clean_team_name(&body.name)?;
    let mut tx = st.pool.begin().await?;
    sqlx::query("select pg_advisory_xact_lock(hashtextextended('xt_team', 0))")
        .execute(&mut *tx)
        .await?;
    if team_name_taken(&mut tx, &name, None).await? {
        return Err(ApiError::Conflict(TEAM_NAME_TAKEN.into()));
    }
    let codes: Vec<String> = sqlx::query_scalar("select code from team")
        .fetch_all(&mut *tx)
        .await?;
    let code = rules::unique_slug(&rules::slug(&name), &codes.into_iter().collect());
    let row: TeamTuple = sqlx::query_as(
        "insert into team (code, name, sort)
         values ($1, $2, coalesce((select max(sort) from team), 0) + 1)
         returning id::int, code, name, sort::int",
    )
    .bind(&code)
    .bind(&name)
    .fetch_one(&mut *tx)
    .await
    .map_err(|e| {
        if unique_violation(&e) {
            ApiError::Conflict(TEAM_NAME_TAKEN.into())
        } else {
            e.into()
        }
    })?;
    tx.commit().await?;
    Ok((
        StatusCode::CREATED,
        Json(team_json(row.0, &row.1, &row.2, row.3)),
    ))
}

#[derive(Deserialize)]
struct TeamPatch {
    #[serde(default)]
    name: Option<String>,
    #[serde(default)]
    sort: Option<i64>,
}

fn team_id_from_path(s: &str) -> Result<i32, ApiError> {
    s.parse::<i16>()
        .map(i32::from)
        .map_err(|_| ApiError::not_found("That team does not exist."))
}

async fn update_team(
    user: AuthUser,
    State(st): State<AppState>,
    Path(id): Path<String>,
    ApiJson(body): ApiJson<TeamPatch>,
) -> Result<Json<Value>, ApiError> {
    user.require_controller()?;
    let id = team_id_from_path(&id)?;
    let name = body
        .name
        .as_deref()
        .map(rules::clean_team_name)
        .transpose()?;
    let sort = body.sort.map(rules::check_sort).transpose()?;
    let mut tx = st.pool.begin().await?;
    if let Some(n) = &name {
        if team_name_taken(&mut tx, n, Some(id)).await? {
            return Err(ApiError::Conflict(TEAM_NAME_TAKEN.into()));
        }
    }
    let row: Option<TeamTuple> = sqlx::query_as(
        "update team set name = coalesce($2, name), sort = coalesce($3::smallint, sort)
         where id = $1 returning id::int, code, name, sort::int",
    )
    .bind(id)
    .bind(name)
    .bind(sort)
    .fetch_optional(&mut *tx)
    .await
    .map_err(|e| {
        if unique_violation(&e) {
            ApiError::Conflict(TEAM_NAME_TAKEN.into())
        } else {
            e.into()
        }
    })?;
    tx.commit().await?;
    let row = row.ok_or_else(|| ApiError::not_found("That team does not exist."))?;
    Ok(Json(team_json(row.0, &row.1, &row.2, row.3)))
}

async fn delete_team(
    user: AuthUser,
    State(st): State<AppState>,
    Path(id): Path<String>,
) -> Result<StatusCode, ApiError> {
    user.require_controller()?;
    let id = team_id_from_path(&id)?;
    let mut tx = st.pool.begin().await?;
    let exists: Option<i32> =
        sqlx::query_scalar("select id::int from team where id = $1 for update")
            .bind(id)
            .fetch_optional(&mut *tx)
            .await?;
    if exists.is_none() {
        return Err(ApiError::not_found("That team does not exist."));
    }
    let seats: i64 = sqlx::query_scalar("select count(*) from assignment where team_id = $1")
        .bind(id)
        .fetch_one(&mut *tx)
        .await?;
    if seats > 0 {
        return Err(ApiError::Conflict(
            "Move or remove the seats of this team first.".into(),
        ));
    }
    sqlx::query("delete from team where id = $1")
        .bind(id)
        .execute(&mut *tx)
        .await?;
    tx.commit().await?;
    Ok(StatusCode::NO_CONTENT)
}

// ---------- persons ----------

const EMAIL_TAKEN: &str = "That email is already used.";
const LAST_MANAGER: &str = "There must be at least one manager.";

#[derive(Deserialize)]
struct PersonBody {
    full_name: String,
    /// Optional: when missing or blank the server makes an internal address from the name.
    #[serde(default)]
    email: Option<String>,
    app_role: String,
}

async fn email_taken(
    conn: &mut PgConnection,
    email: &str,
    except: Option<Uuid>,
) -> Result<bool, ApiError> {
    Ok(sqlx::query_scalar::<_, bool>(
        "select exists(select 1 from person where lower(email) = $1 and ($2::uuid is null or id <> $2))",
    )
    .bind(email)
    .bind(except)
    .fetch_one(conn)
    .await?)
}

async fn create_person(
    user: AuthUser,
    State(st): State<AppState>,
    ApiJson(body): ApiJson<PersonBody>,
) -> Result<(StatusCode, Json<Value>), ApiError> {
    user.require_controller()?;
    let name = rules::clean_person_name(&body.full_name)?;
    let given = body.email.as_deref().filter(|e| !e.trim().is_empty());
    let given = given.map(rules::clean_email).transpose()?;
    let role = rules::clean_app_role(&body.app_role)?;
    let mut tx = st.pool.begin().await?;
    let email = match given {
        Some(e) => e,
        None => {
            // One generator at a time, so two new people cannot pick the same address.
            sqlx::query("select pg_advisory_xact_lock(hashtextextended('xt_person_email', 0))")
                .execute(&mut *tx)
                .await?;
            let domain = st
                .config
                .internal_email_domains
                .first()
                .cloned()
                .unwrap_or_else(|| crate::config::DEFAULT_INTERNAL_DOMAIN.into());
            crate::signin::free_internal_email(&mut tx, &name, &domain).await?
        }
    };
    if email_taken(&mut tx, &email, None).await? {
        return Err(ApiError::Conflict(EMAIL_TAKEN.into()));
    }
    let id: Uuid = sqlx::query_scalar(
        "insert into person (full_name, email, app_role) values ($1, $2, $3::app_role) returning id",
    )
    .bind(&name)
    .bind(&email)
    .bind(&role)
    .fetch_one(&mut *tx)
    .await
    .map_err(|e| {
        if unique_violation(&e) {
            ApiError::Conflict(EMAIL_TAKEN.into())
        } else {
            e.into()
        }
    })?;
    let person = load_person(&mut tx, id).await?.ok_or(ApiError::Internal)?;
    tx.commit().await?;
    Ok((StatusCode::CREATED, Json(person_json(&person, true))))
}

#[derive(Deserialize)]
struct PersonPatch {
    #[serde(default)]
    full_name: Option<String>,
    #[serde(default)]
    email: Option<String>,
    #[serde(default)]
    app_role: Option<String>,
    #[serde(default)]
    active: Option<bool>,
}

async fn update_person(
    user: AuthUser,
    State(st): State<AppState>,
    Path(id): Path<String>,
    ApiJson(body): ApiJson<PersonPatch>,
) -> Result<Json<Value>, ApiError> {
    user.require_controller()?;
    let id = parse_id(&id).map_err(|_| ApiError::not_found("That person does not exist."))?;
    let name = body
        .full_name
        .as_deref()
        .map(rules::clean_person_name)
        .transpose()?;
    let email = body.email.as_deref().map(rules::clean_email).transpose()?;
    let role = body
        .app_role
        .as_deref()
        .map(rules::clean_app_role)
        .transpose()?;

    let mut tx = st.pool.begin().await?;
    // One at a time, so two requests cannot each leave "the other" manager standing.
    sqlx::query("select pg_advisory_xact_lock(hashtextextended('xt_managers', 0))")
        .execute(&mut *tx)
        .await?;
    let cur = load_person(&mut tx, id)
        .await?
        .ok_or_else(|| ApiError::not_found("That person does not exist."))?;
    if let Some(e) = &email {
        if email_taken(&mut tx, e, Some(id)).await? {
            return Err(ApiError::Conflict(EMAIL_TAKEN.into()));
        }
    }
    let new_role = role.clone().unwrap_or_else(|| cur.app_role.clone());
    let new_active = body.active.unwrap_or(cur.active);
    let was_manager = cur.active && cur.app_role == "controller";
    let will_be_manager = new_active && new_role == "controller";
    if was_manager && !will_be_manager {
        let others: i64 = sqlx::query_scalar(
            "select count(*) from person where active and app_role = 'controller' and id <> $1",
        )
        .bind(id)
        .fetch_one(&mut *tx)
        .await?;
        if others == 0 {
            return Err(ApiError::Conflict(LAST_MANAGER.into()));
        }
    }
    sqlx::query(
        "update person set full_name = coalesce($2, full_name), email = coalesce($3, email),
                app_role = $4::app_role, active = $5 where id = $1",
    )
    .bind(id)
    .bind(name)
    .bind(email)
    .bind(&new_role)
    .bind(new_active)
    .execute(&mut *tx)
    .await
    .map_err(|e| {
        if unique_violation(&e) {
            ApiError::Conflict(EMAIL_TAKEN.into())
        } else {
            e.into()
        }
    })?;
    let person = load_person(&mut tx, id).await?.ok_or(ApiError::Internal)?;
    tx.commit().await?;
    Ok(Json(person_json(&person, true)))
}

#[derive(Deserialize)]
struct SignInLinkBody {
    /// 1 to 168, default 24. Kept as raw JSON so "2.5" or "1" (text) get our plain message.
    #[serde(default)]
    hours: Option<Value>,
}

/// A one-time sign-in link for a person, to share privately (chat, in person).
async fn create_sign_in_link(
    user: AuthUser,
    State(st): State<AppState>,
    Path(id): Path<String>,
    ApiJson(body): ApiJson<SignInLinkBody>,
) -> Result<(StatusCode, Json<Value>), ApiError> {
    use crate::signin::{self, msg};
    user.require_controller()?;
    let id = parse_id(&id).map_err(|_| ApiError::not_found("That person does not exist."))?;
    let hours = match &body.hours {
        None | Some(Value::Null) => signin::LINK_HOURS_DEFAULT,
        Some(v) => v
            .as_i64()
            .filter(|h| (signin::LINK_HOURS_MIN..=signin::LINK_HOURS_MAX).contains(h))
            .ok_or_else(|| ApiError::bad(msg::HOURS_INVALID))?,
    };
    let mut tx = st.pool.begin().await?;
    let cur = load_person(&mut tx, id)
        .await?
        .ok_or_else(|| ApiError::not_found("That person does not exist."))?;
    if !cur.active {
        return Err(ApiError::Conflict(msg::SWITCHED_OFF.into()));
    }
    // Serialise per issuing manager so parallel requests cannot all pass the count.
    sqlx::query("select pg_advisory_xact_lock(hashtextextended($1::text, 0))")
        .bind(format!("xt_sign_in_link:{}", user.person_id))
        .execute(&mut *tx)
        .await?;
    let recent: i64 = sqlx::query_scalar(
        "select count(*) from sign_in_link_audit
         where issued_by = $1 and issued_at > now() - interval '1 hour'",
    )
    .bind(user.person_id)
    .fetch_one(&mut *tx)
    .await?;
    if recent >= signin::MAX_SIGN_IN_LINKS_PER_HOUR {
        let wait: Option<i64> = sqlx::query_scalar(
            "select ceil(extract(epoch from (issued_at + interval '1 hour' - now())))::bigint
             from sign_in_link_audit
             where issued_by = $1 and issued_at > now() - interval '1 hour'
             order by issued_at
             offset greatest((select count(*) from sign_in_link_audit
                              where issued_by = $1 and issued_at > now() - interval '1 hour') - $2, 0)
             limit 1",
        )
        .bind(user.person_id)
        .bind(signin::MAX_SIGN_IN_LINKS_PER_HOUR)
        .fetch_optional(&mut *tx)
        .await?;
        return Err(ApiError::TooManyRequests(
            msg::TOO_MANY.into(),
            wait.unwrap_or(3600).clamp(1, 3600) as u64,
        ));
    }
    let link = signin::create_sign_in_link(
        &mut tx,
        &st.config.public_url,
        id,
        hours,
        Some(user.person_id),
    )
    .await?;
    tx.commit().await?;
    Ok((
        StatusCode::CREATED,
        Json(serde_json::json!({
            "url": link.url,
            "expires_at": link.expires_at_rfc3339(),
            "person_id": link.person_id,
        })),
    ))
}

// ---------- seats ----------

const SEAT_TAKEN: &str = "That person already has this role in this team.";

#[derive(Deserialize)]
struct AssignmentBody {
    person_id: Uuid,
    team_id: Flex,
    role_title: String,
}

async fn team_exists(conn: &mut PgConnection, id: i32) -> Result<bool, ApiError> {
    Ok(
        sqlx::query_scalar::<_, bool>("select exists(select 1 from team where id = $1)")
            .bind(id)
            .fetch_one(conn)
            .await?,
    )
}

async fn create_assignment(
    user: AuthUser,
    State(st): State<AppState>,
    ApiJson(body): ApiJson<AssignmentBody>,
) -> Result<(StatusCode, Json<Value>), ApiError> {
    user.require_controller()?;
    let team = team_id_of(&body.team_id)?;
    let title = rules::clean_role_title(&body.role_title)?;
    let mut tx = st.pool.begin().await?;
    sqlx::query("select pg_advisory_xact_lock(hashtextextended('xt_seat', 0))")
        .execute(&mut *tx)
        .await?;
    let person = load_person(&mut tx, body.person_id)
        .await?
        .ok_or_else(|| ApiError::bad("Choose a person."))?;
    if !team_exists(&mut tx, team).await? {
        return Err(ApiError::bad("Choose a team."));
    }
    let dup: bool = sqlx::query_scalar(
        "select exists(select 1 from assignment where person_id = $1 and team_id = $2 and lower(btrim(role_title)) = lower($3))",
    )
    .bind(person.id)
    .bind(team)
    .bind(&title)
    .fetch_one(&mut *tx)
    .await?;
    if dup {
        return Err(ApiError::Conflict(SEAT_TAKEN.into()));
    }
    let codes: HashSet<String> = sqlx::query_scalar::<_, String>("select code from assignment")
        .fetch_all(&mut *tx)
        .await?
        .into_iter()
        .collect();
    let code = rules::unique_slug(
        &rules::slug(&format!("{} {}", person.full_name, title)),
        &codes,
    );
    let id: Uuid = sqlx::query_scalar(
        "insert into assignment (code, person_id, team_id, role_title, sort)
         values ($1, $2, $3, $4,
                 coalesce((select max(sort) from assignment where team_id = $3), 0) + 1)
         returning id",
    )
    .bind(&code)
    .bind(person.id)
    .bind(team)
    .bind(&title)
    .fetch_one(&mut *tx)
    .await
    .map_err(|e| {
        if unique_violation(&e) {
            ApiError::Conflict(SEAT_TAKEN.into())
        } else if fk_violation(&e) {
            // The team or person was deleted a moment ago.
            ApiError::bad("Choose a team.")
        } else {
            e.into()
        }
    })?;
    let mut rows = assignments_json(&mut tx, Some(id), true).await?;
    tx.commit().await?;
    Ok((StatusCode::CREATED, Json(rows.remove(0))))
}

#[derive(Deserialize)]
struct AssignmentPatch {
    #[serde(default, deserialize_with = "flex_opt")]
    team_id: Option<Flex>,
    #[serde(default)]
    role_title: Option<String>,
    #[serde(default)]
    active: Option<bool>,
    #[serde(default)]
    sort: Option<i64>,
}

fn seat_id(s: &str) -> Result<Uuid, ApiError> {
    parse_id(s).map_err(|_| ApiError::not_found("That seat does not exist."))
}

async fn update_assignment(
    user: AuthUser,
    State(st): State<AppState>,
    Path(id): Path<String>,
    ApiJson(body): ApiJson<AssignmentPatch>,
) -> Result<Json<Value>, ApiError> {
    user.require_controller()?;
    let id = seat_id(&id)?;
    let team = body.team_id.as_ref().map(team_id_of).transpose()?;
    let title = body
        .role_title
        .as_deref()
        .map(rules::clean_role_title)
        .transpose()?;
    let sort = body.sort.map(rules::check_sort).transpose()?;

    let mut tx = st.pool.begin().await?;
    let cur: Option<(Uuid, i32, String)> = sqlx::query_as(
        "select person_id, team_id::int, role_title from assignment where id = $1 for update",
    )
    .bind(id)
    .fetch_optional(&mut *tx)
    .await?;
    let (person_id, cur_team, cur_title) =
        cur.ok_or_else(|| ApiError::not_found("That seat does not exist."))?;
    let new_team = team.unwrap_or(cur_team);
    let new_title = title.unwrap_or(cur_title);
    if team.is_some() && !team_exists(&mut tx, new_team).await? {
        return Err(ApiError::bad("Choose a team."));
    }
    let dup: bool = sqlx::query_scalar(
        "select exists(select 1 from assignment
                       where person_id = $1 and team_id = $2 and lower(btrim(role_title)) = lower($3) and id <> $4)",
    )
    .bind(person_id)
    .bind(new_team)
    .bind(&new_title)
    .bind(id)
    .fetch_one(&mut *tx)
    .await?;
    if dup {
        return Err(ApiError::Conflict(SEAT_TAKEN.into()));
    }
    sqlx::query(
        "update assignment set team_id = $2, role_title = $3,
                active = coalesce($4, active), sort = coalesce($5::smallint, sort)
         where id = $1",
    )
    .bind(id)
    .bind(new_team)
    .bind(&new_title)
    .bind(body.active)
    .bind(sort)
    .execute(&mut *tx)
    .await
    .map_err(|e| {
        if unique_violation(&e) {
            ApiError::Conflict(SEAT_TAKEN.into())
        } else if fk_violation(&e) {
            // The team or person was deleted a moment ago.
            ApiError::bad("Choose a team.")
        } else {
            e.into()
        }
    })?;
    let mut rows = assignments_json(&mut tx, Some(id), true).await?;
    tx.commit().await?;
    Ok(Json(rows.remove(0)))
}

// ---------- counts and targets of a seat ----------

#[derive(Deserialize)]
struct MetricBody {
    #[serde(default)]
    id: Option<Uuid>,
    label: String,
}

#[derive(Deserialize)]
struct KpiBody {
    #[serde(default)]
    id: Option<Uuid>,
    text: String,
}

#[derive(Deserialize)]
struct DefinitionsBody {
    #[serde(default)]
    metrics: Vec<MetricBody>,
    #[serde(default)]
    kpis: Vec<KpiBody>,
}

const NOT_THIS_SEAT: &str = "One of the counts or targets does not belong to this seat.";

async fn save_definitions(
    user: AuthUser,
    State(st): State<AppState>,
    Path(id): Path<String>,
    ApiJson(body): ApiJson<DefinitionsBody>,
) -> Result<Json<Value>, ApiError> {
    user.require_controller()?;
    let id = seat_id(&id)?;
    let metrics = rules::check_metrics(
        &body
            .metrics
            .iter()
            .map(|m| (m.id, m.label.clone()))
            .collect::<Vec<_>>(),
    )?;
    let kpis = rules::check_kpis(
        &body
            .kpis
            .iter()
            .map(|k| (k.id, k.text.clone()))
            .collect::<Vec<_>>(),
    )?;

    let mut tx = st.pool.begin().await?;
    let seat: Option<Uuid> =
        sqlx::query_scalar("select id from assignment where id = $1 for update")
            .bind(id)
            .fetch_optional(&mut *tx)
            .await?;
    if seat.is_none() {
        return Err(ApiError::not_found("That seat does not exist."));
    }
    save_metrics(&mut tx, id, &metrics).await?;
    save_kpis(&mut tx, id, &kpis).await?;
    let mut rows = assignments_json(&mut tx, Some(id), true).await?;
    tx.commit().await?;
    Ok(Json(rows.remove(0)))
}

async fn save_metrics(
    tx: &mut PgConnection,
    seat: Uuid,
    entries: &[Entry],
) -> Result<(), ApiError> {
    let live: HashSet<Uuid> = sqlx::query_scalar::<_, Uuid>(
        "select id from metric_def where assignment_id = $1 and retired_at is null",
    )
    .bind(seat)
    .fetch_all(&mut *tx)
    .await?
    .into_iter()
    .collect();
    let keep: Vec<Uuid> = entries.iter().filter_map(|e| e.id).collect();
    if keep.iter().any(|k| !live.contains(k)) {
        return Err(ApiError::bad(NOT_THIS_SEAT));
    }
    let mut keys: HashSet<String> =
        sqlx::query_scalar::<_, String>("select key from metric_def where assignment_id = $1")
            .bind(seat)
            .fetch_all(&mut *tx)
            .await?
            .into_iter()
            .collect();

    // Counts that are no longer listed are retired; their old values stay with them.
    sqlx::query(
        "update metric_def set retired_at = now()
         where assignment_id = $1 and retired_at is null and id <> all($2)",
    )
    .bind(seat)
    .bind(&keep)
    .execute(&mut *tx)
    .await?;
    // Park the kept ones in a temporary range so the new order cannot collide
    // with the unique index on (assignment, series) while rows move one by one.
    for (pos, e) in entries.iter().enumerate() {
        if let Some(mid) = e.id {
            sqlx::query("update metric_def set label = $2, series = $3 where id = $1")
                .bind(mid)
                .bind(&e.text)
                .bind(1000 + pos as i16)
                .execute(&mut *tx)
                .await?;
        }
    }
    for (pos, e) in entries.iter().enumerate() {
        if e.id.is_none() {
            let key = rules::unique_slug(&rules::slug(&e.text), &keys);
            keys.insert(key.clone());
            sqlx::query(
                "insert into metric_def (assignment_id, key, label, series) values ($1, $2, $3, $4)",
            )
            .bind(seat)
            .bind(&key)
            .bind(&e.text)
            .bind(pos as i16)
            .execute(&mut *tx)
            .await?;
        }
    }
    for (pos, e) in entries.iter().enumerate() {
        if let Some(mid) = e.id {
            sqlx::query("update metric_def set series = $2 where id = $1")
                .bind(mid)
                .bind(pos as i16)
                .execute(&mut *tx)
                .await?;
        }
    }
    Ok(())
}

async fn save_kpis(tx: &mut PgConnection, seat: Uuid, entries: &[Entry]) -> Result<(), ApiError> {
    let live: HashMap<Uuid, String> = sqlx::query_as::<_, (Uuid, String)>(
        "select id, text from kpi_def where assignment_id = $1 and retired_at is null",
    )
    .bind(seat)
    .fetch_all(&mut *tx)
    .await?
    .into_iter()
    .collect();
    let keep: Vec<Uuid> = entries.iter().filter_map(|e| e.id).collect();
    if keep.iter().any(|k| !live.contains_key(k)) {
        return Err(ApiError::bad(NOT_THIS_SEAT));
    }
    // Changing the wording retires the old row and adds a new one, so reports
    // already sent keep the wording they were answered against.
    let changed: Vec<Uuid> = entries
        .iter()
        .filter(|e| e.id.is_some_and(|k| live.get(&k) != Some(&e.text)))
        .filter_map(|e| e.id)
        .collect();
    let unchanged: Vec<Uuid> = keep
        .iter()
        .copied()
        .filter(|k| !changed.contains(k))
        .collect();
    sqlx::query(
        "update kpi_def set retired_at = now()
         where assignment_id = $1 and retired_at is null and id <> all($2)",
    )
    .bind(seat)
    .bind(&unchanged)
    .execute(&mut *tx)
    .await?;
    for (pos, e) in entries.iter().enumerate() {
        let sort = pos as i16 + 1;
        match e.id.filter(|k| unchanged.contains(k)) {
            Some(kid) => {
                sqlx::query("update kpi_def set sort = $2 where id = $1")
                    .bind(kid)
                    .bind(sort)
                    .execute(&mut *tx)
                    .await?;
            }
            None => {
                sqlx::query("insert into kpi_def (assignment_id, sort, text) values ($1, $2, $3)")
                    .bind(seat)
                    .bind(sort)
                    .bind(&e.text)
                    .execute(&mut *tx)
                    .await?;
            }
        }
    }
    Ok(())
}
