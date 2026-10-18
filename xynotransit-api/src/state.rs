use std::{
    collections::HashMap,
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};

use serde::{Deserialize, Serialize};
use sqlx::PgPool;
use tokio::sync::broadcast;
use uuid::Uuid;

use crate::{config::Config, mail::Mailer};

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
    pub tickets: Arc<Mutex<HashMap<String, (Uuid, Instant)>>>,
    pub ticket_ttl: Duration,
}

impl AppState {
    pub fn new(pool: PgPool, config: Config, mailer: Mailer) -> Self {
        let (events, _) = broadcast::channel(256);
        AppState {
            pool,
            config: Arc::new(config),
            mailer,
            events,
            tickets: Arc::new(Mutex::new(HashMap::new())),
            ticket_ttl: Duration::from_secs(60),
        }
    }

    /// Hand out a single-use ticket bound to one person.
    pub fn issue_ticket(&self, person_id: Uuid) -> String {
        let ticket = crate::auth::random_token();
        let now = Instant::now();
        let mut map = self.tickets.lock().unwrap_or_else(|e| e.into_inner());
        map.retain(|_, (_, at)| now.duration_since(*at) < self.ticket_ttl);
        map.insert(ticket.clone(), (person_id, now));
        ticket
    }

    /// Use a ticket. It works once, and only while it is fresh.
    pub fn redeem_ticket(&self, ticket: &str) -> Option<Uuid> {
        let mut map = self.tickets.lock().unwrap_or_else(|e| e.into_inner());
        let (person, at) = map.remove(ticket)?;
        (at.elapsed() < self.ticket_ttl).then_some(person)
    }
}
