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
    /// Addresses at these domains never receive mail (lowercase, no `@`). The first one is used
    /// for generated internal addresses.
    pub internal_email_domains: Vec<String>,
    /// How long requests that are running get to finish after SIGTERM.
    pub shutdown_grace: std::time::Duration,
    /// Argon2id parameters for new password hashes. The default is the OWASP minimum; only tests
    /// lower it (PASSWORD_HASH_MEMORY_KIB, PASSWORD_HASH_ITERATIONS).
    pub password_hash: crate::hashing::HashSettings,
    /// Trusted front door (for example a Netlify rewrite). See `ProxyAuth`.
    pub proxy_auth: Option<ProxyAuth>,
}

/// A trusted front door: a proxy that proves itself with a shared key and tells us the visitor's
/// address in a header. Set by PROXY_AUTH_KEY (at least 32 characters), PROXY_AUTH_HEADER
/// (default x-xt-proxy-key) and PROXY_CLIENT_HEADER (default x-nf-client-connection-ip).
#[derive(Clone)]
pub struct ProxyAuth {
    pub key: String,
    pub key_header: axum::http::HeaderName,
    pub client_header: axum::http::HeaderName,
}

// Never prints the key (Config derives Debug).
impl std::fmt::Debug for ProxyAuth {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ProxyAuth")
            .field("key", &"<hidden>")
            .field("key_header", &self.key_header)
            .field("client_header", &self.client_header)
            .finish()
    }
}

/// The trusted front door from the settings, or `None` when PROXY_AUTH_KEY is not set.
pub fn proxy_auth_from(get: &impl Fn(&str) -> Option<String>) -> Result<Option<ProxyAuth>, String> {
    let non_empty = |k: &str| {
        get(k)
            .map(|v| v.trim().to_string())
            .filter(|v| !v.is_empty())
    };
    let Some(key) = non_empty("PROXY_AUTH_KEY") else {
        return Ok(None);
    };
    if key.chars().count() < 32 {
        return Err("PROXY_AUTH_KEY must be at least 32 characters (openssl rand -hex 32)".into());
    }
    let name = |k: &str, default: &str| -> Result<axum::http::HeaderName, String> {
        non_empty(k)
            .unwrap_or_else(|| default.to_string())
            .to_ascii_lowercase()
            .parse()
            .map_err(|_| format!("{k} must be a valid header name"))
    };
    let key_header = name("PROXY_AUTH_HEADER", "x-xt-proxy-key")?;
    let client_header = name("PROXY_CLIENT_HEADER", "x-nf-client-connection-ip")?;
    if key_header == client_header {
        return Err("PROXY_AUTH_HEADER and PROXY_CLIENT_HEADER must differ".into());
    }
    Ok(Some(ProxyAuth {
        key,
        key_header,
        client_header,
    }))
}

/// Domain used for internal addresses when INTERNAL_EMAIL_DOMAINS is not set.
pub const DEFAULT_INTERNAL_DOMAIN: &str = "xynotransit.internal";

/// Argon2id parameters from PASSWORD_HASH_MEMORY_KIB and PASSWORD_HASH_ITERATIONS (tests only;
/// unset means the OWASP minimum).
pub fn password_hash_from(
    get: &impl Fn(&str) -> Option<String>,
) -> Result<crate::hashing::HashSettings, String> {
    let non_empty = |k: &str| {
        get(k)
            .map(|v| v.trim().to_string())
            .filter(|v| !v.is_empty())
    };
    let mut s = crate::hashing::HashSettings::default();
    if let Some(v) = non_empty("PASSWORD_HASH_MEMORY_KIB") {
        s.memory_kib = v
            .parse::<u32>()
            .ok()
            .filter(|n| (8..=1_048_576).contains(n))
            .ok_or("PASSWORD_HASH_MEMORY_KIB must be a number from 8 to 1048576")?;
    }
    if let Some(v) = non_empty("PASSWORD_HASH_ITERATIONS") {
        s.iterations = v
            .parse::<u32>()
            .ok()
            .filter(|n| (1..=20).contains(n))
            .ok_or("PASSWORD_HASH_ITERATIONS must be a number from 1 to 20")?;
    }
    Ok(s)
}

/// Origin of the links, without a trailing slash.
pub fn public_url_from(get: impl Fn(&str) -> Option<String>) -> String {
    get("PUBLIC_URL")
        .map(|v| v.trim().to_string())
        .filter(|v| !v.is_empty())
        .unwrap_or_else(|| "http://127.0.0.1:8080".into())
        .trim_end_matches('/')
        .to_string()
}

/// Comma separated domains, trimmed and lowercased, a leading `@` allowed. Empty means default.
pub fn parse_internal_domains(raw: Option<&str>) -> Result<Vec<String>, String> {
    let mut out: Vec<String> = Vec::new();
    for part in raw.unwrap_or("").split(',') {
        let d = part
            .trim()
            .trim_start_matches('@')
            .trim_matches('.')
            .to_lowercase();
        if d.is_empty() {
            continue;
        }
        if d.contains('@') || d.chars().any(|c| c.is_whitespace() || c.is_control()) {
            return Err("INTERNAL_EMAIL_DOMAINS must be domains such as xynotransit.internal, separated by commas".into());
        }
        if !out.contains(&d) {
            out.push(d);
        }
    }
    if out.is_empty() {
        out.push(DEFAULT_INTERNAL_DOMAIN.into());
    }
    Ok(out)
}

impl Config {
    /// True when mail to this address must never be tried.
    pub fn is_internal_email(&self, email: &str) -> bool {
        is_internal_email(&self.internal_email_domains, email)
    }

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
        let public_url = public_url_from(&get);
        let internal_email_domains =
            parse_internal_domains(non_empty("INTERNAL_EMAIL_DOMAINS").as_deref())?;

        let password_hash = password_hash_from(&get)?;
        let proxy_auth = proxy_auth_from(&get)?;

        Ok(Config {
            proxy_auth,
            password_hash,
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
            internal_email_domains,
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

/// Does the address end in one of the internal domains (case does not matter)?
pub fn is_internal_email(domains: &[String], email: &str) -> bool {
    match email.trim().rsplit_once('@') {
        Some((_, d)) => {
            let d = d.to_lowercase();
            domains.contains(&d)
        }
        None => false,
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

    #[test]
    fn password_hash_settings() {
        let base = [
            ("DATABASE_URL", "postgres://x"),
            ("JWT_SECRET", "0123456789012345678901234567890123"),
        ];
        let with = |extra: &[(&'static str, &'static str)]| {
            let mut p = base.to_vec();
            p.extend_from_slice(extra);
            Config::from_lookup(lookup(&p))
        };
        let d = with(&[]).unwrap().password_hash;
        assert_eq!((d.memory_kib, d.iterations, d.parallelism), (19456, 2, 1));
        let c = with(&[
            ("PASSWORD_HASH_MEMORY_KIB", "64"),
            ("PASSWORD_HASH_ITERATIONS", "1"),
        ])
        .unwrap();
        assert_eq!(c.password_hash.memory_kib, 64);
        assert_eq!(c.password_hash.iterations, 1);
        assert!(with(&[("PASSWORD_HASH_MEMORY_KIB", "4")]).is_err());
        assert!(with(&[("PASSWORD_HASH_MEMORY_KIB", "lots")]).is_err());
        assert!(with(&[("PASSWORD_HASH_ITERATIONS", "0")]).is_err());
    }

    #[test]
    fn internal_domains() {
        let base = [
            ("DATABASE_URL", "postgres://x"),
            ("JWT_SECRET", "0123456789012345678901234567890123"),
        ];
        let with = |v: &'static str| {
            let mut p = base.to_vec();
            p.push(("INTERNAL_EMAIL_DOMAINS", v));
            Config::from_lookup(lookup(&p))
        };
        let c = Config::from_lookup(lookup(&base)).unwrap();
        assert_eq!(c.internal_email_domains, vec!["xynotransit.internal"]);
        assert!(c.is_internal_email("Rosa@XYNOTRANSIT.internal"));
        assert!(!c.is_internal_email("rosa@xynotransit.internal.evil.org"));
        assert!(!c.is_internal_email("rosa@evilxynotransit.internal"));
        assert!(!c.is_internal_email("no-at-sign"));
        assert!(!c.is_internal_email("rosa@example.org"));
        let c = with(" A.internal, @B.local ,,a.internal").unwrap();
        assert_eq!(c.internal_email_domains, vec!["a.internal", "b.local"]);
        assert!(c.is_internal_email("x@b.local"));
        assert_eq!(
            with("  ").unwrap().internal_email_domains,
            vec!["xynotransit.internal"]
        );
        // A leading dot or a trailing dot is dropped, so the domain still matches and a generated
        // address is never name@.domain.
        let c = with(".C.internal.,@.d.local").unwrap();
        assert_eq!(c.internal_email_domains, vec!["c.internal", "d.local"]);
        assert!(c.is_internal_email("x@c.internal"));
        assert!(with("a b.local").is_err());
        assert!(with("x@y.local").is_err());
    }
}
