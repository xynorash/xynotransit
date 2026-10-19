//! Limits on password sign-in: how many wrong tries, from which name and from which address.
//!
//! Rows of `login_failure` (windows of 15 minutes):
//!   * 5 failures for one username key (what was typed, trimmed and lowercased, known or not)
//!     lock that name: 429 "Too many sign-in attempts. Try again later." with Retry-After.
//!   * 30 failures from one client address lock the address.
//!
//! A try is written down BEFORE the password is checked (under advisory locks), and taken back when
//! it turns out right, so parallel guesses cannot all slip past the count. While locked, even the
//! right password is refused and the refused tries are not counted again. A success clears that
//! name's rows only; nobody else's counters change.
//!
//! The client address comes from the socket. The API sits behind nginx and Caddy, which are on
//! private addresses; only when the connecting peer is a private network address (10/8, 172.16/12,
//! 192.168/16, 100.64/10, loopback, link-local, IPv6 fc00::/7 and fe80::/10) is `X-Forwarded-For`
//! read, from the right: private hops are our own proxies and are skipped, and the right-most
//! address that is not private is the client. A peer that is not private is the client itself and
//! the header is ignored. If the header is unusable the peer is used. IPv6 clients count per /64.

use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};

use axum::{
    extract::{ConnectInfo, FromRequestParts},
    http::request::Parts,
};
use sqlx::PgPool;

use crate::{error::ApiError, state::AppState};

pub const WINDOW_MINUTES: i64 = 15;
pub const MAX_FAILURES_PER_USER: i64 = 5;
pub const MAX_FAILURES_PER_IP: i64 = 30;
/// Temporary passwords a manager may issue per hour.
pub const MAX_RESETS_PER_HOUR: i64 = 30;

pub mod msg {
    pub const WRONG: &str = "Username or password is wrong.";
    pub const TOO_MANY: &str = "Too many sign-in attempts. Try again later.";
    pub const TOO_MANY_RESETS: &str = "Too many temporary passwords created. Try again later.";
    pub const BUSY: &str = "Busy, try again in a moment.";
}

fn private_v4(a: Ipv4Addr) -> bool {
    let o = a.octets();
    a.is_private() || a.is_loopback() || a.is_link_local() || (o[0] == 100 && (o[1] & 0xc0) == 64)
}

/// Is this a private network address (one of our own machines or proxies)?
pub fn is_private(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(a) => private_v4(a),
        IpAddr::V6(a) => match a.to_ipv4_mapped() {
            Some(v4) => private_v4(v4),
            None => {
                let s = a.segments()[0];
                a.is_loopback() || (s & 0xfe00) == 0xfc00 || (s & 0xffc0) == 0xfe80
            }
        },
    }
}

fn parse_hop(raw: &str) -> Option<IpAddr> {
    let raw = raw.trim();
    if let Ok(ip) = raw.parse::<IpAddr>() {
        return Some(ip);
    }
    if let Ok(sa) = raw.parse::<SocketAddr>() {
        return Some(sa.ip());
    }
    raw.strip_prefix('[')
        .and_then(|r| r.strip_suffix(']'))
        .and_then(|r| r.parse::<Ipv6Addr>().ok())
        .map(IpAddr::V6)
}

/// The text the limits count by: the address, an IPv6 one cut to its /64.
pub fn key_of(ip: IpAddr) -> String {
    let ip = match ip {
        IpAddr::V6(a) => a.to_ipv4_mapped().map(IpAddr::V4).unwrap_or(IpAddr::V6(a)),
        v4 => v4,
    };
    match ip {
        IpAddr::V4(a) => a.to_string(),
        IpAddr::V6(a) => {
            let s = a.segments();
            format!("{:x}:{:x}:{:x}:{:x}::/64", s[0], s[1], s[2], s[3])
        }
    }
}

/// The client address key from the socket peer and the X-Forwarded-For header (all its lines,
/// joined with commas). See the module notes.
pub fn client_key(peer: Option<IpAddr>, forwarded_for: Option<&str>) -> String {
    let Some(peer) = peer else {
        return "unknown".into();
    };
    if !is_private(peer) {
        return key_of(peer);
    }
    if let Some(xff) = forwarded_for {
        for hop in xff.rsplit(',') {
            match parse_hop(hop) {
                Some(ip) if is_private(ip) => continue,
                Some(ip) => return key_of(ip),
                None => break,
            }
        }
    }
    key_of(peer)
}

/// The caller's address key, for handlers that count tries.
pub struct ClientKey(pub String);

impl FromRequestParts<AppState> for ClientKey {
    type Rejection = std::convert::Infallible;

    async fn from_request_parts(parts: &mut Parts, _: &AppState) -> Result<Self, Self::Rejection> {
        let peer = parts
            .extensions
            .get::<ConnectInfo<SocketAddr>>()
            .map(|c| c.0.ip());
        let lines: Vec<&str> = parts
            .headers
            .get_all("x-forwarded-for")
            .iter()
            .filter_map(|v| v.to_str().ok())
            .collect();
        let joined = lines.join(",");
        Ok(ClientKey(client_key(
            peer,
            (!lines.is_empty()).then_some(joined.as_str()),
        )))
    }
}

async fn lock(tx: &mut sqlx::PgConnection, what: &str) -> Result<(), sqlx::Error> {
    sqlx::query("select pg_advisory_xact_lock(hashtextextended($1::text, 0))")
        .bind(what)
        .execute(tx)
        .await?;
    Ok(())
}

/// Seconds until the failure that holds a place beyond `limit` is out of the window.
async fn wait_for(
    tx: &mut sqlx::PgConnection,
    column: &str,
    value: &str,
    count: i64,
    limit: i64,
) -> Result<i64, sqlx::Error> {
    let sql = format!(
        "select ceil(extract(epoch from (at + make_interval(mins => {WINDOW_MINUTES}) - now())))::bigint
         from login_failure where {column} = $1 and at > now() - make_interval(mins => {WINDOW_MINUTES})
         order by at, id offset $2 limit 1"
    );
    let w: Option<i64> = sqlx::query_scalar(&sql)
        .bind(value)
        .bind((count - limit).max(0))
        .fetch_optional(tx)
        .await?;
    Ok(w.unwrap_or(WINDOW_MINUTES * 60)
        .clamp(1, WINDOW_MINUTES * 60))
}

/// Write down one try for this username key and address, or refuse with 429. Returns the id of
/// the row, which the caller drops with `forgive` when the try was right or never a real guess.
pub async fn begin_attempt(pool: &PgPool, user_key: &str, ip: &str) -> Result<i64, ApiError> {
    let mut tx = pool.begin().await?;
    // Always the address first, then the name, so two requests cannot wait for each other.
    lock(&mut tx, &format!("xt_login_ip:{ip}")).await?;
    lock(&mut tx, &format!("xt_login_user:{user_key}")).await?;
    sqlx::query(
        "delete from login_failure where username_key = $1
         and at < now() - make_interval(mins => $2::int)",
    )
    .bind(user_key)
    .bind(WINDOW_MINUTES as i32)
    .execute(&mut *tx)
    .await?;
    let count = |col: &'static str| {
        format!(
            "select count(*) from login_failure
             where {col} = $1 and at > now() - make_interval(mins => {WINDOW_MINUTES})"
        )
    };
    let by_user: i64 = sqlx::query_scalar(&count("username_key"))
        .bind(user_key)
        .fetch_one(&mut *tx)
        .await?;
    let by_ip: i64 = sqlx::query_scalar(&count("ip"))
        .bind(ip)
        .fetch_one(&mut *tx)
        .await?;
    if by_user >= MAX_FAILURES_PER_USER || by_ip >= MAX_FAILURES_PER_IP {
        let mut wait = 0;
        if by_user >= MAX_FAILURES_PER_USER {
            wait = wait.max(
                wait_for(
                    &mut tx,
                    "username_key",
                    user_key,
                    by_user,
                    MAX_FAILURES_PER_USER,
                )
                .await?,
            );
        }
        if by_ip >= MAX_FAILURES_PER_IP {
            wait = wait.max(wait_for(&mut tx, "ip", ip, by_ip, MAX_FAILURES_PER_IP).await?);
        }
        tx.commit().await?;
        return Err(ApiError::TooManyRequests(msg::TOO_MANY.into(), wait as u64));
    }
    let id: i64 = sqlx::query_scalar(
        "insert into login_failure (username_key, ip) values ($1, $2) returning id",
    )
    .bind(user_key)
    .bind(ip)
    .fetch_one(&mut *tx)
    .await?;
    tx.commit().await?;
    Ok(id)
}

/// The try was not a wrong guess after all (a busy server, a failure of ours): take it back.
pub async fn forgive(pool: &PgPool, id: i64) {
    if let Err(e) = sqlx::query("delete from login_failure where id = $1")
        .bind(id)
        .execute(pool)
        .await
    {
        tracing::error!(error = %e, "could not take back a sign-in try");
    }
}

/// The try was right: this name starts again from zero. Other names are not touched.
pub async fn succeed(pool: &PgPool, user_key: &str) {
    if let Err(e) = sqlx::query("delete from login_failure where username_key = $1")
        .bind(user_key)
        .execute(pool)
        .await
    {
        tracing::error!(error = %e, "could not clear sign-in tries");
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ip(s: &str) -> Option<IpAddr> {
        Some(s.parse().unwrap())
    }

    #[test]
    fn private_addresses() {
        for p in [
            "10.1.2.3",
            "172.16.0.1",
            "172.31.255.255",
            "192.168.1.1",
            "127.0.0.1",
            "169.254.1.1",
            "100.64.0.1",
            "100.127.255.255",
            "::1",
            "fd00::1",
            "fc12::1",
            "fe80::1",
            "::ffff:10.0.0.1",
        ] {
            assert!(is_private(p.parse().unwrap()), "{p}");
        }
        for p in [
            "8.8.8.8",
            "172.32.0.1",
            "172.15.0.1",
            "100.63.0.1",
            "100.128.0.1",
            "192.169.0.1",
            "2001:db8::1",
            "2a00::1",
            "::ffff:8.8.8.8",
        ] {
            assert!(!is_private(p.parse().unwrap()), "{p}");
        }
    }

    #[test]
    fn forwarded_for_table() {
        let cases: &[(Option<&str>, Option<&str>, &str)] = &[
            // No peer known (not a real socket).
            (None, Some("1.2.3.4"), "unknown"),
            // A public peer is the client; the header is a lie.
            (Some("8.8.8.8"), Some("1.2.3.4"), "8.8.8.8"),
            (Some("8.8.8.8"), None, "8.8.8.8"),
            // A private peer without a header.
            (Some("172.18.0.2"), None, "172.18.0.2"),
            // One proxy hop.
            (Some("172.18.0.2"), Some("203.0.113.9"), "203.0.113.9"),
            // Two of our proxies: the right-most public address is the client.
            (
                Some("172.18.0.2"),
                Some("203.0.113.9, 10.0.0.5"),
                "203.0.113.9",
            ),
            (
                Some("127.0.0.1"),
                Some("203.0.113.9, 192.168.1.1, 10.0.0.5"),
                "203.0.113.9",
            ),
            // The client wrote a fake first hop: only the right-most untrusted one counts.
            (
                Some("172.18.0.2"),
                Some("1.1.1.1, 203.0.113.9"),
                "203.0.113.9",
            ),
            (
                Some("172.18.0.2"),
                Some("1.1.1.1, 203.0.113.9, 10.0.0.5"),
                "203.0.113.9",
            ),
            // A fake private address typed by the client sits left of the real one.
            (
                Some("172.18.0.2"),
                Some("10.9.9.9, 203.0.113.9"),
                "203.0.113.9",
            ),
            // Everything private: the peer.
            (
                Some("172.18.0.2"),
                Some("10.0.0.1, 192.168.0.4"),
                "172.18.0.2",
            ),
            // Garbage on the right: the peer, never the garbage.
            (
                Some("172.18.0.2"),
                Some("203.0.113.9, not-an-ip"),
                "172.18.0.2",
            ),
            (Some("172.18.0.2"), Some(""), "172.18.0.2"),
            (Some("172.18.0.2"), Some(" , "), "172.18.0.2"),
            // Ports and brackets are cut.
            (Some("172.18.0.2"), Some("203.0.113.9:5555"), "203.0.113.9"),
            (
                Some("172.18.0.2"),
                Some("[2001:db8:1:2:3:4:5:6]:443"),
                "2001:db8:1:2::/64",
            ),
            (
                Some("172.18.0.2"),
                Some("[2001:db8:1:2:3:4:5:6]"),
                "2001:db8:1:2::/64",
            ),
            // IPv6 clients count per /64.
            (
                Some("::1"),
                Some("2001:db8:1:2:aaaa:bbbb:cccc:dddd"),
                "2001:db8:1:2::/64",
            ),
            (Some("::1"), Some("2001:db8:1:2:1::1"), "2001:db8:1:2::/64"),
            // IPv4 in IPv6 is the IPv4 address.
            (
                Some("::ffff:172.18.0.2"),
                Some("::ffff:203.0.113.9"),
                "203.0.113.9",
            ),
            (Some("::ffff:8.8.4.4"), None, "8.8.4.4"),
        ];
        for (peer, xff, want) in cases {
            let peer = peer.and_then(ip);
            assert_eq!(client_key(peer, *xff), *want, "{peer:?} {xff:?}");
        }
    }
}
