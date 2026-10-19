// The API publishes the username and password rules in
// xynotransit-api/tests/fixtures/rules.json (section "passwords"). Every
// number and every message of the Dart side is held against it here. The
// section is written by the API side; the test waits for it (up to 20 minutes)
// and then skips with a message.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xynotransit_app/domain/password_rules.dart';

const _path = '../xynotransit-api/tests/fixtures/rules.json';

Future<Map<String, dynamic>?> _load() async {
  final f = File(_path);
  final end = DateTime.now().add(const Duration(minutes: 20));
  while (true) {
    if (f.existsSync()) {
      try {
        final j = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
        if (j['passwords'] is Map) {
          return j['passwords'] as Map<String, dynamic>;
        }
      } on FormatException {
        // The API side is writing it right now.
      }
    }
    if (DateTime.now().isAfter(end)) return null;
    await Future<void>.delayed(const Duration(seconds: 10));
  }
}

void main() {
  Map<String, dynamic>? rules;
  setUpAll(() async => rules = await _load());

  void withRules(String name, void Function(Map<String, dynamic> r) body) {
    test(name, () {
      final r = rules;
      if (r == null) {
        markTestSkipped(
          'skipped: no "passwords" section in $_path after 20 min',
        );
        return;
      }
      body(r);
    }, timeout: const Timeout(Duration(minutes: 21)));
  }

  Map<String, dynamic> limits(Map<String, dynamic> r) =>
      r['limits'] as Map<String, dynamic>;
  Map<String, dynamic> messages(Map<String, dynamic> r) =>
      r['messages'] as Map<String, dynamic>;

  withRules('limits equal the Dart constants', (r) {
    final l = limits(r);
    expect(l['username_min'], UsernameRules.minLength);
    expect(l['username_max'], UsernameRules.maxLength);
    expect(l['password_min'], PasswordRules.minLength);
    expect(l['password_max'], PasswordRules.maxLength);
    expect(l['login_failures_per_username'], PasswordRules.failuresPerPair);
    expect(l['login_failures_per_pair'], PasswordRules.failuresPerPair);
    expect(
      l['login_failures_per_username_backstop'],
      PasswordRules.failuresBackstop,
    );
    expect(l['login_failures_per_address'], PasswordRules.failuresPerAddress);
    expect(l['trusted_address_days'], PasswordRules.trustDays);
    expect(l['link_recovery_minutes'], PasswordRules.linkRecovery.inMinutes);
    expect(l['login_window_minutes'], PasswordRules.window.inMinutes);
    expect(l['resets_per_manager_per_hour'], PasswordRules.resetsPerHour);
    expect(l['temporary_password_chars'], PasswordRules.resetLength);
  });

  withRules('the temporary password alphabet and the username pattern', (r) {
    expect(r['temporary_password_alphabet'], PasswordRules.resetAlphabet);
    final pattern = RegExp(r['username_pattern'] as String);
    for (final u in [
      'abc',
      'a.b-c_d9',
      'a' * 40,
      'ab',
      'a' * 41,
      'A.b',
      'a b',
      'é.ab',
    ]) {
      expect(
        UsernameRules.clean(u) != null,
        pattern.hasMatch(u.toLowerCase()),
        reason: 'username $u',
      );
    }
  });

  withRules('messages equal the Dart words', (r) {
    final m = messages(r);
    expect(m['username_invalid'], UsernameRules.invalid);
    expect(m['username_taken'], UsernameRules.taken);
    expect(m['login_wrong'], PasswordRules.wrongLogin);
    expect(m['login_too_many'], PasswordRules.tooManyAttempts);
    expect(m['busy'], PasswordRules.busy);
    expect(m['password_control'], PasswordRules.hasControl);
    expect(m['password_short'], PasswordRules.tooShort);
    expect(m['password_long'], PasswordRules.tooLong);
    expect(m['password_personal'], PasswordRules.looksLikeYou);
    expect(m['password_repeated'], PasswordRules.repeated);
    expect(m['password_run'], PasswordRules.simpleRun);
    expect(m['password_common'], PasswordRules.tooCommon);
    expect(m['password_new_required'], PasswordRules.newRequired);
    expect(m['password_current_required'], PasswordRules.currentRequired);
    expect(m['password_current_wrong'], PasswordRules.currentWrong);
    expect(m['password_same'], PasswordRules.sameAsCurrent);
    expect(m['choose_new_password'], PasswordRules.mustChangeFirst);
    expect(m['sign_in_again'], PasswordRules.signInAgain);
    expect(m['too_many_resets'], PasswordRules.tooManyResets);
    expect(m['switched_off'], PasswordRules.switchedOff);
    expect(m['manager_only'], 'Only the manager can do this.');
  });

  withRules('the policy checks run in the published order', (r) {
    final order = (r['policy_order'] as List).cast<String>();
    final m = messages(r);
    // One password per check: each breaks only its own rule.
    final samples = {
      'control': ['tab\there is long enough', 'password_control'],
      'short': ['too short', 'password_short'],
      'long': ['x' * 130, 'password_long'],
      'personal': ['rosa.rakoto', 'password_personal'],
      'repeated': ['zzzzzzzzzzzz', 'password_repeated'],
      'run': ['abcdefghijkl', 'password_run'],
      'common': ['password123', 'password_common'],
    };
    expect(order, samples.keys.toList());
    for (final name in order) {
      final (pw, key) = (samples[name]![0], samples[name]![1]);
      expect(
        PasswordRules.check(pw, username: 'rosa.rakoto'),
        m[key],
        reason: name,
      );
    }
    // When two rules break at once, the earlier one in the order speaks.
    expect(PasswordRules.check('\t\t\t'), m['password_control']);
    expect(
      PasswordRules.check('rosa.rakoto', username: 'rosa.rakoto'),
      m['password_personal'],
    );
    // A repeated character is both repeated and, with a username of the same
    // text, personal: personal comes first.
    expect(
      PasswordRules.check('aaaaaaaaaa', username: 'aaaaaaaaaa'),
      m['password_personal'],
    );
    // A run that is also on the common list reads as a run.
    expect(PasswordRules.check('1234567890'), m['password_run']);
  });
}
