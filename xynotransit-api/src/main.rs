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
    if std::env::args().nth(1).as_deref() == Some("sign-in-link") {
        let args: Vec<String> = std::env::args().skip(2).collect();
        std::process::exit(sign_in_link_command(&args).await);
    }
    if std::env::args().nth(1).as_deref() == Some("set-password") {
        let args: Vec<String> = std::env::args().skip(2).collect();
        std::process::exit(set_password_command(&args).await);
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
    if config.password_hash.is_below_owasp_minimum() {
        tracing::warn!("password hashing runs below the OWASP minimum (meant for tests only)");
    }
    let pool = connect(&config.database_url).await?;

    if let Some(email) = &config.bootstrap_controller_email {
        let n =
            bootstrap_controller(&pool, email, config.bootstrap_controller_name.as_deref()).await?;
        tracing::info!(changed = n, "bootstrap manager checked");
    }

    let mailer = Mailer::smtp(
        &config.smtp_host,
        config.smtp_port,
        &config.mail_from,
        config.smtp_security,
        config.smtp_credentials.clone(),
    )?;
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

/// `xynotransit-api sign-in-link <email> [--hours N] [--recovery]`: prints only the URL on stdout. Problems go
/// to stderr in plain words. Exit 0 on success, 1 when no link could be made, 2 for wrong usage.
async fn sign_in_link_command(args: &[String]) -> i32 {
    use xynotransit_api::signin::{parse_cli_args, sign_in_link_for_email};
    let (email, hours, recovery) = match parse_cli_args(args) {
        Ok(v) => v,
        Err(e) => {
            eprintln!("{e}");
            return e.exit_code();
        }
    };
    let get = |k: &str| std::env::var(k).ok();
    let Some(url) = get("DATABASE_URL").filter(|u| !u.trim().is_empty()) else {
        eprintln!("DATABASE_URL is not set.");
        return 1;
    };
    let public_url = xynotransit_api::config::public_url_from(get);
    let pool = match sqlx::postgres::PgPoolOptions::new()
        .max_connections(1)
        .acquire_timeout(Duration::from_secs(10))
        .connect(url.trim())
        .await
    {
        Ok(p) => p,
        Err(_) => {
            eprintln!("Could not reach the database. Check DATABASE_URL.");
            return 1;
        }
    };
    match sign_in_link_for_email(&pool, &public_url, &email, hours, recovery).await {
        Ok(link) => {
            println!("{}", link.url);
            0
        }
        Err(e) => {
            eprintln!("{e}");
            e.exit_code()
        }
    }
}

/// Read the new password: from a terminal it is asked twice without echo, otherwise one line of
/// standard input (the line break is cut, nothing else).
fn read_new_password() -> Result<String, passwords::CliError> {
    use passwords::CliError;
    use std::io::{BufRead, IsTerminal};
    if std::io::stdin().is_terminal() {
        let ask = |p: &str| {
            rpassword::prompt_password(p)
                .map_err(|_| CliError::Rejected("Could not read the password.".into()))
        };
        let first = ask("New password: ")?;
        let second = ask("New password again: ")?;
        if first != second {
            return Err(CliError::Rejected(
                "The two passwords are not the same.".into(),
            ));
        }
        return Ok(first);
    }
    let mut line = String::new();
    let n = std::io::stdin()
        .lock()
        .read_line(&mut line)
        .map_err(|_| CliError::Rejected("Could not read the password.".into()))?;
    if n == 0 {
        return Err(CliError::Rejected(
            "No password was given on standard input.".into(),
        ));
    }
    if line.ends_with('\n') {
        line.pop();
        if line.ends_with('\r') {
            line.pop();
        }
    }
    Ok(line)
}

use xynotransit_api::passwords;

/// `xynotransit-api set-password <username-or-email>`: the new password comes from standard
/// input. Prints only "Password set for <username>." on success. Exit 0 on success, 1 when it
/// could not be set, 2 for wrong usage.
async fn set_password_command(args: &[String]) -> i32 {
    let who = match passwords::parse_cli_args(args) {
        Ok(v) => v,
        Err(e) => {
            eprintln!("{e}");
            return e.exit_code();
        }
    };
    let get = |k: &str| std::env::var(k).ok();
    let Some(url) = get("DATABASE_URL").filter(|u| !u.trim().is_empty()) else {
        eprintln!("DATABASE_URL is not set.");
        return 1;
    };
    let settings = match xynotransit_api::config::password_hash_from(&get) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("{e}");
            return 1;
        }
    };
    let pool = match sqlx::postgres::PgPoolOptions::new()
        .max_connections(1)
        .acquire_timeout(Duration::from_secs(10))
        .connect(url.trim())
        .await
    {
        Ok(p) => p,
        Err(_) => {
            eprintln!("Could not reach the database. Check DATABASE_URL.");
            return 1;
        }
    };
    let run = async {
        let person = passwords::find_person(&pool, &who).await?;
        let password = read_new_password()?;
        let hasher = xynotransit_api::hashing::Hasher::new(settings);
        passwords::set_password_for(&pool, &hasher, &person, &password).await?;
        Ok::<_, passwords::CliError>(person.username)
    };
    match run.await {
        Ok(username) => {
            println!("Password set for {username}.");
            0
        }
        Err(e) => {
            eprintln!("{e}");
            e.exit_code()
        }
    }
}
