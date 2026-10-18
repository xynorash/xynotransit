//! One Postgres LISTEN connection, fanned out to every open browser.

use std::time::Duration;

use sqlx::{postgres::PgListener, PgPool};
use tokio::sync::{broadcast, oneshot};

use crate::state::ChangeEvent;

pub const CHANNEL: &str = "xt_changes";

/// Start the listener task. Resolves once it is listening (or has failed once),
/// so callers and tests know changes made afterwards will be seen.
pub async fn start(
    pool: PgPool,
    tx: broadcast::Sender<ChangeEvent>,
) -> tokio::task::JoinHandle<()> {
    let (ready_tx, ready_rx) = oneshot::channel::<()>();
    let handle = tokio::spawn(run(pool, tx, Some(ready_tx)));
    let _ = tokio::time::timeout(Duration::from_secs(5), ready_rx).await;
    handle
}

async fn run(
    pool: PgPool,
    tx: broadcast::Sender<ChangeEvent>,
    mut ready: Option<oneshot::Sender<()>>,
) {
    let mut backoff = Duration::from_millis(500);
    loop {
        match listen_once(&pool, &tx, &mut ready).await {
            Ok(()) => backoff = Duration::from_millis(500),
            Err(e) => tracing::warn!(error = %e, "change listener lost, reconnecting"),
        }
        if let Some(r) = ready.take() {
            let _ = r.send(());
        }
        tokio::time::sleep(backoff).await;
        backoff = (backoff * 2).min(Duration::from_secs(10));
    }
}

async fn listen_once(
    pool: &PgPool,
    tx: &broadcast::Sender<ChangeEvent>,
    ready: &mut Option<oneshot::Sender<()>>,
) -> Result<(), sqlx::Error> {
    let mut listener = PgListener::connect_with(pool).await?;
    listener.listen(CHANNEL).await?;
    if let Some(r) = ready.take() {
        let _ = r.send(());
    }
    loop {
        let note = listener.recv().await?;
        match serde_json::from_str::<ChangeEvent>(note.payload()) {
            Ok(ev) => {
                // No receivers is fine: nobody has the page open.
                let _ = tx.send(ev);
            }
            Err(e) => tracing::warn!(error = %e, "ignored a change message"),
        }
    }
}
