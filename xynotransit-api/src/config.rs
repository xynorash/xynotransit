//! Settings read from environment variables.

use std::net::SocketAddr;

#[derive(Debug, Clone)]
pub struct Config {
    pub database_url: String,
    pub jwt_secret: String,
    pub public_url: String,
    pub smtp_host: String,
    pub smtp_port: u16,
    pub mail_from: String,
    pub bind: SocketAddr,
    pub bootstrap_controller_email: Option<String>,
    pub bootstrap_controller_name: Option<String>,
    pub log_magic_links: bool,
    /// How long requests that are running get to finish after SIGTERM.
    pub shutdown_grace: std::time::Duration,
}

impl Config {
    pub fn from_env() -> Result<Self, String> {
        Self::from_lookup(|k| std::env::var(k).ok())
    }

    /// Build the config from any key lookup, so tests need no real environment.
    pub fn from_lookup(get: impl Fn(&str) -> Option<String>) -> Result<Self, String> {
        let non_empty = |k: &str| {
            get(k)
                .map(|v| v.trim().to_string())
                .filter(|v| !v.is_empty())
        };

        let database_url = non_empty("DATABASE_URL").ok_or("DATABASE_URL is required")?;
        let jwt_secret = non_empty("JWT_SECRET").ok_or("JWT_SECRET is required")?;
        if jwt_secret.chars().count() < 32 {
            return Err("JWT_SECRET must be at least 32 characters".into());
        }
        let smtp_port = match non_empty("SMTP_PORT") {
            Some(p) => p.parse::<u16>().map_err(|_| "SMTP_PORT must be a number")?,
            None => 1025,
        };
        let bind = non_empty("BIND").unwrap_or_else(|| "0.0.0.0:8081".into());
        let bind = bind
            .parse::<SocketAddr>()
            .map_err(|_| "BIND must look like 0.0.0.0:8081")?;
        let public_url = non_empty("PUBLIC_URL")
            .unwrap_or_else(|| "http://127.0.0.1:8080".into())
            .trim_end_matches('/')
            .to_string();

        Ok(Config {
            database_url,
            jwt_secret,
            public_url,
            smtp_host: non_empty("SMTP_HOST").unwrap_or_else(|| "mailpit".into()),
            smtp_port,
            mail_from: non_empty("MAIL_FROM")
                .unwrap_or_else(|| "Xynotransit <no-reply@xynotransit.local>".into()),
            bind,
            bootstrap_controller_email: non_empty("BOOTSTRAP_CONTROLLER_EMAIL")
                .map(|e| e.to_lowercase()),
            bootstrap_controller_name: non_empty("BOOTSTRAP_CONTROLLER_NAME"),
            log_magic_links: non_empty("LOG_MAGIC_LINKS")
                .map(|v| v.eq_ignore_ascii_case("true") || v == "1")
                .unwrap_or(false),
            shutdown_grace: std::time::Duration::from_secs(
                match non_empty("SHUTDOWN_GRACE_SECS") {
                    Some(v) => v
                        .parse::<u64>()
                        .ok()
                        .filter(|n| (1..=300).contains(n))
                        .ok_or("SHUTDOWN_GRACE_SECS must be a number from 1 to 300")?,
                    None => 8,
                },
            ),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    fn lookup(pairs: &[(&str, &str)]) -> impl Fn(&str) -> Option<String> {
        let m: HashMap<String, String> = pairs
            .iter()
            .map(|(k, v)| (k.to_string(), v.to_string()))
            .collect();
        move |k| m.get(k).cloned()
    }

    #[test]
    fn requires_database_and_secret() {
        assert!(Config::from_lookup(lookup(&[])).is_err());
        assert!(Config::from_lookup(lookup(&[("DATABASE_URL", "postgres://x")])).is_err());
    }

    #[test]
    fn rejects_short_secret() {
        let e = Config::from_lookup(lookup(&[
            ("DATABASE_URL", "postgres://x"),
            ("JWT_SECRET", "too short"),
        ]))
        .unwrap_err();
        assert!(e.contains("32"));
    }

    #[test]
    fn defaults_and_overrides() {
        let c = Config::from_lookup(lookup(&[
            ("DATABASE_URL", "postgres://x"),
            ("JWT_SECRET", "0123456789012345678901234567890123"),
            ("PUBLIC_URL", "http://example.org/"),
            ("LOG_MAGIC_LINKS", "true"),
            ("BOOTSTRAP_CONTROLLER_EMAIL", " Boss@Example.org "),
        ]))
        .unwrap();
        assert_eq!(c.bind.port(), 8081);
        assert_eq!(c.smtp_port, 1025);
        assert_eq!(c.public_url, "http://example.org");
        assert!(c.log_magic_links);
        assert_eq!(c.shutdown_grace.as_secs(), 8);
        assert_eq!(
            c.bootstrap_controller_email.as_deref(),
            Some("boss@example.org")
        );
    }

    #[test]
    fn shutdown_grace_is_checked() {
        let base = [
            ("DATABASE_URL", "postgres://x"),
            ("JWT_SECRET", "0123456789012345678901234567890123"),
        ];
        let with = |v: &'static str| {
            let mut p = base.to_vec();
            p.push(("SHUTDOWN_GRACE_SECS", v));
            Config::from_lookup(lookup(&p))
        };
        assert_eq!(with("20").unwrap().shutdown_grace.as_secs(), 20);
        assert!(with("0").is_err());
        assert!(with("soon").is_err());
        assert!(with("301").is_err());
    }
}
