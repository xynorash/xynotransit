//! Settings read from environment variables.

use std::net::SocketAddr;

/// How the API talks to the mail server.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SmtpSecurity {
    /// Plain text, for a local catcher such as Mailpit.
    None,
    /// Starts plain, then upgrades the connection (usually port 587).
    StartTls,
    /// Encrypted from the first byte (usually port 465).
    Tls,
}

#[derive(Debug, Clone)]
pub struct Config {
    pub database_url: String,
    pub jwt_secret: String,
    pub public_url: String,
    pub smtp_host: String,
    pub smtp_port: u16,
    pub smtp_security: SmtpSecurity,
    /// Both set or both empty.
    pub smtp_credentials: Option<(String, String)>,
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
        let smtp_security = match non_empty("SMTP_TLS").map(|v| v.to_ascii_lowercase()) {
            None => SmtpSecurity::None,
            Some(v) => match v.as_str() {
                "none" => SmtpSecurity::None,
                "starttls" => SmtpSecurity::StartTls,
                "tls" => SmtpSecurity::Tls,
                _ => return Err("SMTP_TLS must be none, starttls or tls".into()),
            },
        };
        // Spaces around a user name are never meant; the password is kept as typed.
        let smtp_credentials = match (non_empty("SMTP_USERNAME"), get("SMTP_PASSWORD")) {
            (Some(u), Some(p)) if !p.is_empty() => Some((u, p)),
            (None, None) => None,
            (None, Some(p)) if p.is_empty() => None,
            _ => return Err("SMTP_USERNAME and SMTP_PASSWORD must be set together".into()),
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
            smtp_security,
            smtp_credentials,
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
    fn smtp_security_and_credentials_are_checked() {
        let base = [
            ("DATABASE_URL", "postgres://x"),
            ("JWT_SECRET", "0123456789012345678901234567890123"),
        ];
        let with = |extra: &[(&'static str, &'static str)]| {
            let mut p = base.to_vec();
            p.extend_from_slice(extra);
            Config::from_lookup(lookup(&p))
        };
        let c = with(&[]).unwrap();
        assert_eq!(c.smtp_security, SmtpSecurity::None);
        assert!(c.smtp_credentials.is_none());
        let c = with(&[
            ("SMTP_TLS", "StartTLS"),
            ("SMTP_USERNAME", "apikey"),
            ("SMTP_PASSWORD", "s3 cret"),
        ])
        .unwrap();
        assert_eq!(c.smtp_security, SmtpSecurity::StartTls);
        assert_eq!(
            c.smtp_credentials,
            Some(("apikey".to_string(), "s3 cret".to_string()))
        );
        assert_eq!(
            with(&[("SMTP_TLS", "tls")]).unwrap().smtp_security,
            SmtpSecurity::Tls
        );
        assert!(with(&[("SMTP_TLS", "yes")]).is_err());
        assert!(with(&[("SMTP_USERNAME", "u")]).is_err());
        assert!(with(&[("SMTP_PASSWORD", "p")]).is_err());
        // Empty values (as an env file template leaves them) mean "not set".
        assert!(with(&[
            ("SMTP_USERNAME", ""),
            ("SMTP_PASSWORD", ""),
            ("SMTP_TLS", "")
        ])
        .unwrap()
        .smtp_credentials
        .is_none());
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
