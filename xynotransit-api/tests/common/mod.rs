#![allow(dead_code)]

pub mod model;

use std::time::Duration;

use axum::{
    body::Body,
    extract::ConnectInfo,
    http::{HeaderMap, Request, StatusCode},
    Router,
};
use http_body_util::BodyExt;
use serde_json::{json, Value};
use sqlx::{postgres::PgPoolOptions, Connection, PgConnection};
use tower::ServiceExt;
use uuid::Uuid;
use xynotransit_api::{build_router, config::Config, mail::Mailer, state::AppState};

pub const ANA: &str = "00000000-0000-0000-0000-0000000000a1";
pub const BEN: &str = "00000000-0000-0000-0000-0000000000a2";
pub const CORA: &str = "00000000-0000-0000-0000-0000000000a3";
pub const A_ANA: &str = "00000000-0000-0000-0000-0000000000d1";
pub const A_BEN: &str = "00000000-0000-0000-0000-0000000000d2";
pub const A_CORA: &str = "00000000-0000-0000-0000-0000000000d3";
pub const M_FILES: &str = "00000000-0000-0000-0000-0000000000b1";
pub const M_CALLS: &str = "00000000-0000-0000-0000-0000000000b2";
pub const M_BOXES: &str = "00000000-0000-0000-0000-0000000000b4";
pub const K_ONTIME: &str = "00000000-0000-0000-0000-0000000000c1";
pub const K_NOERR: &str = "00000000-0000-0000-0000-0000000000c2";
pub const K_SHIP: &str = "00000000-0000-0000-0000-0000000000c4";
pub const K_CALM: &str = "00000000-0000-0000-0000-0000000000c5";
pub const SECRET: &str = "test-secret-test-secret-test-secret-123";

fn admin_url() -> String {
    std::env::var("TEST_ADMIN_URL")
        .unwrap_or_else(|_| "postgres://xynotransit:xynotransit@127.0.0.1:5432/postgres".into())
}

fn db_url(admin: &str, db: &str) -> String {
    let (base, _) = admin.rsplit_once('/').expect("admin url has a database");
    format!("{base}/{db}")
}

/// A throwaway database plus the router on top of it.
pub struct TestApp {
    pub state: AppState,
    pub router: Router,
    db_name: String,
    admin: String,
}

impl TestApp {
    pub async fn new() -> Self {
        Self::with_ticket_ttl(Duration::from_secs(60)).await
    }

    pub async fn with_ticket_ttl(ttl: Duration) -> Self {
        Self::build(ttl, true).await
    }

    /// A fresh install: schema only, no catalog.
    pub async fn empty() -> Self {
        Self::build(Duration::from_secs(60), false).await
    }

    /// Open event streams look the person up again this often (30 seconds in production).
    pub async fn with_stream_recheck(every: Duration) -> Self {
        Self::build_with(Duration::from_secs(60), true, Some(every)).await
    }

    async fn build(ttl: Duration, with_fixture: bool) -> Self {
        Self::build_with(ttl, with_fixture, None).await
    }

    async fn build_with(ttl: Duration, with_fixture: bool, recheck: Option<Duration>) -> Self {
        let admin = admin_url();
        let db_name = format!("xt_test_{}", Uuid::new_v4().simple());
        let mut conn = PgConnection::connect(&admin)
            .await
            .expect("test Postgres must be running (see xynotransit-db)");
        // TEST_TEMPLATE_DB: build the schema from an upgraded copy of a real database instead of
        // the initdb files (scripts/test-migrations.sh uses it); its rows are removed below.
        let template = std::env::var("TEST_TEMPLATE_DB").ok();
        let create = match &template {
            Some(t) => format!("create database {db_name} template \"{t}\""),
            None => format!("create database {db_name}"),
        };
        sqlx::query(&create).execute(&mut conn).await.unwrap();
        let _ = conn.close().await;

        let url = db_url(&admin, &db_name);
        let pool = PgPoolOptions::new()
            .max_connections(8)
            .connect(&url)
            .await
            .unwrap();
        let initdb = concat!(env!("CARGO_MANIFEST_DIR"), "/../xynotransit-db/initdb/");
        if template.is_some() {
            let tables: Vec<String> = sqlx::query_scalar(
                "select tablename::text from pg_tables
                 where schemaname = 'public' and tablename <> 'schema_migration'",
            )
            .fetch_all(&pool)
            .await
            .unwrap();
            let mut tx = pool.begin().await.unwrap();
            sqlx::query("set local xt.allow_deck_delete = 'on'")
                .execute(&mut *tx)
                .await
                .unwrap();
            sqlx::query(&format!(
                "truncate table {} restart identity cascade",
                tables.join(", ")
            ))
            .execute(&mut *tx)
            .await
            .unwrap();
            tx.commit().await.unwrap();
        } else {
            // Every file of initdb in name order, exactly like a fresh install.
            let mut files: Vec<_> = std::fs::read_dir(initdb)
                .unwrap()
                .map(|e| e.unwrap().path())
                .filter(|p| p.extension().is_some_and(|x| x == "sql"))
                .collect();
            files.sort();
            for file in files {
                let sql = std::fs::read_to_string(&file).unwrap();
                sqlx::raw_sql(&sql).execute(&pool).await.unwrap();
            }
        }
        if with_fixture {
            sqlx::raw_sql(include_str!("fixture.sql"))
                .execute(&pool)
                .await
                .unwrap();
        }

        let config = Config::from_lookup(|k| match k {
            "DATABASE_URL" => Some(url.clone()),
            "JWT_SECRET" => Some(SECRET.into()),
            "PUBLIC_URL" => Some("http://127.0.0.1:8080".into()),
            // Cheap Argon2 so the suite stays fast; production uses the OWASP minimum.
            "PASSWORD_HASH_MEMORY_KIB" => Some("64".into()),
            "PASSWORD_HASH_ITERATIONS" => Some("1".into()),
            _ => None,
        })
        .unwrap();
        let mut state = AppState::new(pool, config, Mailer::capture());
        state.ticket_ttl = ttl;
        if let Some(r) = recheck {
            state.stream_recheck = r;
        }
        let router = build_router(state.clone());
        TestApp {
            state,
            router,
            db_name,
            admin,
        }
    }

    pub async fn raw(
        &self,
        method: &str,
        uri: &str,
        token: Option<&str>,
        body: Option<Vec<u8>>,
    ) -> (StatusCode, Vec<u8>) {
        let mut b = Request::builder().method(method).uri(uri);
        if let Some(t) = token {
            b = b.header("authorization", format!("Bearer {t}"));
        }
        let req = if let Some(body) = body {
            b.header("content-type", "application/json")
                .body(Body::from(body))
                .unwrap()
        } else {
            b.body(Body::empty()).unwrap()
        };
        let res = self.router.clone().oneshot(req).await.unwrap();
        let status = res.status();
        let bytes = res.into_body().collect().await.unwrap().to_bytes();
        (status, bytes.to_vec())
    }

    /// Any request with any content type and any bytes; returns status, headers and body.
    pub async fn send(
        &self,
        method: &str,
        uri: &str,
        token: Option<&str>,
        content_type: Option<&str>,
        body: Vec<u8>,
    ) -> (StatusCode, axum::http::HeaderMap, Vec<u8>) {
        let mut b = Request::builder().method(method).uri(uri);
        if let Some(t) = token {
            b = b.header("authorization", format!("Bearer {t}"));
        }
        if let Some(c) = content_type {
            b = b.header("content-type", c);
        }
        let res = self
            .router
            .clone()
            .oneshot(b.body(Body::from(body)).unwrap())
            .await
            .unwrap();
        let (status, headers) = (res.status(), res.headers().clone());
        let bytes = res.into_body().collect().await.unwrap().to_bytes().to_vec();
        (status, headers, bytes)
    }

    /// Back to the fixture catalog: the same three people, two teams, no reports.
    pub async fn reset_fixture(&self) {
        self.wipe().await;
        sqlx::raw_sql(include_str!("fixture.sql"))
            .execute(&self.state.pool)
            .await
            .unwrap();
    }

    pub async fn call(
        &self,
        method: &str,
        uri: &str,
        token: Option<&str>,
        body: Option<Value>,
    ) -> (StatusCode, Value) {
        let (s, bytes) = self
            .raw(
                method,
                uri,
                token,
                body.map(|b| serde_json::to_vec(&b).unwrap()),
            )
            .await;
        let v = if bytes.is_empty() {
            Value::Null
        } else {
            serde_json::from_slice(&bytes).unwrap_or(Value::Null)
        };
        (s, v)
    }

    /// Run the whole magic link flow and return the access token.
    pub async fn login(&self, email: &str) -> String {
        let before = self.state.mailer.sent().len();
        let (s, _) = self
            .call(
                "POST",
                "/api/auth/magic-link",
                None,
                Some(json!({"email": email})),
            )
            .await;
        assert_eq!(s, StatusCode::ACCEPTED);
        let sent = self.state.mailer.sent();
        assert_eq!(sent.len(), before + 1, "a link should have been mailed");
        let link = &sent[before].link;
        let token = link.split("token=").nth(1).unwrap();
        let (s, v) = self
            .call(
                "POST",
                "/api/auth/verify",
                None,
                Some(json!({"token": token})),
            )
            .await;
        assert_eq!(s, StatusCode::OK, "{v}");
        v["access_token"].as_str().unwrap().to_string()
    }

    pub async fn ensure_period(&self, token: &str, start: &str) -> String {
        let (s, v) = self
            .call(
                "POST",
                "/api/periods/ensure",
                Some(token),
                Some(json!({"start_month": start})),
            )
            .await;
        assert_eq!(s, StatusCode::OK, "{v}");
        v["id"].as_str().unwrap().to_string()
    }

    pub async fn put_report(
        &self,
        token: &str,
        period: &str,
        assignment: &str,
        body: Value,
    ) -> (StatusCode, Value) {
        self.call(
            "PUT",
            &format!("/api/periods/{period}/reports/{assignment}"),
            Some(token),
            Some(body),
        )
        .await
    }

    pub async fn count(&self, table: &str) -> i64 {
        sqlx::query_scalar::<_, i64>(&format!("select count(*) from {table}"))
            .fetch_one(&self.state.pool)
            .await
            .unwrap()
    }

    pub async fn scalar(&self, q: &str) -> i64 {
        sqlx::query_scalar::<_, i64>(q)
            .fetch_one(&self.state.pool)
            .await
            .unwrap()
    }

    /// Remove every row (also decks), keeping the schema, so one database can serve many cases.
    pub async fn wipe(&self) {
        let mut tx = self.state.pool.begin().await.unwrap();
        sqlx::query("set local xt.allow_deck_delete = 'on'")
            .execute(&mut *tx)
            .await
            .unwrap();
        sqlx::query(
            "truncate table team, person, assignment, metric_def, kpi_def, period, report,
             report_metric_value, report_kpi_result, report_note, deck_run, deck_run_item,
             deck_text, login_token, login_attempt, login_failure, login_success restart identity cascade",
        )
        .execute(&mut *tx)
        .await
        .unwrap();
        tx.commit().await.unwrap();
    }

    /// A token for a person without the magic link round trip (the link flow is rate limited).
    pub fn token_for(&self, person_id: &str, controller: bool) -> String {
        self.token_for_epoch(person_id, controller, 0)
    }

    /// Like `token_for`, with the session epoch the token claims.
    pub fn token_for_epoch(&self, person_id: &str, controller: bool, epoch: i32) -> String {
        let role = if controller {
            xynotransit_api::auth::Role::Controller
        } else {
            xynotransit_api::auth::Role::Contributor
        };
        xynotransit_api::auth::issue_jwt(SECRET, person_id.parse().unwrap(), role, epoch)
            .unwrap()
            .0
    }

    /// A JSON call as seen from a socket peer (and an optional X-Forwarded-For line), for the
    /// sign-in limits, which count by client address.
    pub async fn call_from(
        &self,
        method: &str,
        uri: &str,
        token: Option<&str>,
        body: Option<Value>,
        peer: &str,
        forwarded_for: Option<&str>,
    ) -> (StatusCode, HeaderMap, Value) {
        let mut b = Request::builder()
            .method(method)
            .uri(uri)
            .header("content-type", "application/json");
        if let Some(t) = token {
            b = b.header("authorization", format!("Bearer {t}"));
        }
        if let Some(x) = forwarded_for {
            b = b.header("x-forwarded-for", x);
        }
        let mut req = b
            .body(Body::from(
                body.map(|b| serde_json::to_vec(&b).unwrap())
                    .unwrap_or_default(),
            ))
            .unwrap();
        let addr: std::net::SocketAddr = format!("{peer}:40000")
            .parse()
            .or_else(|_| format!("[{peer}]:40000").parse())
            .unwrap();
        req.extensions_mut().insert(ConnectInfo(addr));
        let res = self.router.clone().oneshot(req).await.unwrap();
        let (status, headers) = (res.status(), res.headers().clone());
        let bytes = res.into_body().collect().await.unwrap().to_bytes();
        let v = serde_json::from_slice(&bytes).unwrap_or(Value::Null);
        (status, headers, v)
    }

    /// Sign in with a username and password; returns the whole answer.
    pub async fn password_login(&self, username: &str, password: &str) -> (StatusCode, Value) {
        self.call(
            "POST",
            "/api/auth/login",
            None,
            Some(json!({"username": username, "password": password})),
        )
        .await
    }

    /// Give a person a password through the manager's reset and the person's own change, so the
    /// person ends up with `password`, no longer asked to change it. Returns a fresh token.
    pub async fn give_password(&self, person_id: &str, username: &str, password: &str) -> String {
        // The manager may have a password (and so an epoch) already.
        let epoch: i32 = sqlx::query_scalar("select session_epoch from person where id = $1")
            .bind(uuid::Uuid::parse_str(CORA).unwrap())
            .fetch_one(&self.state.pool)
            .await
            .unwrap();
        let manager = self.token_for_epoch(CORA, true, epoch);
        let (s, v) = self
            .call(
                "POST",
                &format!("/api/persons/{person_id}/password-reset"),
                Some(&manager),
                Some(json!({})),
            )
            .await;
        assert_eq!(s, StatusCode::CREATED, "{v}");
        let temp = v["temporary_password"].as_str().unwrap().to_string();
        let (s, v) = self.password_login(username, &temp).await;
        assert_eq!(s, StatusCode::OK, "{v}");
        let tok = v["access_token"].as_str().unwrap().to_string();
        let (s, v) = self
            .call(
                "POST",
                "/api/auth/password",
                Some(&tok),
                Some(json!({"current_password": temp, "new_password": password})),
            )
            .await;
        assert_eq!(s, StatusCode::OK, "{v}");
        v["access_token"].as_str().unwrap().to_string()
    }

    /// A token that began with a link (or a password) `age_minutes` ago.
    pub fn token_via(
        &self,
        person_id: &str,
        controller: bool,
        epoch: i32,
        via: xynotransit_api::auth::Via,
        age_minutes: i64,
    ) -> String {
        let role = if controller {
            xynotransit_api::auth::Role::Controller
        } else {
            xynotransit_api::auth::Role::Contributor
        };
        let at = chrono::Utc::now() - chrono::Duration::minutes(age_minutes);
        xynotransit_api::auth::issue_jwt_at(
            SECRET,
            person_id.parse().unwrap(),
            role,
            epoch,
            via,
            at,
        )
        .unwrap()
        .0
    }

    /// The stored key of a username as typed.
    pub fn user_key(&self, typed: &str) -> String {
        self.state
            .limit_keys
            .user(&xynotransit_api::username::lookup_key(typed))
    }

    /// The stored key of a client address key (`None` is the unknown address).
    pub fn addr_key(&self, addr: Option<&str>) -> String {
        self.state.limit_keys.address(addr)
    }

    /// Write a failure that is `age_minutes` old (what a past wrong try left behind).
    pub async fn add_failure(&self, typed: &str, addr: Option<&str>, age_minutes: i64) {
        sqlx::query(
            "insert into login_failure (username_key, address_key, at)
             values ($1, $2, now() - make_interval(mins => $3::int))",
        )
        .bind(self.user_key(typed))
        .bind(self.addr_key(addr))
        .bind(age_minutes as i32)
        .execute(&self.state.pool)
        .await
        .unwrap();
    }

    /// Write a successful sign-in that is `age_days` old.
    pub async fn add_success(&self, typed: &str, addr: Option<&str>, age_days: i64) {
        sqlx::query(
            "insert into login_success (username_key, address_key, at)
             values ($1, $2, now() - make_interval(days => $3::int))",
        )
        .bind(self.user_key(typed))
        .bind(self.addr_key(addr))
        .bind(age_days as i32)
        .execute(&self.state.pool)
        .await
        .unwrap();
    }

    /// Failures stored for a typed name (all addresses).
    pub async fn failures_of(&self, typed: &str) -> i64 {
        sqlx::query_scalar("select count(*) from login_failure where username_key = $1")
            .bind(self.user_key(typed))
            .fetch_one(&self.state.pool)
            .await
            .unwrap()
    }

    /// Failures stored for a typed name from one address.
    pub async fn pair_failures(&self, typed: &str, addr: Option<&str>) -> i64 {
        sqlx::query_scalar(
            "select count(*) from login_failure where username_key = $1 and address_key = $2",
        )
        .bind(self.user_key(typed))
        .bind(self.addr_key(addr))
        .fetch_one(&self.state.pool)
        .await
        .unwrap()
    }

    pub async fn sql(&self, q: &str) {
        sqlx::query(q).execute(&self.state.pool).await.unwrap();
    }
}

impl Drop for TestApp {
    fn drop(&mut self) {
        let admin = self.admin.clone();
        let name = self.db_name.clone();
        // Own thread and runtime: Drop is sync and the test runtime may be shutting down.
        let _ = std::thread::spawn(move || {
            let rt = tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
                .unwrap();
            rt.block_on(async {
                if let Ok(mut c) = PgConnection::connect(&admin).await {
                    let _ = sqlx::query(&format!("drop database if exists {name} with (force)"))
                        .execute(&mut c)
                        .await;
                }
            });
        })
        .join();
    }
}

pub fn ana_report() -> Value {
    json!({
        "reporter": {"name": "Ana Rakoto", "country": "Tana", "role": "Import"},
        "values": [
            {"metric_def_id": M_FILES, "month_offset": 0, "value": 10},
            {"metric_def_id": M_FILES, "month_offset": 1, "value": 11},
            {"metric_def_id": M_FILES, "month_offset": 2, "value": 12},
            {"metric_def_id": M_CALLS, "month_offset": 0, "value": 0},
            {"metric_def_id": M_CALLS, "month_offset": 1, "value": 5},
            {"metric_def_id": M_CALLS, "month_offset": 2, "value": 6},
        ],
        "kpis": [
            {"kpi_def_id": K_ONTIME, "status": "met", "comment": null},
            {"kpi_def_id": K_NOERR, "status": "partly", "comment": "two slips"},
        ],
        "notes": [
            {"kind": "well", "position": 2, "text": "Second good thing"},
            {"kind": "well", "position": 1, "text": "  First good thing  "},
            {"kind": "next", "position": 1, "text": "Hire one more"},
        ],
    })
}

pub fn ben_report() -> Value {
    json!({
        "reporter": {"name": "Ben Rabe", "country": "Tana", "role": "Export"},
        "values": [
            {"metric_def_id": M_BOXES, "month_offset": 0, "value": 1},
            {"metric_def_id": M_BOXES, "month_offset": 1, "value": 2},
            {"metric_def_id": M_BOXES, "month_offset": 2, "value": 3},
        ],
        "kpis": [{"kpi_def_id": K_SHIP, "status": "missed", "comment": "late trucks"}],
        "notes": [],
    })
}

pub fn cora_report() -> Value {
    json!({
        "reporter": {"name": "Cora Boss", "country": "Antsirabe", "role": "Operations"},
        "values": [],
        "kpis": [{"kpi_def_id": K_CALM, "status": "met"}],
        "notes": [{"kind": "wrong", "position": 1, "text": "Too many meetings"}],
    })
}
