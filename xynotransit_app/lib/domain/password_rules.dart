/// Usernames and passwords: what is allowed, in the same order and with the
/// same words as the API (xynotransit-api/src/rules.rs). The in-memory demo
/// uses these too, and the parity test holds the numbers against
/// xynotransit-api/tests/fixtures/rules.json.
///
/// Normalisation: the server normalises passwords to Unicode NFKC before it
/// checks and hashes them (so "ﬁ" and "fi" are the same password). The hints
/// in the app look at the raw text as typed; this is on purpose and the server
/// has the last word. Usernames are trimmed and lower-cased on both sides.
library;

import 'common_passwords.dart';
import 'text_rules.dart';

/// The shape of a username: lower case letters, digits, dot, dash, underscore.
class UsernameRules {
  const UsernameRules._();

  static const minLength = 3;
  static const maxLength = 40;

  static const invalid =
      'Usernames use letters, digits, dots, dashes and underscores, '
      '3 to 40 characters.';
  static const taken = 'That username is already used.';

  /// Trimmed and lower case, or null when it does not follow the rules.
  static String? clean(String s) {
    final u = trimText(s).toLowerCase();
    if (u.length < minLength || u.length > maxLength) return null;
    for (final c in u.codeUnits) {
      final ok =
          (c >= 0x61 && c <= 0x7A) ||
          (c >= 0x30 && c <= 0x39) ||
          c == 0x2E ||
          c == 0x2D ||
          c == 0x5F;
      if (!ok) return null;
    }
    return u;
  }

  /// The username a new person gets: the part of the email before the @, with
  /// anything that is not allowed taken out, then a number when it is used.
  static String fromEmail(String email, bool Function(String) isTaken) {
    final at = email.indexOf('@');
    final local = (at < 0 ? email : email.substring(0, at)).toLowerCase();
    var base = local.replaceAll(RegExp(r'[^a-z0-9._-]'), '');
    if (base.length < minLength) {
      base = '${base}user'.padRight(minLength, 'x');
    }
    if (base.length > maxLength - 4) base = base.substring(0, maxLength - 4);
    var candidate = base;
    for (var n = 2; isTaken(candidate); n++) {
      candidate = '$base$n';
    }
    return candidate;
  }
}

/// Strength as the meter shows it. It only looks at length and at whether the
/// password is a common one, never at "letters and symbols".
enum PasswordStrength { empty, tooShort, weak, fair, good, strong }

class PasswordRules {
  const PasswordRules._();

  static const minLength = 10;
  static const maxLength = 128;

  static const tooShort = 'Use at least 10 characters.';
  static const tooLong = 'Use at most 128 characters.';
  static const hasControl = 'Use letters, numbers, spaces and symbols only.';
  static const looksLikeYou =
      'Do not use your username, email address or name as a password.';
  static const repeated = 'Do not repeat one character.';
  static const simpleRun =
      'Do not use a simple run such as 1234567890 or abcdefghij.';
  static const tooCommon =
      'That password is too common. Pick something only you would think of.';
  static const newRequired = 'Enter a new password.';
  static const currentRequired = 'Enter your current password.';
  static const sameAsCurrent =
      'Choose a password different from the current one.';
  static const mismatch = 'The two passwords are not the same.';
  static const currentWrong = 'Your current password is not right.';
  static const wrongLogin = 'Username or password is wrong.';
  static const tooManyAttempts = 'Too many sign-in attempts. Try again later.';
  static const mustChangeFirst = 'Choose a new password first.';
  static const signInAgain = 'Please sign in again.';
  static const switchedOff = 'This person is switched off.';
  static const busy = 'Busy, try again in a moment.';
  static const tooManyResets =
      'Too many temporary passwords created. Try again later.';

  /// Failed sign-ins allowed for one pair of username and address in
  /// [window]; only that pair is locked.
  static const failuresPerPair = 5;

  /// Failed sign-ins for one username from any address in [window]. Then
  /// every address that has not signed in as that person lately is locked.
  static const failuresBackstop = 100;

  /// Failed sign-ins from one known public address in [window].
  static const failuresPerAddress = 30;

  /// An address that signed in as the person within this many days is
  /// trusted when the backstop applies.
  static const trustDays = 30;

  /// A session that began with a link may choose a new password without the
  /// old one for this long.
  static const linkRecovery = Duration(minutes: 15);
  static const window = Duration(minutes: 15);
  static const resetsPerHour = 30;
  static const resetLength = 16;

  /// The first problem with [password], or null when it is fine. Spaces are
  /// kept exactly as typed. [username], [email] and [fullName] are the ones of
  /// the person it is for; the password may not be any of them (ignoring case),
  /// nor the part of the email before the @.
  static String? check(
    String password, {
    String? username,
    String? email,
    String? fullName,
  }) {
    for (final c in password.runes) {
      if (isControlRune(c)) return hasControl;
    }
    final n = charCount(password);
    if (n < minLength) return tooShort;
    if (n > maxLength) return tooLong;
    final lower = password.toLowerCase();
    final mail = (email ?? '').toLowerCase();
    final at = mail.indexOf('@');
    final same = <String>{
      if (username != null && username.isNotEmpty) username.toLowerCase(),
      if (mail.isNotEmpty) mail,
      if (at > 0) mail.substring(0, at),
      if (fullName != null && fullName.trim().isNotEmpty)
        fullName.trim().toLowerCase(),
    };
    if (same.contains(lower)) return looksLikeYou;
    if (_oneCharacter(password)) return repeated;
    if (_run(password)) return simpleRun;
    if (commonPasswords.contains(lower)) return tooCommon;
    return null;
  }

  static bool _oneCharacter(String s) {
    final r = s.runes.toList();
    return r.length > 1 && r.every((c) => c == r.first);
  }

  /// Each character is the next one up (or each the next one down), ignoring
  /// case, digits going on from 9 to 0: 1234567890, abcdefghij, 9876543210.
  static bool _run(String s) {
    final r = s.toLowerCase().runes.toList();
    if (r.length < 2) return false;
    bool digit(int c) => c >= 0x30 && c <= 0x39;
    bool step(int dir) {
      for (var i = 1; i < r.length; i++) {
        final a = r[i - 1];
        final b = r[i];
        if (digit(a) && digit(b)) {
          if (((b - a) - dir) % 10 != 0) return false;
        } else if (b - a != dir) {
          return false;
        }
      }
      return true;
    }

    return step(1) || step(-1);
  }

  /// What the strength meter shows. Length and common-ness only.
  static PasswordStrength strength(String password) {
    if (password.isEmpty) return PasswordStrength.empty;
    final n = charCount(password);
    if (n < minLength) return PasswordStrength.tooShort;
    final lower = password.toLowerCase();
    if (commonPasswords.contains(lower) ||
        _oneCharacter(password) ||
        _run(password)) {
      return PasswordStrength.weak;
    }
    if (n < 14) return PasswordStrength.fair;
    if (n < 20) return PasswordStrength.good;
    return PasswordStrength.strong;
  }

  /// Words next to the meter.
  static String strengthWords(PasswordStrength s) => switch (s) {
    PasswordStrength.empty => '',
    PasswordStrength.tooShort => 'Too short',
    PasswordStrength.weak => 'Too easy to guess',
    PasswordStrength.fair => 'Fair',
    PasswordStrength.good => 'Good',
    PasswordStrength.strong => 'Strong',
  };

  /// Letters and digits that cannot be mistaken for each other (no 0/O, 1/l/I).
  static const resetAlphabet =
      'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789';
}
