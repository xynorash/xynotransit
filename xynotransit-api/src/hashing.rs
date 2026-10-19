//! Password hashing: Argon2id, run off the async threads and behind a small semaphore.
//!
//! The production parameters are the OWASP minimum (m=19456 KiB, t=2, p=1). The target machine has
//! 1 GB of RAM, so at most two hashes run at the same time (about 40 MiB); a request that cannot
//! get a place within a short time is answered 503 "Busy, try again in a moment.". Tests use far
//! cheaper parameters through `Config` (`PASSWORD_HASH_MEMORY_KIB`, `PASSWORD_HASH_ITERATIONS`);
//! the PHC string carries its own parameters, so a hash made with other parameters still verifies
//! and is made again with the current ones after the next good sign-in.
//! A password is never logged and never part of an error.

use std::{sync::Arc, time::Duration};

use argon2::{
    password_hash::{PasswordHash, PasswordHasher, PasswordVerifier, SaltString},
    Algorithm, Argon2, Params, Version,
};
use rand::RngCore;
use tokio::sync::Semaphore;

/// OWASP minimum for Argon2id.
pub const DEFAULT_MEMORY_KIB: u32 = 19_456;
pub const DEFAULT_ITERATIONS: u32 = 2;
pub const DEFAULT_PARALLELISM: u32 = 1;
/// Hashes that may run at once.
pub const PERMITS: usize = 2;
/// How long a request waits for a place before the answer is 503.
pub const QUEUE_WAIT: Duration = Duration::from_secs(5);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct HashSettings {
    pub memory_kib: u32,
    pub iterations: u32,
    pub parallelism: u32,
}

impl Default for HashSettings {
    fn default() -> Self {
        HashSettings {
            memory_kib: DEFAULT_MEMORY_KIB,
            iterations: DEFAULT_ITERATIONS,
            parallelism: DEFAULT_PARALLELISM,
        }
    }
}

impl HashSettings {
    pub fn is_below_owasp_minimum(&self) -> bool {
        self.memory_kib < DEFAULT_MEMORY_KIB || self.iterations < DEFAULT_ITERATIONS
    }

    fn params(&self) -> Result<Params, HashError> {
        Params::new(self.memory_kib, self.iterations, self.parallelism, None)
            .map_err(|_| HashError::Failed)
    }
}

#[derive(Debug, PartialEq, Eq)]
pub enum HashError {
    /// No place became free in time.
    Busy,
    Failed,
}

/// The result of checking a password against a stored hash.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Verdict {
    pub ok: bool,
    /// The stored hash was made with other parameters than the current ones.
    pub needs_rehash: bool,
}

#[derive(Clone)]
pub struct Hasher {
    settings: HashSettings,
    sem: Arc<Semaphore>,
    wait: Duration,
    /// A hash of a random password, checked against when there is no real hash so that unknown
    /// users cost the same time as known ones.
    dummy: Arc<String>,
}

fn salt() -> Result<SaltString, HashError> {
    let mut bytes = [0u8; 16];
    rand::rng().fill_bytes(&mut bytes);
    SaltString::encode_b64(&bytes).map_err(|_| HashError::Failed)
}

fn hash_now(settings: HashSettings, password: &str) -> Result<String, HashError> {
    let argon = Argon2::new(Algorithm::Argon2id, Version::V0x13, settings.params()?);
    argon
        .hash_password(password.as_bytes(), &salt()?)
        .map(|h| h.to_string())
        .map_err(|_| HashError::Failed)
}

fn verify_now(settings: HashSettings, password: &str, phc: &str) -> Verdict {
    let Ok(parsed) = PasswordHash::new(phc) else {
        return Verdict {
            ok: false,
            needs_rehash: false,
        };
    };
    // Verification uses the parameters inside the stored string.
    let ok = Argon2::default()
        .verify_password(password.as_bytes(), &parsed)
        .is_ok();
    Verdict {
        ok,
        needs_rehash: ok && !matches_settings(&parsed, settings),
    }
}

fn matches_settings(parsed: &PasswordHash<'_>, s: HashSettings) -> bool {
    if parsed.algorithm.as_str() != "argon2id" {
        return false;
    }
    match Params::try_from(parsed) {
        Ok(p) => {
            p.m_cost() == s.memory_kib
                && p.t_cost() == s.iterations
                && p.p_cost() == s.parallelism
                && parsed.version == Some(0x13)
        }
        Err(_) => false,
    }
}

impl Hasher {
    pub fn new(settings: HashSettings) -> Self {
        Self::with_limits(settings, PERMITS, QUEUE_WAIT)
    }

    pub fn with_limits(settings: HashSettings, permits: usize, wait: Duration) -> Self {
        let mut junk = [0u8; 24];
        rand::rng().fill_bytes(&mut junk);
        let dummy = hash_now(settings, &format!("{junk:?}")).unwrap_or_default();
        Hasher {
            settings,
            sem: Arc::new(Semaphore::new(permits)),
            wait,
            dummy: Arc::new(dummy),
        }
    }

    pub fn settings(&self) -> HashSettings {
        self.settings
    }

    /// Places free right now (for tests).
    pub fn available(&self) -> usize {
        self.sem.available_permits()
    }

    /// The semaphore, so a test can hold places and see the 503.
    pub fn semaphore(&self) -> Arc<Semaphore> {
        self.sem.clone()
    }

    async fn run<T: Send + 'static>(
        &self,
        work: impl FnOnce() -> T + Send + 'static,
    ) -> Result<T, HashError> {
        let permit = match tokio::time::timeout(self.wait, self.sem.clone().acquire_owned()).await {
            Ok(Ok(p)) => p,
            _ => return Err(HashError::Busy),
        };
        tokio::task::spawn_blocking(move || {
            let out = work();
            drop(permit);
            out
        })
        .await
        .map_err(|_| HashError::Failed)
    }

    /// Hash a new password into a PHC string.
    pub async fn hash(&self, password: &str) -> Result<String, HashError> {
        let (s, pw) = (self.settings, crate::password::normalize(password));
        self.run(move || hash_now(s, &pw)).await?
    }

    /// Check a password against a stored hash; with `None` it checks against the dummy hash and
    /// never says yes, so the time spent is the same either way.
    pub async fn verify(&self, password: &str, stored: Option<&str>) -> Result<Verdict, HashError> {
        let (s, pw) = (self.settings, crate::password::normalize(password));
        let real = stored.is_some();
        let phc = stored
            .map(str::to_owned)
            .unwrap_or_else(|| (*self.dummy).clone());
        let v = self.run(move || verify_now(s, &pw, &phc)).await?;
        Ok(if real {
            v
        } else {
            Verdict {
                ok: false,
                needs_rehash: false,
            }
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cheap() -> HashSettings {
        HashSettings {
            memory_kib: 64,
            iterations: 1,
            parallelism: 1,
        }
    }

    #[tokio::test]
    async fn hash_and_verify() {
        let h = Hasher::new(cheap());
        let phc = h.hash("correct horse battery").await.unwrap();
        assert!(phc.starts_with("$argon2id$v=19$m=64,t=1,p=1$"), "{phc}");
        assert!(!phc.contains("correct"));
        let v = h.verify("correct horse battery", Some(&phc)).await.unwrap();
        assert_eq!(
            v,
            Verdict {
                ok: true,
                needs_rehash: false
            }
        );
        assert!(
            !h.verify("correct horse batter", Some(&phc))
                .await
                .unwrap()
                .ok
        );
        assert!(!h.verify("", Some(&phc)).await.unwrap().ok);
        // Same password, new salt.
        assert_ne!(phc, h.hash("correct horse battery").await.unwrap());
    }

    #[tokio::test]
    async fn unicode_and_spaces_are_exact() {
        let h = Hasher::new(cheap());
        let phc = h.hash("  été 😀 pass ").await.unwrap();
        assert!(h.verify("  été 😀 pass ", Some(&phc)).await.unwrap().ok);
        assert!(!h.verify("été 😀 pass", Some(&phc)).await.unwrap().ok);
    }

    #[tokio::test]
    async fn dummy_never_says_yes() {
        let h = Hasher::new(cheap());
        assert!(!h.verify("anything at all", None).await.unwrap().ok);
        assert!(!h.dummy.is_empty());
    }

    #[tokio::test]
    async fn garbage_hash_is_a_no() {
        let h = Hasher::new(cheap());
        for bad in [
            "",
            "plain",
            "$argon2id$garbage",
            "$2b$12$abcdefghijklmnopqrstuv",
        ] {
            assert!(
                !h.verify("whatever long", Some(bad)).await.unwrap().ok,
                "{bad}"
            );
        }
    }

    #[tokio::test]
    async fn old_parameters_still_verify_and_ask_for_a_rehash() {
        let old = Hasher::new(cheap());
        let phc = old.hash("another passphrase").await.unwrap();
        let newer = Hasher::new(HashSettings {
            memory_kib: 128,
            ..cheap()
        });
        let v = newer
            .verify("another passphrase", Some(&phc))
            .await
            .unwrap();
        assert!(v.ok && v.needs_rehash);
        let again = newer.hash("another passphrase").await.unwrap();
        let v = newer
            .verify("another passphrase", Some(&again))
            .await
            .unwrap();
        assert!(v.ok && !v.needs_rehash);
        // A wrong password never asks for a rehash.
        let v = newer.verify("nope nope nope", Some(&phc)).await.unwrap();
        assert!(!v.ok && !v.needs_rehash);
    }

    #[tokio::test]
    async fn production_parameters_are_the_owasp_minimum() {
        let s = HashSettings::default();
        assert_eq!((s.memory_kib, s.iterations, s.parallelism), (19456, 2, 1));
        assert!(!s.is_below_owasp_minimum());
        assert!(cheap().is_below_owasp_minimum());
        let phc = hash_now(s, "a long enough password").unwrap();
        assert!(phc.starts_with("$argon2id$v=19$m=19456,t=2,p=1$"), "{phc}");
    }

    #[tokio::test]
    async fn only_so_many_hashes_at_once_then_busy() {
        let h = Hasher::with_limits(cheap(), 2, Duration::from_millis(50));
        let sem = h.semaphore();
        let a = sem.clone().acquire_owned().await.unwrap();
        let b = sem.clone().acquire_owned().await.unwrap();
        assert_eq!(h.hash("some password here").await, Err(HashError::Busy));
        assert_eq!(h.verify("x", None).await.err(), Some(HashError::Busy));
        drop(a);
        assert!(h.hash("some password here").await.is_ok());
        drop(b);
        assert_eq!(h.available(), 2);
    }
}
