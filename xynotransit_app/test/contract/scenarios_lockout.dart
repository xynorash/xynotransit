// Link recovery and the targeted lockout: the same answers from the in-memory
// demo and the real API. Addresses are documentation addresses (RFC 5737);
// on the live stack they travel in X-Forwarded-For like behind Caddy.
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:xynotransit_app/data/api/api_client.dart';

import 'arena.dart';
import 'scenarios_passwords.dart' show personWithPassword;

const _wrong = 'Username or password is wrong.';
const _currentRequired = 'Enter your current password.';
const _currentWrong = 'Your current password is not right.';

final _random = Random();

/// A fresh public address, never handed out twice in one run and unlikely to
/// carry counts of an earlier run.
final _handedOut = <String>{};
String address([String net = '198.51.100']) {
  while (true) {
    final next = '$net.${1 + _random.nextInt(250)}';
    if (_handedOut.add(next)) return next;
  }
}

/// The refusal of [f] as the status and Retry-After it carried.
Future<ApiException> _refused(Future<Object?> f, {String? why}) async {
  try {
    await f;
  } on ApiException catch (e) {
    return e;
  }
  fail('${why ?? 'call'}: expected a refusal, but it succeeded');
}

void _expectLocked(ApiException e, {String? why}) {
  expect(e.statusCode, 429, reason: why);
  expect(
    e.retryAfterSeconds,
    isNotNull,
    reason: '$why: 429 carries Retry-After',
  );
  expect(e.retryAfterSeconds, inInclusiveRange(1, 900), reason: why);
  expect(
    e.message,
    matches(
      RegExp(
        r'^Too many sign-in attempts\. Try again in \d+ (second|minute)s?\.$',
      ),
    ),
    reason: '$why: ${e.message}',
  );
}

Future<void> _wrongTries(
  Arena a,
  String user,
  String from,
  int n, {
  String prefix = 'wrong',
}) async {
  for (var i = 0; i < n; i++) {
    await expectRefused(
      a.signInWithPassword(user, '$prefix try $i', address: from),
      _wrong,
      why: 'wrong try $i from $from',
    );
  }
}

/// Which link may skip the current password. A link a manager hands over does
/// not, unless the manager chose "recovery"; a link from the mailbox does. The
/// first password of a person without one never needs the old one.
Future<void> linkRecovery(Arena a) async {
  final rosa = await personWithPassword(
    a,
    'recover',
    'old long phrase ${a.tag}',
  );
  final name = rosa.username!;

  // A manager's link without recovery: signs in, but the session is plain.
  final plainLink = await a.boss.createSignInLink(rosa.id);
  expect(plainLink.recovery, isFalse);
  final plain = await a.signInWithLinkSession(plainLink.url);
  final plainMe = await plain.me();
  expect(plainMe.hasPassword, isTrue);
  expect(plainMe.recentLinkSession, isFalse, reason: 'no recovery');
  expect(await plain.repo.loadCatalog(), isNotNull);
  await expectRefused(
    plain.changePassword(newPassword: 'another long phrase ${a.tag}'),
    _currentRequired,
    why: 'a plain link needs the current password',
  );
  await expectRefused(
    plain.changePassword(
      currentPassword: 'not it at all',
      newPassword: 'another long phrase ${a.tag}',
    ),
    _currentWrong,
    why: 'and a wrong one is refused',
  );

  // A person without a password: the flag is ignored.
  final fresh = await a.makePerson('norecovery');
  final ignored = await a.boss.createSignInLink(fresh.id, recovery: true);
  expect(ignored.recovery, isFalse, reason: 'no password, no recovery link');

  // A manager's link WITH recovery: a new password without the old one.
  final link = await a.boss.createSignInLink(rosa.id, recovery: true);
  expect(link.recovery, isTrue);
  final ls = await a.signInWithLinkSession(link.url);
  final me = await ls.me();
  expect(me.hasPassword, isTrue);
  expect(me.recentLinkSession, isTrue, reason: 'a recovery link');

  // A password session of the same person is not a link session.
  final pw = await a.signInWithPassword(name, 'old long phrase ${a.tag}');
  expect((await pw.me()).recentLinkSession, isFalse);
  await expectRefused(
    pw.changePassword(newPassword: 'another long phrase ${a.tag}'),
    _currentRequired,
    why: 'a password session still needs the current password',
  );
  await expectRefused(
    pw.changePassword(
      currentPassword: 'not it at all',
      newPassword: 'another long phrase ${a.tag}',
    ),
    _currentWrong,
  );

  // The recovery session needs no current password.
  final next = 'new long phrase ${a.tag}';
  await ls.changePassword(newPassword: next);
  final after = await ls.me();
  expect(after.hasPassword, isTrue);
  expect(
    after.recentLinkSession,
    isFalse,
    reason: 'the new session is a password one',
  );
  // Everything older ended, and the old password is gone.
  await expectRefused(pw.repo.loadCatalog(), 'Please sign in again.');
  await expectRefused(plain.repo.loadCatalog(), 'Please sign in again.');
  await expectRefused(
    a.signInWithPassword(name, 'old long phrase ${a.tag}'),
    _wrong,
  );
  expect(
    await (await a.signInWithPassword(name, next)).repo.loadCatalog(),
    isNotNull,
  );

  // The new session is a password session: the next change needs the current.
  await expectRefused(
    ls.changePassword(newPassword: 'third long phrase ${a.tag}'),
    _currentRequired,
  );
  await ls.changePassword(
    currentPassword: next,
    newPassword: 'third long phrase ${a.tag}',
  );
}

/// A link from the mailbox proves control of it, so it allows recovery.
Future<void> emailLinkRecovery(Arena a) async {
  final ana = await personWithPassword(
    a,
    'mailrec',
    'old long phrase ${a.tag}',
  );
  final ls = await a.signInWithEmailLinkSession(ana);
  expect((await ls.me()).recentLinkSession, isTrue);
  await ls.changePassword(newPassword: 'fresh long phrase ${a.tag}');
  expect(
    await (await a.signInWithPassword(
      ana.username!,
      'fresh long phrase ${a.tag}',
    )).repo.loadCatalog(),
    isNotNull,
  );
}

/// The first password after any kind of link needs no current one.
Future<void> firstPasswordAfterLink(Arena a) async {
  for (final recovery in [false, true]) {
    final p = await a.makePerson('first${recovery ? 'r' : 'p'}');
    final link = await a.boss.createSignInLink(p.id, recovery: recovery);
    expect(link.recovery, isFalse, reason: 'no password yet');
    final ls = await a.signInWithLinkSession(link.url);
    expect((await ls.me()).hasPassword, isFalse);
    await ls.changePassword(newPassword: 'first long phrase ${a.tag}$recovery');
    expect((await ls.me()).hasPassword, isTrue);
  }
}

/// Failures of one address never lock the same person out at another.
Future<void> pairLockout(Arena a) async {
  final ana = await personWithPassword(a, 'pair', 'ana long phrase ${a.tag}');
  final ben = await personWithPassword(a, 'pairb', 'ben long phrase ${a.tag}');
  final name = ana.username!;
  final good = 'ana long phrase ${a.tag}';
  final attacker = address('198.51.100');
  final home = address('203.0.113');

  // 5 wrong tries lock the pair, even a right password, and say when to retry.
  await _wrongTries(a, name, attacker, 5);
  _expectLocked(
    await _refused(a.signInWithPassword(name, good, address: attacker)),
    why: 'the sixth try from the attacker',
  );
  _expectLocked(
    await _refused(
      a.signInWithPassword(name, 'wrong again', address: attacker),
    ),
    why: 'a wrong one while locked',
  );

  // Ana at home, and Ben from the attacker address, are not affected.
  final atHome = await a.signInWithPassword(name, good, address: home);
  expect(await atHome.repo.loadCatalog(), isNotNull);
  final benFromAttacker = await a.signInWithPassword(
    ben.username!,
    'ben long phrase ${a.tag}',
    address: attacker,
  );
  expect(await benFromAttacker.repo.loadCatalog(), isNotNull);

  // Failures at home count for the home pair only; a right password at an
  // address with no failures always passes.
  await _wrongTries(a, name, home, 4);
  expect(
    await (await a.signInWithPassword(
      name,
      good,
      address: home,
    )).repo.loadCatalog(),
    isNotNull,
    reason: 'four failures then the right password',
  );
  await _wrongTries(a, name, home, 4, prefix: 'again');

  // Unknown names behave the same: 401 with the same words, then 429.
  final ghost = 'ct${a.tag.toLowerCase()}.ghost';
  await _wrongTries(a, ghost, attacker, 5);
  _expectLocked(
    await _refused(a.signInWithPassword(ghost, 'one more', address: attacker)),
    why: 'unknown name',
  );
  await expectRefused(
    a.signInWithPassword(ghost, 'one more', address: home),
    _wrong,
    why: 'unknown name from another address',
  );

  // Wrong current passwords on a change are counted apart (per person), so
  // they never lock the sign-in pair, and an outsider's failed logins never
  // block the signed-in person's change.
  final other = address('203.0.113');
  final mine = await a.signInWithPassword(name, good, address: other);
  for (var i = 0; i < 4; i++) {
    await expectRefused(
      mine.changePassword(
        currentPassword: 'not mine $i',
        newPassword: 'changed long phrase ${a.tag}',
      ),
      _currentWrong,
      why: 'wrong current $i',
    );
  }
  expect(
    await (await a.signInWithPassword(
      name,
      good,
      address: other,
    )).repo.loadCatalog(),
    isNotNull,
    reason: 'wrong changes do not count toward the login pair',
  );
  final calm = await personWithPassword(a, 'pairc', 'cat long phrase ${a.tag}');
  final calmAtHome = await a.signInWithPassword(
    calm.username!,
    'cat long phrase ${a.tag}',
    address: home,
  );
  await _wrongTries(a, calm.username!, home, 5);
  _expectLocked(
    await _refused(
      a.signInWithPassword(
        calm.username!,
        'cat long phrase ${a.tag}',
        address: home,
      ),
    ),
    why: 'the login pair of the signed-in person is locked',
  );
  await calmAtHome.changePassword(
    currentPassword: 'cat long phrase ${a.tag}',
    newPassword: 'cat second phrase ${a.tag}',
  );
}

/// A thief with a token guesses the current password from many addresses: 10
/// wrong tries per person in 15 minutes, whatever the address. The 10th ends
/// every session of the person.
Future<void> changeCap(Arena a) async {
  final ana = await personWithPassword(a, 'chg', 'ana long phrase ${a.tag}');
  final name = ana.username!;
  final good = 'ana long phrase ${a.tag}';
  final sessions = [
    for (var i = 0; i < 10; i++)
      await a.signInWithPassword(name, good, address: address('198.51.100')),
  ];
  for (var i = 0; i < 9; i++) {
    await expectRefused(
      sessions[i].changePasswordRaw(
        currentPassword: 'guess $i',
        newPassword: 'changed long phrase ${a.tag}',
      ),
      _currentWrong,
      why: 'guess $i from its own address',
    );
  }
  // The tenth wrong guess answers 401 in plain words and ends every session.
  final tenth = await _refused(
    sessions[9].changePasswordRaw(
      currentPassword: 'guess 9',
      newPassword: 'changed long phrase ${a.tag}',
    ),
    why: 'the tenth guess',
  );
  expect(tenth.statusCode, 401);
  expect(tenth.message, _safety);
  for (var i = 0; i < sessions.length; i++) {
    // The client that got the 401 forgot its own token, so it asks without one.
    final said = await refusal(sessions[i].repo.loadCatalog());
    expect(
      said,
      i == 9
          ? anyOf('Please sign in.', 'Please sign in again.')
          : 'Please sign in again.',
    );
  }

  // The person signs in again with the password.
  final back = await a.signInWithPassword(name, good, address: address());
  expect(await back.repo.loadCatalog(), isNotNull);
  // Changing stays closed until the window passes, also with the right
  // current password: no eleventh check.
  _expectChangeCap(
    await _refused(
      back.changePasswordRaw(
        currentPassword: good,
        newPassword: 'changed long phrase ${a.tag}',
      ),
    ),
    why: 'the right password after the cap',
  );
  // The person is not signed out again for this: it is a wait.
  expect(await back.repo.loadCatalog(), isNotNull);
  // And signing in still works.
  expect(
    await (await a.signInWithPassword(
      name,
      good,
      address: address(),
    )).repo.loadCatalog(),
    isNotNull,
  );
}

const _safety =
    'You were signed out for safety after too many wrong passwords. '
    'Sign in again.';

void _expectChangeCap(ApiException e, {String? why}) {
  expect(e.statusCode, 429, reason: why);
  expect(e.retryAfterSeconds, isNotNull, reason: '$why: Retry-After');
  expect(e.retryAfterSeconds, inInclusiveRange(1, 900), reason: why);
  expect(
    e.message,
    matches(
      RegExp(
        r'^Too many password attempts\. Try again in \d+ (second|minute)s?\.$',
      ),
    ),
    reason: why,
  );
}

/// Wrong guesses at once from different addresses: never more than 10 checks.
Future<void> changeConcurrent(Arena a) async {
  final ana = await personWithPassword(
    a,
    'chgrace',
    'ana long phrase ${a.tag}',
  );
  final good = 'ana long phrase ${a.tag}';
  final sessions = [
    for (var i = 0; i < 14; i++)
      await a.signInWithPassword(
        ana.username!,
        good,
        address: address('203.0.113'),
      ),
  ];
  final results = await Future.wait([
    for (var i = 0; i < sessions.length; i++)
      _refused(
        sessions[i].changePasswordRaw(
          currentPassword: 'race $i',
          newPassword: 'changed long phrase ${a.tag}',
        ),
      ),
  ]);
  final checked = results.where((e) => e.statusCode == 403).length;
  expect(checked, lessThanOrEqualTo(10), reason: 'no 11th verification');
  expect(checked, greaterThanOrEqualTo(9));
  for (final e in results.where((e) => e.statusCode != 403)) {
    expect(e.statusCode, anyOf(401, 429), reason: e.message);
  }
  // Nothing was changed: the old password still signs in.
  expect(
    await (await a.signInWithPassword(
      ana.username!,
      good,
      address: address(),
    )).repo.loadCatalog(),
    isNotNull,
  );
}

/// 100 failures for one username from any addresses lock it for everyone
/// except addresses that signed in as that person lately.
Future<void> backstop(Arena a) async {
  final ana = await personWithPassword(a, 'back', 'ana long phrase ${a.tag}');
  final ben = await personWithPassword(a, 'backb', 'ben long phrase ${a.tag}');
  final name = ana.username!;
  final good = 'ana long phrase ${a.tag}';
  final trusted = address('203.0.113');
  final byLink = address('198.51.100');
  final stranger = address('192.0.2');

  // Two addresses that signed in as Ana: one with the password, one with a link.
  expect(
    await (await a.signInWithPassword(
      name,
      good,
      address: trusted,
    )).repo.loadCatalog(),
    isNotNull,
  );
  final link = await a.boss.createSignInLink(ana.id);
  final viaLink = await a.signInWithLinkSession(link.url, address: byLink);
  expect(await viaLink.repo.loadCatalog(), isNotNull);

  // 100 failures, each from its own address (so no pair or address limit hits).
  for (var i = 0; i < 100; i++) {
    final from = address(['198.51.100', '203.0.113', '192.0.2'][i % 3]);
    await expectRefused(
      a.signInWithPassword(name, 'spray $i', address: from),
      _wrong,
      why: 'spray $i',
    );
  }

  _expectLocked(
    await _refused(a.signInWithPassword(name, good, address: stranger)),
    why: 'untrusted address, right password',
  );
  _expectLocked(
    await _refused(a.signInWithPassword(name, 'wrong', address: stranger)),
    why: 'untrusted address, wrong password',
  );
  // Trusted addresses still get in with the right password.
  expect(
    await (await a.signInWithPassword(
      name,
      good,
      address: trusted,
    )).repo.loadCatalog(),
    isNotNull,
    reason: 'trusted by a password sign-in',
  );
  expect(
    await (await a.signInWithPassword(
      name,
      good,
      address: byLink,
    )).repo.loadCatalog(),
    isNotNull,
    reason: 'trusted by a link sign-in',
  );
  // Someone else is not locked.
  expect(
    await (await a.signInWithPassword(
      ben.username!,
      'ben long phrase ${a.tag}',
      address: stranger,
    )).repo.loadCatalog(),
    isNotNull,
  );
}

/// 30 failures from one known address lock that address, for every username.
Future<void> addressCap(Arena a) async {
  final ana = await personWithPassword(a, 'cap', 'ana long phrase ${a.tag}');
  final from = address('192.0.2');
  // 30 failures over unknown names (5 per name keeps every pair open).
  for (var i = 0; i < 30; i++) {
    await expectRefused(
      a.signInWithPassword(
        'ct${a.tag.toLowerCase()}.ghost${i ~/ 4}',
        'spray $i',
        address: from,
      ),
      _wrong,
      why: 'failure $i',
    );
  }
  _expectLocked(
    await _refused(
      a.signInWithPassword(
        ana.username!,
        'ana long phrase ${a.tag}',
        address: from,
      ),
    ),
    why: 'the address is locked for everybody',
  );
  expect(
    await (await a.signInWithPassword(
      ana.username!,
      'ana long phrase ${a.tag}',
      address: address('203.0.113'),
    )).repo.loadCatalog(),
    isNotNull,
    reason: 'another address is free',
  );
}

/// 24 wrong tries at once from one pair: exactly 5 are 401, the rest 429.
Future<void> pairConcurrent(Arena a) async {
  final ana = await personWithPassword(a, 'race', 'ana long phrase ${a.tag}');
  final from = address('203.0.113');
  final results = await Future.wait([
    for (var i = 0; i < 24; i++)
      _refused(a.signInWithPassword(ana.username!, 'race $i', address: from)),
  ]);
  expect(results.where((e) => e.statusCode == 401).length, 5);
  expect(results.where((e) => e.statusCode == 429).length, 19);
  for (final e in results.where((e) => e.statusCode == 429)) {
    _expectLocked(e, why: 'concurrent');
  }
  for (final e in results.where((e) => e.statusCode == 401)) {
    expect(e.message, _wrong);
  }
}
