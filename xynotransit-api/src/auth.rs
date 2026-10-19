//! Who is calling, and may they. The JWT only proves who; the role is read
//! from the database on every request so a demotion takes effect at once.

use axum::{extract::FromRequestParts, http::request::Parts};
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};
use chrono::{DateTime, Duration, Utc};
use jsonwebtoken::{decode, encode, DecodingKey, EncodingKey, Header, Validation};
use rand::RngCore;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use uuid::Uuid;

use crate::{error::ApiError, state::AppState};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Role {
    Contributor,
    Controller,
}

impl Role {
    pub fn parse(s: &str) -> Role {
        if s == "controller" {
            Role::Controller
        } else {
            Role::Contributor
        }
    }
}

/// How the session began. `Link`: a sign-in link that allows recovery (asked for by email, or made
/// with the recovery option); a fresh one may choose a new password without the old one (see
/// `POST /api/auth/password`). `LinkPlain`: any other link (a manager's or the server command's
/// without recovery); it always needs the current password of a person who has one. `Password`:
/// the password. Tokens made before this claim existed count as `Password`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Via {
    Link,
    #[serde(rename = "link-plain")]
    LinkPlain,
    #[default]
    Password,
}

#[derive(Debug, Serialize, Deserialize)]
struct Claims {
    sub: String,
    role: Role,
    iat: i64,
    exp: i64,
    /// The person's session_epoch when the token was made. A password change, reset or removal
    /// adds 1 to the epoch, which ends every older token. Tokens from before this existed have 0.
    #[serde(default)]
    ep: i32,
    /// "link", "link-plain" or "password".
    #[serde(default)]
    via: Via,
}

/// 32 random bytes, url-safe.
pub fn random_token() -> String {
    let mut buf = [0u8; 32];
    rand::rng().fill_bytes(&mut buf);
    URL_SAFE_NO_PAD.encode(buf)
}

pub fn hash_token(token: &str) -> Vec<u8> {
    Sha256::digest(token.as_bytes()).to_vec()
}

pub const JWT_DAYS: i64 = 7;

/// A token for a session that began with the password (or from before `via` existed).
pub fn issue_jwt(
    secret: &str,
    person_id: Uuid,
    role: Role,
    epoch: i32,
) -> Result<(String, DateTime<Utc>), ApiError> {
    issue_jwt_via(secret, person_id, role, epoch, Via::Password)
}

pub fn issue_jwt_via(
    secret: &str,
    person_id: Uuid,
    role: Role,
    epoch: i32,
    via: Via,
) -> Result<(String, DateTime<Utc>), ApiError> {
    issue_jwt_at(secret, person_id, role, epoch, via, Utc::now())
}

/// Like `issue_jwt_via` with the issue time given (tests make old sessions this way).
pub fn issue_jwt_at(
    secret: &str,
    person_id: Uuid,
    role: Role,
    epoch: i32,
    via: Via,
    now: DateTime<Utc>,
) -> Result<(String, DateTime<Utc>), ApiError> {
    let exp = now + Duration::days(JWT_DAYS);
    let claims = Claims {
        sub: person_id.to_string(),
        role,
        iat: now.timestamp(),
        exp: exp.timestamp(),
        ep: epoch,
        via,
    };
    let token = encode(
        &Header::default(),
        &claims,
        &EncodingKey::from_secret(secret.as_bytes()),
    )
    .map_err(|e| {
        tracing::error!(error = %e, "could not sign token");
        ApiError::Internal
    })?;
    Ok((token, exp))
}

struct TokenFacts {
    person_id: Uuid,
    epoch: i32,
    via: Via,
    issued_at: i64,
}

fn person_from_jwt(secret: &str, token: &str) -> Option<TokenFacts> {
    let data = decode::<Claims>(
        token,
        &DecodingKey::from_secret(secret.as_bytes()),
        &Validation::new(jsonwebtoken::Algorithm::HS256),
    )
    .ok()?;
    Some(TokenFacts {
        person_id: Uuid::parse_str(&data.claims.sub).ok()?,
        epoch: data.claims.ep,
        via: data.claims.via,
        issued_at: data.claims.iat,
    })
}

/// The signed-in, active person. Role comes from the database.
#[derive(Debug, Clone)]
pub struct AuthUser {
    pub person_id: Uuid,
    pub role: Role,
    pub label: String,
    pub username: String,
    /// The current session epoch (the token must carry the same number).
    pub epoch: i32,
    pub has_password: bool,
    pub must_change_password: bool,
    /// How this session began and when (from the token; `load_user` alone cannot know, so it
    /// says a password session issued at 0).
    pub via: Via,
    pub session_issued_at: i64,
}

impl AuthUser {
    /// A session that began with a recovery sign-in link, at most `LINK_RECOVERY_MINUTES` ago.
    pub fn fresh_link_session(&self) -> bool {
        let age = Utc::now().timestamp() - self.session_issued_at;
        self.via == Via::Link && (0..=crate::rules::LINK_RECOVERY_MINUTES * 60).contains(&age)
    }

    /// A fresh link session of a person who has a password: they may choose a new one without
    /// giving the old one (the way back for someone who forgot it).
    pub fn recent_link_session(&self) -> bool {
        self.has_password && self.fresh_link_session()
    }

    pub fn is_controller(&self) -> bool {
        self.role == Role::Controller
    }

    pub fn require_controller(&self) -> Result<(), ApiError> {
        if self.is_controller() {
            Ok(())
        } else {
            Err(ApiError::forbidden("Only the manager can do this."))
        }
    }
}

const SIGN_IN_MSG: &str = "Please sign in.";
pub const SIGN_IN_AGAIN_MSG: &str = "Please sign in again.";
pub const CHOOSE_NEW_PASSWORD_MSG: &str = "Choose a new password first.";

/// Who is calling, whatever they still have to do first. The token must be good, the person active
/// and the token's epoch the person's current one.
async fn authenticate(parts: &mut Parts, state: &AppState) -> Result<AuthUser, ApiError> {
    let header = parts
        .headers
        .get(axum::http::header::AUTHORIZATION)
        .and_then(|v| v.to_str().ok())
        .ok_or_else(|| ApiError::unauthorized(SIGN_IN_MSG))?;
    let token = header
        .strip_prefix("Bearer ")
        .ok_or_else(|| ApiError::unauthorized(SIGN_IN_MSG))?;
    let facts = person_from_jwt(&state.config.jwt_secret, token.trim())
        .ok_or_else(|| ApiError::unauthorized(SIGN_IN_MSG))?;
    let mut user = load_user(&state.pool, facts.person_id)
        .await?
        .ok_or_else(|| ApiError::unauthorized(SIGN_IN_MSG))?;
    if user.epoch != facts.epoch {
        return Err(ApiError::unauthorized(SIGN_IN_AGAIN_MSG));
    }
    user.via = facts.via;
    user.session_issued_at = facts.issued_at;
    Ok(user)
}

/// The signed-in person for every ordinary route. While the person still has to choose a new
/// password (a manager set a temporary one) every such route answers 403.
impl FromRequestParts<AppState> for AuthUser {
    type Rejection = ApiError;

    async fn from_request_parts(
        parts: &mut Parts,
        state: &AppState,
    ) -> Result<Self, Self::Rejection> {
        let user = authenticate(parts, state).await?;
        if user.must_change_password {
            return Err(ApiError::forbidden(CHOOSE_NEW_PASSWORD_MSG));
        }
        Ok(user)
    }
}

/// The signed-in person even when they must choose a new password first. Only `GET /api/me` and
/// `POST /api/auth/password` use this.
pub struct SessionUser(pub AuthUser);

impl FromRequestParts<AppState> for SessionUser {
    type Rejection = ApiError;

    async fn from_request_parts(
        parts: &mut Parts,
        state: &AppState,
    ) -> Result<Self, Self::Rejection> {
        authenticate(parts, state).await.map(SessionUser)
    }
}

/// Active person by id, with the current role and password state.
pub async fn load_user(pool: &sqlx::PgPool, person_id: Uuid) -> Result<Option<AuthUser>, ApiError> {
    let row: Option<(String, String, String, i32, bool, bool)> = sqlx::query_as(
        "select app_role::text, full_name, username, session_epoch,
                password_hash is not null, must_change_password
         from person where id = $1 and active",
    )
    .bind(person_id)
    .fetch_optional(pool)
    .await?;
    Ok(row.map(
        |(role, label, username, epoch, has_password, must_change_password)| AuthUser {
            person_id,
            role: Role::parse(&role),
            label,
            username,
            epoch,
            has_password,
            must_change_password,
            via: Via::Password,
            session_issued_at: 0,
        },
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tokens_are_long_and_unique() {
        let a = random_token();
        let b = random_token();
        assert_ne!(a, b);
        assert_eq!(a.len(), 43);
        assert!(a
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_'));
    }

    #[test]
    fn jwt_round_trip_and_wrong_secret() {
        let secret = "0123456789012345678901234567890123";
        let id = Uuid::new_v4();
        let (t, _) = issue_jwt(secret, id, Role::Controller, 3).unwrap();
        let f = person_from_jwt(secret, &t).unwrap();
        assert_eq!((f.person_id, f.epoch, f.via), (id, 3, Via::Password));
        assert!(person_from_jwt("another secret another secret 123456", &t).is_none());
        assert!(person_from_jwt(secret, "garbage").is_none());
        let (l, _) = issue_jwt_via(secret, id, Role::Contributor, 1, Via::Link).unwrap();
        assert_eq!(person_from_jwt(secret, &l).unwrap().via, Via::Link);
    }

    #[test]
    fn hash_is_stable_sha256() {
        assert_eq!(hash_token("a").len(), 32);
        assert_eq!(hash_token("a"), hash_token("a"));
        assert_ne!(hash_token("a"), hash_token("b"));
    }
}
