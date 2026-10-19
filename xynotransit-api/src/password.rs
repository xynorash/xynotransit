//! The password policy (NIST style: length and common sense, no composition rules). Pure.
//!
//! Spaces are allowed and kept exactly as typed. Length counts Unicode scalar values (one emoji is
//! one character). The checks run in this order and the first that fails gives the message:
//! control characters, too short, too long, same as the username / email / name, one repeated
//! character, a simple run, a common password.

use std::{collections::HashSet, sync::OnceLock};

pub const MIN_CHARS: usize = 10;
pub const MAX_CHARS: usize = 128;

pub mod msg {
    pub const CONTROL: &str = "Use letters, numbers, spaces and symbols only.";
    pub const SHORT: &str = "Use at least 10 characters.";
    pub const LONG: &str = "Use at most 128 characters.";
    pub const PERSONAL: &str = "Do not use your username, email address or name as a password.";
    pub const REPEATED: &str = "Do not repeat one character.";
    pub const RUN: &str = "Do not use a simple run such as 1234567890 or abcdefghij.";
    pub const COMMON: &str = "That password is too common. Pick something only you would think of.";
    pub const NEW_REQUIRED: &str = "Enter a new password.";
    pub const CURRENT_REQUIRED: &str = "Enter your current password.";
    pub const SAME: &str = "Choose a password different from the current one.";
    pub const CURRENT_WRONG: &str = "Your current password is not right.";
}

/// The form a password is stored and compared in: Unicode NFKC (NIST SP 800-63B), so the same
/// typed password works whether a device sends "é" as one letter or as e plus an accent, or
/// full-width letters. Length, the policy and hashing all work on this form.
pub fn normalize(password: &str) -> String {
    use unicode_normalization::UnicodeNormalization;
    password.nfkc().collect()
}

/// Longer than any password can be, once normalised? Then it cannot be anyone's password.
pub fn too_long(password: &str) -> bool {
    normalize(password).chars().count() > MAX_CHARS
}

/// Who the password is for: it may not be the same as any of these (ignoring case).
#[derive(Debug, Clone, Copy, Default)]
pub struct Subject<'a> {
    pub username: &'a str,
    pub email: &'a str,
    pub full_name: &'a str,
}

static COMMON: OnceLock<HashSet<&'static str>> = OnceLock::new();

/// The built-in list of common passwords (lowercase, one per line, each 10 characters or more).
pub fn common_list() -> &'static HashSet<&'static str> {
    COMMON.get_or_init(|| {
        include_str!("common_passwords.txt")
            .lines()
            .map(str::trim)
            .filter(|l| !l.is_empty())
            .collect()
    })
}

pub fn is_common(password: &str) -> bool {
    common_list().contains(password.to_lowercase().as_str())
}

/// All the same character (at least 2 long).
fn is_repeated(chars: &[char]) -> bool {
    chars.len() > 1 && chars.iter().all(|c| *c == chars[0])
}

/// Every character is the next (or every one the previous) one, ignoring case: abcdefghij,
/// jihgfedcba. Digits wrap around, so 1234567890 and 0987654321 count as runs too.
fn is_run(chars: &[char]) -> bool {
    if chars.len() < 2 {
        return false;
    }
    let lower: Vec<char> = chars.iter().flat_map(|c| c.to_lowercase()).collect();
    let step = |a: char, b: char, d: i64| -> bool {
        if a.is_ascii_digit() && b.is_ascii_digit() {
            // Digits wrap: 9 then 0, 0 then 9 going down.
            let (x, y) = (a as i64 - '0' as i64, b as i64 - '0' as i64);
            return (y - x).rem_euclid(10) == d.rem_euclid(10);
        }
        b as i64 - a as i64 == d
    };
    [1i64, -1]
        .iter()
        .any(|d| lower.windows(2).all(|w| step(w[0], w[1], *d)))
}

/// Check a new password. `Ok` or the plain message to show.
pub fn check(password: &str, who: Subject<'_>) -> Result<(), &'static str> {
    let normalized = normalize(password);
    let password = normalized.as_str();
    if password.chars().any(char::is_control) {
        return Err(msg::CONTROL);
    }
    let chars: Vec<char> = password.chars().collect();
    if chars.len() < MIN_CHARS {
        return Err(msg::SHORT);
    }
    if chars.len() > MAX_CHARS {
        return Err(msg::LONG);
    }
    let lower = password.to_lowercase();
    let local = who.email.split('@').next().unwrap_or("");
    let personal = [who.username, who.email, local, who.full_name];
    if personal
        .iter()
        .any(|p| !p.is_empty() && p.to_lowercase() == lower)
    {
        return Err(msg::PERSONAL);
    }
    if is_repeated(&chars) {
        return Err(msg::REPEATED);
    }
    if is_run(&chars) {
        return Err(msg::RUN);
    }
    if common_list().contains(lower.as_str()) {
        return Err(msg::COMMON);
    }
    Ok(())
}

/// A random temporary password: 16 characters from an alphabet without look-alikes
/// (no 0 O 1 l I), about 92 bits.
pub fn temporary() -> String {
    use rand::Rng;
    const ALPHABET: &[u8] = b"ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789";
    let mut rng = rand::rng();
    (0..16)
        .map(|_| ALPHABET[rng.random_range(0..ALPHABET.len())] as char)
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    const WHO: Subject<'static> = Subject {
        username: "rosa.rakoto",
        email: "Rosa.Rakoto@Example.org",
        full_name: "Rosa Rakoto Andrianaivo",
    };

    #[test]
    fn table_of_messages() {
        let long_ok = "x7!".repeat(42); // 126
        let cases: Vec<(String, Result<(), &str>)> = vec![
            ("".into(), Err(msg::SHORT)),
            ("123456789".into(), Err(msg::SHORT)),
            ("short one".into(), Err(msg::SHORT)),
            ("tab\there is long".into(), Err(msg::CONTROL)),
            ("new\nline is long".into(), Err(msg::CONTROL)),
            ("nul\0 is long enough".into(), Err(msg::CONTROL)),
            ("\u{7f}delete is long".into(), Err(msg::CONTROL)),
            ("\r\nxxxxxxxxxxxxx".into(), Err(msg::CONTROL)),
            // Control wins over length.
            ("\t".into(), Err(msg::CONTROL)),
            ("x".repeat(129), Err(msg::LONG)),
            ("é".repeat(129), Err(msg::LONG)),
            ("ROSA.RAKOTO".into(), Err(msg::PERSONAL)),
            ("rosa.rakoto@example.org".into(), Err(msg::PERSONAL)),
            ("Rosa Rakoto Andrianaivo".into(), Err(msg::PERSONAL)),
            ("rosa rakoto andrianaivo".into(), Err(msg::PERSONAL)),
            ("aaaaaaaaaa".into(), Err(msg::REPEATED)),
            ("          ".into(), Err(msg::REPEATED)),
            ("zzzzzzzzzzzzzzzzzzzzzzzz".into(), Err(msg::REPEATED)),
            ("1234567890".into(), Err(msg::RUN)),
            ("0123456789".into(), Err(msg::RUN)),
            ("9876543210".into(), Err(msg::RUN)),
            ("abcdefghij".into(), Err(msg::RUN)),
            ("ABCDEFGHIJ".into(), Err(msg::RUN)),
            ("jihgfedcba".into(), Err(msg::RUN)),
            ("123456789012".into(), Err(msg::RUN)),
            ("password123".into(), Err(msg::COMMON)),
            ("PassWord123".into(), Err(msg::COMMON)),
            ("Qwertyuiop".into(), Err(msg::COMMON)),
            ("iloveyou123".into(), Err(msg::COMMON)),
            ("correct horse battery".into(), Ok(())),
            ("a b c d e f g h".into(), Ok(())),
            ("  leading spaces kept  ".into(), Ok(())),
            ("tenchars!!".into(), Ok(())),
            ("1234567891".into(), Err(msg::COMMON)),
            ("abcdefghik".into(), Ok(())),
            ("1234567809".into(), Ok(())),
            ("12345678901".into(), Err(msg::RUN)),
            (long_ok, Ok(())),
            ("x".repeat(127) + "y", Ok(())),
        ];
        for (pw, want) in cases {
            assert_eq!(check(&pw, WHO), want, "{pw:?}");
        }
    }

    #[test]
    fn length_counts_unicode_scalars() {
        // Nine emoji are nine characters although each is four bytes.
        let nine = "😀😁😂🤣😃😄😅😆😉";
        assert_eq!(nine.chars().count(), 9);
        assert!(nine.len() > 10);
        assert_eq!(check(nine, WHO), Err(msg::SHORT));
        let ten = "😀😁😂🤣😃😄😅😆😉😊";
        assert_eq!(check(ten, WHO), Ok(()));
        // 128 accented letters pass, 129 do not, though 128 of them are 256 bytes.
        let max = "é".repeat(64) + &"è".repeat(64);
        assert_eq!(max.chars().count(), 128);
        assert_eq!(check(&max, WHO), Ok(()));
        assert_eq!(check(&(max + "e"), WHO), Err(msg::LONG));
        // Letters with a combining accent are folded to one letter first (NFKC), so five of
        // them are five characters, not ten.
        let combining = "e\u{301}".repeat(5);
        assert_eq!(combining.chars().count(), 10);
        assert_eq!(check(&combining, WHO), Err(msg::SHORT));
        assert_eq!(check(&"e\u{301}".repeat(10), WHO), Err(msg::REPEATED));
    }

    #[test]
    fn spaces_are_kept_not_trimmed() {
        // Ten characters only because of the spaces.
        assert_eq!(check("  ab cd   ", WHO), Ok(()));
        assert_eq!(check("ab cd", WHO), Err(msg::SHORT));
        // A password that equals the name only with its spaces cut is a different password.
        let who = Subject {
            username: "longusername",
            email: "",
            full_name: "",
        };
        assert_eq!(check("longusername", who), Err(msg::PERSONAL));
        assert_eq!(check(" longusername", who), Ok(()));
    }

    #[test]
    fn empty_subject_fields_never_match() {
        let none = Subject::default();
        assert_eq!(check("some fine passphrase", none), Ok(()));
        assert_eq!(check(&"q".repeat(10), none), Err(msg::REPEATED));
    }

    #[test]
    fn local_part_without_at_sign() {
        let who = Subject {
            username: "x",
            email: "weirdaddress",
            full_name: "",
        };
        assert_eq!(check("weirdaddress", who), Err(msg::PERSONAL));
    }

    #[test]
    fn the_common_list_is_sound() {
        let list = include_str!("common_passwords.txt");
        let mut seen = HashSet::new();
        let mut n = 0;
        for l in list.lines() {
            n += 1;
            assert!(
                l.chars().count() >= MIN_CHARS,
                "{l:?} is too short to matter"
            );
            assert_eq!(l, l.to_lowercase(), "{l:?} must be lowercase");
            assert_eq!(l, l.trim(), "{l:?}");
            assert!(seen.insert(l), "{l:?} twice");
        }
        assert!(n >= 300, "only {n} entries");
        assert_eq!(common_list().len(), n);
        assert!(is_common("PASSWORD1234"));
        assert!(!is_common("a purple bicycle"));
    }

    #[test]
    fn temporary_passwords() {
        let all: HashSet<String> = (0..200).map(|_| temporary()).collect();
        assert_eq!(all.len(), 200);
        for t in &all {
            assert_eq!(t.chars().count(), 16);
            assert!(t.chars().all(|c| c.is_ascii_alphanumeric()));
            assert!(!t.chars().any(|c| "0O1lI".contains(c)), "{t}");
        }
    }
}
