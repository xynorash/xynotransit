//! Limits on password sign-in: how many wrong tries, from which name and from which address.
//!
//! Rows of `login_failure` (windows of 15 minutes), counted three ways:
//!   * per PAIR (username, client address): 5 failures lock that pair only. Someone else's
//!     address is not affected, so an attacker cannot lock the real person out.
//!   * per USERNAME, a backstop: 100 failures from any addresses lock the name for everybody
//!     except addresses that signed in successfully for that name (by password or link) within the
//!     last 30 days (`login_success`).
//!   * per ADDRESS: 30 failures lock the address, but only an address the server can determine.
//!
//! A WRONG CURRENT PASSWORD while signed in (`Kind::Change`) is counted apart, under other keys
//! (own HMAC domains, so these rows never touch a login lock and a login failure never touches
//! them): per pair (5), per address (30) and, across all addresses, per PERSON: 10 failures per
//! 15 minutes answer 429 "Too many password attempts. Try again later." with Retry-After. The 10th
//! failure also ends the person's sessions (`end_sessions`, audit kind `change-lock`), so a thief
//! holding a token cannot keep guessing; the real person signs in again.
//!
//! All three login limits answer 429 "Too many sign-in attempts. Try again later." with Retry-After.
//! A try is written down BEFORE the password is checked (under advisory locks), and taken back when
//! it turns out right, so parallel guesses cannot all slip past the count. While locked, even the
//! right password is refused and the refused tries are not counted again. A success clears that
//! pair's failures only.
//!
//! Nothing readable is stored: the username text and the address are kept as HMAC-SHA256 hex keys
//! (`LimitKeys`, key from JWT_SECRET by HKDF-SHA256 with the label `xt-ratelimit-v1`).
//!
//! The client address is a PUBLIC address only. The API sits behind Caddy (and nginx), which are on
//! private addresses. When the socket peer is public it is the client and X-Forwarded-For is
//! ignored. When the peer is private (10/8, 172.16/12, 192.168/16, 100.64/10, loopback, link-local,
//! IPv6 fc00::/7 and fe80::/10), X-Forwarded-For is read from the right: private hops are our own
//! proxies and are skipped, and the right-most hop that is not private is the client. If there is
//! none (everything private, as with Docker NAT or IPv6 through docker-proxy), the header is
//! unusable or there is no peer, the address is UNKNOWN: the per-address limit is skipped and the
//! pair uses the constant address `unknown`. IPv6 clients count per /64.
//!
//! TRUSTED FRONT DOOR (optional). When PROXY_AUTH_KEY is set and a request carries exactly one
//! PROXY_AUTH_HEADER line equal to it (constant time compare), the client is the address in
//! exactly one PROXY_CLIENT_HEADER line, if that parses as a PUBLIC IP (`front_door_addr`). A
//! wrong, missing or doubled key, or an unset PROXY_AUTH_KEY, means the rules above apply
//! unchanged, and both headers of such a request are ignored completely. A request WITH the
//! correct key but without exactly one public client address (missing, doubled, invalid or
//! private: Netlify passes a visitor's own copy of the header on next to its own) is refused
//! with 400, never answered from the proxy's own address, which would let a visitor spread
//! guesses over the proxy's servers. Every limit, audit row and trusted address
//! gets its address from the `ClientAddr` extractor, so they all see the same resolved address.

use std::{
    net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr},
    sync::atomic::{AtomicI64, Ordering},
};

use axum::{
    extract::{ConnectInfo, FromRequestParts},
    http::request::Parts,
};
use hkdf::Hkdf;
use hmac::{Hmac, Mac};
use sha2::Sha256;
use sqlx::PgPool;

use crate::{error::ApiError, state::AppState};

pub const WINDOW_MINUTES: i64 = 15;
/// Failures per (username, address) pair.
pub const MAX_FAILURES_PER_PAIR: i64 = 5;
/// Backstop: failures per username from all addresses together.
pub const MAX_FAILURES_PER_USER: i64 = 100;
/// Failures per determinable client address.
pub const MAX_FAILURES_PER_IP: i64 = 30;
/// Wrong current passwords per person (from any addresses) per window; the last one ends sessions.
pub const MAX_CHANGE_FAILURES_PER_PERSON: i64 = 10;
/// Days an address stays trusted for a username after a successful sign-in.
pub const TRUSTED_DAYS: i64 = 30;
/// Temporary passwords a manager may issue per hour.
pub const MAX_RESETS_PER_HOUR: i64 = 30;
/// The HKDF label of the key behind the stored keys.
pub const KEY_LABEL: &[u8] = b"xt-ratelimit-v1";
/// The address text used when the client address cannot be determined.
pub const UNKNOWN_ADDRESS: &str = "unknown";

pub mod msg {
    pub const WRONG: &str = "Username or password is wrong.";
    pub const TOO_MANY: &str = "Too many sign-in attempts. Try again later.";
    pub const TOO_MANY_PASSWORD: &str = "Too many password attempts. Try again later.";
    pub const SIGNED_OUT_FOR_SAFETY: &str =
        "You were signed out for safety after too many wrong passwords. Sign in again.";
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

/// The key of the PUBLIC client address from the socket peer and the X-Forwarded-For header (all
/// its lines, joined with commas), or `None` when it cannot be determined. See the module notes.
pub fn client_addr(peer: Option<IpAddr>, forwarded_for: Option<&str>) -> Option<String> {
    let peer = peer?;
    if !is_private(peer) {
        return Some(key_of(peer));
    }
    for hop in forwarded_for?.rsplit(',') {
        match parse_hop(hop) {
            Some(ip) if is_private(ip) => continue,
            Some(ip) => return Some(key_of(ip)),
            // Garbage right of everything else: never guess.
            None => return None,
        }
    }
    None
}

/// Compare two secrets without leaking where they differ or how long the stored one is: both
/// are hashed to 32 bytes, then compared byte by byte without stopping early.
pub fn constant_time_eq(a: &[u8], b: &[u8]) -> bool {
    use sha2::Digest;
    let (ha, hb) = (Sha256::digest(a), Sha256::digest(b));
    ha.iter().zip(hb.iter()).fold(0u8, |d, (x, y)| d | (x ^ y)) == 0
}

/// True when the request carries exactly one key header and it matches: the front door vouches
/// for it. From then on the client header must be exactly one public address; anything else
/// (a visitor adding their own copy, a missing header) is refused, never quietly replaced by the
/// proxy's own address, which would let a visitor spread guesses over the proxy's servers.
pub fn has_front_door_key(
    cfg: Option<&crate::config::ProxyAuth>,
    headers: &axum::http::HeaderMap,
) -> bool {
    let Some(cfg) = cfg else { return false };
    let mut keys = headers.get_all(&cfg.key_header).iter();
    match (keys.next(), keys.next()) {
        (Some(sent), None) => constant_time_eq(sent.as_bytes(), cfg.key.as_bytes()),
        _ => false,
    }
}

/// The client address key given by a trusted front door, or `None` when the request does not
/// carry the correct key or the client header is unusable (the caller then uses the normal rules).
pub fn front_door_addr(
    cfg: Option<&crate::config::ProxyAuth>,
    headers: &axum::http::HeaderMap,
) -> Option<String> {
    let cfg = cfg?;
    let mut keys = headers.get_all(&cfg.key_header).iter();
    let sent = keys.next()?;
    if keys.next().is_some() || !constant_time_eq(sent.as_bytes(), cfg.key.as_bytes()) {
        return None;
    }
    let mut vals = headers.get_all(&cfg.client_header).iter();
    let raw = vals.next()?.to_str().ok()?;
    if vals.next().is_some() {
        return None;
    }
    let ip = raw.trim().parse::<IpAddr>().ok()?;
    // Same rule as everywhere: only a public address counts.
    (!is_private(ip) && !not_a_visitor(ip)).then(|| key_of(ip))
}

/// Addresses that can never be a real visitor (unspecified, broadcast, multicast), even when a
/// key holder names them.
fn not_a_visitor(ip: IpAddr) -> bool {
    let ip = match ip {
        IpAddr::V6(a) => a.to_ipv4_mapped().map(IpAddr::V4).unwrap_or(IpAddr::V6(a)),
        v4 => v4,
    };
    match ip {
        IpAddr::V4(a) => a.is_unspecified() || a.is_broadcast() || a.is_multicast(),
        IpAddr::V6(a) => a.is_unspecified() || a.is_multicast(),
    }
}

/// The caller's public address key, or `None` when it cannot be determined.
pub struct ClientAddr(pub Option<String>);

static LAST_UNKNOWN_LOG: AtomicI64 = AtomicI64::new(0);

/// Log that an address was unknown, at most once a minute.
fn note_unknown() {
    let now = chrono::Utc::now().timestamp();
    let last = LAST_UNKNOWN_LOG.load(Ordering::Relaxed);
    if now - last >= 60
        && LAST_UNKNOWN_LOG
            .compare_exchange(last, now, Ordering::Relaxed, Ordering::Relaxed)
            .is_ok()
    {
        tracing::warn!("client address unknown, per-address limit skipped");
    }
}

impl FromRequestParts<AppState> for ClientAddr {
    type Rejection = ApiError;

    async fn from_request_parts(parts: &mut Parts, st: &AppState) -> Result<Self, Self::Rejection> {
        if let Some(addr) = front_door_addr(st.config.proxy_auth.as_ref(), &parts.headers) {
            return Ok(ClientAddr(Some(addr)));
        }
        if has_front_door_key(st.config.proxy_auth.as_ref(), &parts.headers) {
            // Vouched for by the front door but no single public address: refuse.
            tracing::warn!("front door request without exactly one public client address");
            return Err(ApiError::bad("Bad request."));
        }
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
        let addr = client_addr(peer, (!lines.is_empty()).then_some(joined.as_str()));
        if addr.is_none() {
            note_unknown();
        }
        Ok(ClientAddr(addr))
    }
}

/// The key behind the stored username and address keys.
pub struct LimitKeys {
    key: [u8; 32],
}

impl LimitKeys {
    /// HKDF-SHA256 of the JWT secret with the fixed label.
    pub fn new(secret: &str) -> Self {
        let mut key = [0u8; 32];
        Hkdf::<Sha256>::new(None, secret.as_bytes())
            .expand(KEY_LABEL, &mut key)
            .expect("32 bytes is a valid HKDF length");
        LimitKeys { key }
    }

    fn hex(&self, domain: &str, text: &str) -> String {
        let mut mac = <Hmac<Sha256> as Mac>::new_from_slice(&self.key).expect("any key length");
        mac.update(domain.as_bytes());
        mac.update(&[0]);
        mac.update(text.as_bytes());
        mac.finalize()
            .into_bytes()
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect()
    }

    /// The stored key of a typed username (already through `username::lookup_key`).
    pub fn user(&self, lookup_key: &str) -> String {
        self.hex("user", lookup_key)
    }

    /// The stored key of a person for change attempts (a domain of its own).
    pub fn change_person(&self, person_id: &str) -> String {
        self.hex("change-person", person_id)
    }

    /// The stored key of a client address for change attempts (a domain of its own).
    pub fn change_address(&self, addr: Option<&str>) -> String {
        self.hex("change-address", addr.unwrap_or(UNKNOWN_ADDRESS))
    }

    /// The stored key of a client address key, or of `unknown`.
    pub fn address(&self, addr: Option<&str>) -> String {
        self.hex("address", addr.unwrap_or(UNKNOWN_ADDRESS))
    }
}

/// Who is trying: the stored keys, and whether the address is a real one.
pub struct Who {
    pub user: String,
    pub address: String,
    /// False when the address is unknown: no per-address limit, no trusted address.
    pub known_address: bool,
}

impl Who {
    /// `typed` is what was typed in the username box (or the signed-in username).
    pub fn new(keys: &LimitKeys, typed: &str, client: &ClientAddr) -> Self {
        Who {
            user: keys.user(&crate::username::lookup_key(typed)),
            address: keys.address(client.0.as_deref()),
            known_address: client.0.is_some(),
        }
    }
}

impl Who {
    /// Who is trying to change a password: keys of the change domains, for the person.
    pub fn for_change(keys: &LimitKeys, person_id: &str, client: &ClientAddr) -> Self {
        Who {
            user: keys.change_person(person_id),
            address: keys.change_address(client.0.as_deref()),
            known_address: client.0.is_some(),
        }
    }
}

/// Which tries a check counts.
#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    /// A sign-in: pair, backstop (unless trusted) and address.
    Login,
    /// A wrong current password while signed in: pair, address and person (all addresses), under
    /// keys of their own. Login failures never block it and it never blocks a login.
    Change,
}

async fn lock(tx: &mut sqlx::PgConnection, what: &str) -> Result<(), sqlx::Error> {
    sqlx::query("select pg_advisory_xact_lock(hashtextextended($1::text, 0))")
        .bind(what)
        .execute(tx)
        .await?;
    Ok(())
}

#[derive(Clone, Copy)]
enum Scope {
    Pair,
    User,
    Address,
}

impl Scope {
    fn filter(self) -> &'static str {
        match self {
            Scope::Pair => "username_key = $1 and address_key = $2",
            Scope::User => "username_key = $1 and $2::text is not null",
            Scope::Address => "address_key = $2 and $1::text is not null",
        }
    }
}

async fn count(tx: &mut sqlx::PgConnection, who: &Who, scope: Scope) -> Result<i64, sqlx::Error> {
    let sql = format!(
        "select count(*) from login_failure
         where {} and at > now() - make_interval(mins => {WINDOW_MINUTES})",
        scope.filter()
    );
    sqlx::query_scalar(&sql)
        .bind(&who.user)
        .bind(&who.address)
        .fetch_one(tx)
        .await
}

/// Seconds until the failure that holds a place beyond `limit` is out of the window.
async fn wait_for(
    tx: &mut sqlx::PgConnection,
    who: &Who,
    scope: Scope,
    count: i64,
    limit: i64,
) -> Result<i64, sqlx::Error> {
    let sql = format!(
        "select ceil(extract(epoch from (at + make_interval(mins => {WINDOW_MINUTES}) - now())))::bigint
         from login_failure where {} and at > now() - make_interval(mins => {WINDOW_MINUTES})
         order by at, id offset $3 limit 1",
        scope.filter()
    );
    let w: Option<i64> = sqlx::query_scalar(&sql)
        .bind(&who.user)
        .bind(&who.address)
        .bind((count - limit).max(0))
        .fetch_optional(tx)
        .await?;
    Ok(w.unwrap_or(WINDOW_MINUTES * 60)
        .clamp(1, WINDOW_MINUTES * 60))
}

/// Write down one try, or refuse with 429. Returns the id of the row, which the caller drops
/// with `forgive` when the try was never a real guess; `succeed` drops it when it was right.
pub async fn begin_attempt(pool: &PgPool, who: &Who, kind: Kind) -> Result<i64, ApiError> {
    let mut tx = pool.begin().await?;
    // Always the address first, then the name, so two requests cannot wait for each other. The
    // name lock also keeps the pair and the name counts exact under parallel tries.
    if who.known_address {
        lock(&mut tx, &format!("xt_login_addr:{}", who.address)).await?;
    }
    lock(&mut tx, &format!("xt_login_user:{}", who.user)).await?;
    sqlx::query(
        "delete from login_failure where username_key = $1
         and at < now() - make_interval(mins => $2::int)",
    )
    .bind(&who.user)
    .bind(WINDOW_MINUTES as i32)
    .execute(&mut *tx)
    .await?;

    let mut wait = 0i64;
    let by_pair = count(&mut tx, who, Scope::Pair).await?;
    if by_pair >= MAX_FAILURES_PER_PAIR {
        wait = wait.max(wait_for(&mut tx, who, Scope::Pair, by_pair, MAX_FAILURES_PER_PAIR).await?);
    }
    if who.known_address {
        let by_addr = count(&mut tx, who, Scope::Address).await?;
        if by_addr >= MAX_FAILURES_PER_IP {
            wait = wait
                .max(wait_for(&mut tx, who, Scope::Address, by_addr, MAX_FAILURES_PER_IP).await?);
        }
    }
    if kind == Kind::Change {
        let by_person = count(&mut tx, who, Scope::User).await?;
        if by_person >= MAX_CHANGE_FAILURES_PER_PERSON {
            wait = wait.max(
                wait_for(
                    &mut tx,
                    who,
                    Scope::User,
                    by_person,
                    MAX_CHANGE_FAILURES_PER_PERSON,
                )
                .await?,
            );
        }
    }
    if kind == Kind::Login {
        let by_user = count(&mut tx, who, Scope::User).await?;
        if by_user >= MAX_FAILURES_PER_USER {
            let trusted: bool = who.known_address
                && sqlx::query_scalar(&format!(
                    "select exists (select 1 from login_success
                     where username_key = $1 and address_key = $2
                       and at > now() - make_interval(days => {TRUSTED_DAYS}))"
                ))
                .bind(&who.user)
                .bind(&who.address)
                .fetch_one(&mut *tx)
                .await?;
            if !trusted {
                wait = wait.max(
                    wait_for(&mut tx, who, Scope::User, by_user, MAX_FAILURES_PER_USER).await?,
                );
            }
        }
    }
    if wait > 0 {
        tx.commit().await?;
        let text = match kind {
            Kind::Login => msg::TOO_MANY,
            Kind::Change => msg::TOO_MANY_PASSWORD,
        };
        return Err(ApiError::TooManyRequests(text.into(), wait as u64));
    }
    let id: i64 = sqlx::query_scalar(
        "insert into login_failure (username_key, address_key) values ($1, $2) returning id",
    )
    .bind(&who.user)
    .bind(&who.address)
    .fetch_one(&mut *tx)
    .await?;
    tx.commit().await?;
    Ok(id)
}

/// After a wrong current password: when THIS try (`attempt`, the id `begin_attempt` gave) is the
/// 10th or later in the person's window, end their sessions (epoch plus 1, audit kind
/// `change-lock`). Going by the place of this try, not by the total, means that parallel tries
/// still waiting for their answer are plain wrong answers (403) and only the 10th is the lock.
/// `epoch` is the one the caller's token carried, so callers end the sessions once. Returns true
/// when the sessions are (now or already) ended by this lock, so the caller answers 401.
pub async fn end_sessions_at_cap(
    pool: &PgPool,
    who: &Who,
    attempt: i64,
    person_id: uuid::Uuid,
    epoch: i32,
) -> Result<bool, sqlx::Error> {
    let mut tx = pool.begin().await?;
    lock(&mut tx, &format!("xt_login_user:{}", who.user)).await?;
    let place: i64 = sqlx::query_scalar(
        "select count(*) from login_failure
         where username_key = $1 and id <= $2
           and at > now() - make_interval(mins => $3::int)",
    )
    .bind(&who.user)
    .bind(attempt)
    .bind(WINDOW_MINUTES as i32)
    .fetch_one(&mut *tx)
    .await?;
    if place < MAX_CHANGE_FAILURES_PER_PERSON {
        return Ok(false);
    }
    let done = sqlx::query(
        "update person set session_epoch = session_epoch + 1
         where id = $1 and session_epoch = $2",
    )
    .bind(person_id)
    .bind(epoch)
    .execute(&mut *tx)
    .await?
    .rows_affected();
    if done == 1 {
        sqlx::query("insert into password_audit (person_id, kind) values ($1, 'change-lock')")
            .bind(person_id)
            .execute(&mut *tx)
            .await?;
    }
    tx.commit().await?;
    Ok(true)
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

/// The try was right: this pair starts again from zero (other pairs are not touched). With
/// `trust` (a real sign-in, by password or link) a known address is remembered for 30 days.
pub async fn succeed(pool: &PgPool, who: &Who, trust: bool) {
    let r: Result<(), sqlx::Error> = async {
        let mut tx = pool.begin().await?;
        sqlx::query("delete from login_failure where username_key = $1 and address_key = $2")
            .bind(&who.user)
            .bind(&who.address)
            .execute(&mut *tx)
            .await?;
        if trust && who.known_address {
            sqlx::query(
                "insert into login_success (username_key, address_key) values ($1, $2)
                 on conflict (username_key, address_key) do update set at = now()",
            )
            .bind(&who.user)
            .bind(&who.address)
            .execute(&mut *tx)
            .await?;
        }
        tx.commit().await
    }
    .await;
    if let Err(e) = r {
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
        let cases: &[(Option<&str>, Option<&str>, Option<&str>)] = &[
            // No peer known (not a real socket).
            (None, Some("1.2.3.4"), None),
            // A public peer is the client; the header is a lie.
            (Some("8.8.8.8"), Some("1.2.3.4"), Some("8.8.8.8")),
            (Some("8.8.8.8"), None, Some("8.8.8.8")),
            (
                Some("2001:db8:1:2:3:4:5:6"),
                Some("1.2.3.4"),
                Some("2001:db8:1:2::/64"),
            ),
            // A private peer without a header: nobody to name.
            (Some("172.18.0.2"), None, None),
            (Some("::1"), None, None),
            // One proxy hop.
            (Some("172.18.0.2"), Some("203.0.113.9"), Some("203.0.113.9")),
            // Two of our proxies: the right-most public address is the client.
            (
                Some("172.18.0.2"),
                Some("203.0.113.9, 10.0.0.5"),
                Some("203.0.113.9"),
            ),
            (
                Some("127.0.0.1"),
                Some("203.0.113.9, 192.168.1.1, 10.0.0.5"),
                Some("203.0.113.9"),
            ),
            // The client wrote fake left hops: only the right-most untrusted one counts.
            (
                Some("172.18.0.2"),
                Some("1.1.1.1, 203.0.113.9"),
                Some("203.0.113.9"),
            ),
            (
                Some("172.18.0.2"),
                Some("1.1.1.1, 203.0.113.9, 10.0.0.5"),
                Some("203.0.113.9"),
            ),
            (
                Some("172.18.0.2"),
                Some("10.9.9.9, 203.0.113.9"),
                Some("203.0.113.9"),
            ),
            (
                Some("172.18.0.2"),
                Some("2.2.2.2, 3.3.3.3, 4.4.4.4, 203.0.113.9"),
                Some("203.0.113.9"),
            ),
            // A private LAN client (nginx and Caddy on the same LAN): unknown, never the proxy.
            (Some("172.18.0.2"), Some("192.168.1.50"), None),
            (Some("172.18.0.2"), Some("10.0.0.1, 192.168.0.4"), None),
            (Some("172.18.0.2"), Some("fd00::5, 10.0.0.1"), None),
            // A public hop left of private proxies is the client.
            (
                Some("172.18.0.2"),
                Some("8.8.4.4, 10.0.0.1"),
                Some("8.8.4.4"),
            ),
            // Garbage on the right: unknown, never the garbage and never what is left of it.
            (Some("172.18.0.2"), Some("203.0.113.9, not-an-ip"), None),
            (Some("172.18.0.2"), Some("203.0.113.9, "), None),
            (Some("172.18.0.2"), Some(""), None),
            (Some("172.18.0.2"), Some(" , "), None),
            (Some("172.18.0.2"), Some(",,,"), None),
            (Some("172.18.0.2"), Some("unknown"), None),
            (Some("172.18.0.2"), Some("999.1.1.1"), None),
            (Some("172.18.0.2"), Some("203.0.113.9/24"), None),
            // Ports and brackets are cut.
            (
                Some("172.18.0.2"),
                Some("203.0.113.9:5555"),
                Some("203.0.113.9"),
            ),
            (
                Some("172.18.0.2"),
                Some("[2001:db8:1:2:3:4:5:6]:443"),
                Some("2001:db8:1:2::/64"),
            ),
            (
                Some("172.18.0.2"),
                Some("[2001:db8:1:2:3:4:5:6]"),
                Some("2001:db8:1:2::/64"),
            ),
            // IPv6 clients count per /64.
            (
                Some("::1"),
                Some("2001:db8:1:2:aaaa:bbbb:cccc:dddd"),
                Some("2001:db8:1:2::/64"),
            ),
            (
                Some("::1"),
                Some("2001:db8:1:2:1::1"),
                Some("2001:db8:1:2::/64"),
            ),
            (
                Some("fd00::2"),
                Some("2a00:1450::1"),
                Some("2a00:1450:0:0::/64"),
            ),
            // IPv6 through docker-proxy: the peer is private, there is no header.
            (Some("fd00::2"), None, None),
            // IPv4 in IPv6 is the IPv4 address.
            (
                Some("::ffff:172.18.0.2"),
                Some("::ffff:203.0.113.9"),
                Some("203.0.113.9"),
            ),
            (Some("::ffff:8.8.4.4"), None, Some("8.8.4.4")),
            (Some("::ffff:10.0.0.9"), Some("::ffff:192.168.1.5"), None),
            (
                Some("::ffff:10.0.0.9"),
                Some("::ffff:8.8.8.8, ::ffff:10.0.0.1"),
                Some("8.8.8.8"),
            ),
        ];
        for (peer, xff, want) in cases {
            let peer = peer.and_then(ip);
            assert_eq!(
                client_addr(peer, *xff).as_deref(),
                *want,
                "{peer:?} {xff:?}"
            );
        }
    }

    #[test]
    fn keys_are_stable_hex_and_keyed() {
        let a = LimitKeys::new("0123456789012345678901234567890123");
        let b = LimitKeys::new("another secret another secret 1234567");
        let k = a.user("ana");
        assert_eq!(k.len(), 64);
        assert!(k
            .bytes()
            .all(|c| c.is_ascii_digit() || (b'a'..=b'f').contains(&c)));
        assert_eq!(k, a.user("ana"));
        assert_ne!(k, a.user("ben"));
        assert_ne!(k, b.user("ana"));
        // A name and an address with the same text still differ.
        assert_ne!(a.user("unknown"), a.address(None));
        assert_eq!(a.address(None), a.address(Some("unknown")));
        assert_ne!(a.address(Some("1.2.3.4")), a.address(None));
        assert!(!k.contains("ana"));
    }
}
