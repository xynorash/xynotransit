use std::{
    collections::HashMap,
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};

use serde::{Deserialize, Serialize};
use sqlx::PgPool;
use tokio::sync::{broadcast, watch};
use uuid::Uuid;

use crate::{config::Config, hashing::Hasher, loginlimit::LimitKeys, mail::Mailer};

/// Seconds between two checks of the person behind an open event stream.
pub const STREAM_RECHECK_SECS: u64 = 30;

/// Event tickets: ticket -> (person, session epoch at issue, issue time).
pub type Tickets = HashMap<String, (Uuid, i32, Instant)>;

/// What the database tells us changed: reports of a period, or its deck.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ChangeEvent {
    pub kind: String,
    pub period_id: Uuid,
}

#[derive(Clone)]
pub struct AppState {
    pub pool: PgPool,
    pub config: Arc<Config>,
    pub mailer: Mailer,
    pub events: broadcast::Sender<ChangeEvent>,
    /// ticket -> (person, the person's session epoch when it was made, when it was made)
    pub tickets: Arc<Mutex<Tickets>>,
    pub ticket_ttl: Duration,
    /// How often an open event stream looks the person up again (epoch, active, password, role).
    pub stream_recheck: Duration,
    /// Keys for the sign-in limits (derived from JWT_SECRET).
    pub limit_keys: Arc<LimitKeys>,
    /// Turns true when the server is shutting down; event streams end when they see it.
    pub shutdown: watch::Sender<bool>,
    /// Password hashing, behind a small semaphore.
    pub hasher: Hasher,
}

impl AppState {
    pub fn new(pool: PgPool, config: Config, mailer: Mailer) -> Self {
        let (events, _) = broadcast::channel(256);
        let hasher = Hasher::new(config.password_hash);
        let limit_keys = Arc::new(LimitKeys::new(&config.jwt_secret));
        AppState {
            hasher,
            pool,
            config: Arc::new(config),
            mailer,
            events,
            tickets: Arc::new(Mutex::new(HashMap::new())),
            ticket_ttl: Duration::from_secs(60),
            stream_recheck: Duration::from_secs(STREAM_RECHECK_SECS),
            limit_keys,
            shutdown: watch::channel(false).0,
        }
    }

    pub fn begin_shutdown(&self) {
        self.shutdown.send_replace(true);
    }

    /// Hand out a single-use ticket bound to one person and to the session epoch they have now.
    pub fn issue_ticket(&self, person_id: Uuid, epoch: i32) -> String {
        let ticket = crate::auth::random_token();
        let now = Instant::now();
        let mut map = self.tickets.lock().unwrap_or_else(|e| e.into_inner());
        map.retain(|_, (_, _, at)| now.duration_since(*at) < self.ticket_ttl);
        map.insert(ticket.clone(), (person_id, epoch, now));
        ticket
    }

    /// Use a ticket. It works once, and only while it is fresh. Returns the person and the epoch
    /// the ticket was made under; the caller compares that with the current epoch.
    pub fn redeem_ticket(&self, ticket: &str) -> Option<(Uuid, i32)> {
        let mut map = self.tickets.lock().unwrap_or_else(|e| e.into_inner());
        let (person, epoch, at) = map.remove(ticket)?;
        (at.elapsed() < self.ticket_ttl).then_some((person, epoch))
    }
}
