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

#[derive(Debug, Serialize, Deserialize)]
struct Claims {
    sub: String,
    role: Role,
    iat: i64,
    exp: i64,
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

pub fn issue_jwt(
    secret: &str,
    person_id: Uuid,
    role: Role,
) -> Result<(String, DateTime<Utc>), ApiError> {
    let now = Utc::now();
    let exp = now + Duration::days(JWT_DAYS);
    let claims = Claims {
        sub: person_id.to_string(),
        role,
        iat: now.timestamp(),
        exp: exp.timestamp(),
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

fn person_from_jwt(secret: &str, token: &str) -> Option<Uuid> {
    let data = decode::<Claims>(
        token,
        &DecodingKey::from_secret(secret.as_bytes()),
        &Validation::new(jsonwebtoken::Algorithm::HS256),
    )
    .ok()?;
    Uuid::parse_str(&data.claims.sub).ok()
}

/// The signed-in, active person. Role comes from the database.
#[derive(Debug, Clone)]
pub struct AuthUser {
    pub person_id: Uuid,
    pub role: Role,
    pub label: String,
}

impl AuthUser {
    pub fn is_controller(&self) -> bool {
        self.role == Role::Controller
    }

    pub fn require_controller(&self) -> Result<(), ApiError> {
        if self.is_controller() {
            Ok(())
        } else {
            Err(ApiError::forbidden("Only the controller can do this."))
        }
    }
}

const SIGN_IN_MSG: &str = "Please sign in.";

impl FromRequestParts<AppState> for AuthUser {
    type Rejection = ApiError;

    async fn from_request_parts(
        parts: &mut Parts,
        state: &AppState,
    ) -> Result<Self, Self::Rejection> {
        let header = parts
            .headers
            .get(axum::http::header::AUTHORIZATION)
            .and_then(|v| v.to_str().ok())
            .ok_or_else(|| ApiError::unauthorized(SIGN_IN_MSG))?;
        let token = header
            .strip_prefix("Bearer ")
            .ok_or_else(|| ApiError::unauthorized(SIGN_IN_MSG))?;
        let person_id = person_from_jwt(&state.config.jwt_secret, token.trim())
            .ok_or_else(|| ApiError::unauthorized(SIGN_IN_MSG))?;
        load_user(&state.pool, person_id)
            .await?
            .ok_or_else(|| ApiError::unauthorized(SIGN_IN_MSG))
    }
}

/// Active person by id, with the current role.
pub async fn load_user(pool: &sqlx::PgPool, person_id: Uuid) -> Result<Option<AuthUser>, ApiError> {
    let row: Option<(String, String)> =
        sqlx::query_as("select app_role::text, full_name from person where id = $1 and active")
            .bind(person_id)
            .fetch_optional(pool)
            .await?;
    Ok(row.map(|(role, label)| AuthUser {
        person_id,
        role: Role::parse(&role),
        label,
    }))
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
        let (t, _) = issue_jwt(secret, id, Role::Controller).unwrap();
        assert_eq!(person_from_jwt(secret, &t), Some(id));
        assert_eq!(
            person_from_jwt("another secret another secret 123456", &t),
            None
        );
        assert_eq!(person_from_jwt(secret, "garbage"), None);
    }

    #[test]
    fn hash_is_stable_sha256() {
        assert_eq!(hash_token("a").len(), 32);
        assert_eq!(hash_token("a"), hash_token("a"));
        assert_ne!(hash_token("a"), hash_token("b"));
    }
}
