use std::time::Duration;

use sqlx::postgres::{PgConnectOptions, PgPoolOptions};
use xynotransit_api::{
    bootstrap_controller, config::Config, listener, mail::Mailer, serve, state::AppState,
};

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    if std::env::args().nth(1).as_deref() == Some("healthcheck") {
        std::process::exit(if healthcheck() { 0 } else { 1 });
    }
    // LOG_FORMAT=json writes one JSON object per line (for a log collector); anything else is text.
    let filter = tracing_subscriber::EnvFilter::try_from_default_env()
        .unwrap_or_else(|_| "info,sqlx=warn".into());
    if std::env::var("LOG_FORMAT").is_ok_and(|v| v.eq_ignore_ascii_case("json")) {
        tracing_subscriber::fmt()
            .json()
            .with_env_filter(filter)
            .with_current_span(true)
            .init();
    } else {
        tracing_subscriber::fmt().with_env_filter(filter).init();
    }

    let config = Config::from_env().map_err(|e| anyhow::anyhow!(e))?;
    let pool = connect(&config.database_url).await?;

    if let Some(email) = &config.bootstrap_controller_email {
        let n =
            bootstrap_controller(&pool, email, config.bootstrap_controller_name.as_deref()).await?;
        tracing::info!(changed = n, "bootstrap controller checked");
    }

    let mailer = Mailer::smtp(&config.smtp_host, config.smtp_port, &config.mail_from)?;
    let bind = config.bind;
    let state = AppState::new(pool.clone(), config, mailer);
    listener::start(pool, state.events.clone()).await;

    let tcp = tokio::net::TcpListener::bind(bind).await?;
    tracing::info!(%bind, "listening");

    serve(tcp, state, shutdown_signal()).await?;
    tracing::info!("stopped");
    Ok(())
}

/// The database may still be starting; try for about a minute.
async fn connect(url: &str) -> anyhow::Result<sqlx::PgPool> {
    // Limits on the database side too, so one stuck query or forgotten transaction cannot hold
    // a connection (and a request) forever. Both stay below the 30 second request timeout.
    let options = url
        .parse::<PgConnectOptions>()?
        .application_name("xynotransit-api")
        .options([
            ("statement_timeout", "20000"),
            ("idle_in_transaction_session_timeout", "30000"),
        ]);
    let mut last = None;
    for attempt in 1..=30 {
        match PgPoolOptions::new()
            .max_connections(10)
            .acquire_timeout(Duration::from_secs(10))
            .connect_with(options.clone())
            .await
        {
            Ok(p) => return Ok(p),
            Err(e) => {
                tracing::warn!(attempt, error = %e, "database not ready");
                last = Some(e);
                tokio::time::sleep(Duration::from_secs(2)).await;
            }
        }
    }
    Err(anyhow::anyhow!(
        "could not reach the database: {}",
        last.map(|e| e.to_string()).unwrap_or_default()
    ))
}

async fn shutdown_signal() {
    let ctrl_c = tokio::signal::ctrl_c();
    #[cfg(unix)]
    {
        let mut term = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
            .expect("signal handler");
        tokio::select! { _ = ctrl_c => {}, _ = term.recv() => {} }
    }
    #[cfg(not(unix))]
    {
        let _ = ctrl_c.await;
    }
}

/// Used by the Docker HEALTHCHECK: ask our own /api/health, no curl needed.
fn healthcheck() -> bool {
    use std::io::{Read, Write};
    let port = std::env::var("BIND")
        .ok()
        .and_then(|b| b.rsplit(':').next().and_then(|p| p.parse::<u16>().ok()))
        .unwrap_or(8081);
    let addr = std::net::SocketAddr::from(([127, 0, 0, 1], port));
    let Ok(mut s) = std::net::TcpStream::connect_timeout(&addr, Duration::from_secs(3)) else {
        return false;
    };
    let _ = s.set_read_timeout(Some(Duration::from_secs(3)));
    if s.write_all(b"GET /api/health HTTP/1.0\r\nHost: localhost\r\n\r\n")
        .is_err()
    {
        return false;
    }
    let mut out = String::new();
    let _ = s.read_to_string(&mut out);
    out.starts_with("HTTP/1.0 200") || out.starts_with("HTTP/1.1 200")
}
