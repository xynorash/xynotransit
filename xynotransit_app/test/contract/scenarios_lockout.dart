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

/// A person with a password who forgot it: the link signs them in, and for a
/// few minutes they choose a new password without the old one. A normal
/// session still needs the current one.
Future<void> linkRecovery(Arena a) async {
  final rosa = await personWithPassword(
    a,
    'recover',
    'old long phrase ${a.tag}',
  );
  final name = rosa.username!;
  final link = await a.boss.createSignInLink(rosa.id);

  final ls = await a.signInWithLinkSession(link.url);
  final me = await ls.me();
  expect(me.hasPassword, isTrue);
  expect(me.recentLinkSession, isTrue, reason: 'just signed in by a link');

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

  // The link session needs no current password.
  final fresh = 'new long phrase ${a.tag}';
  await ls.changePassword(newPassword: fresh);
  final after = await ls.me();
  expect(after.hasPassword, isTrue);
  expect(
    after.recentLinkSession,
    isFalse,
    reason: 'the new session is a password one',
  );
  // Everything older ended, and the old password is gone.
  await expectRefused(pw.repo.loadCatalog(), 'Please sign in again.');
  await expectRefused(
    a.signInWithPassword(name, 'old long phrase ${a.tag}'),
    _wrong,
  );
  expect(
    await (await a.signInWithPassword(name, fresh)).repo.loadCatalog(),
    isNotNull,
  );

  // The new session is a password session: the next change needs the current.
  await expectRefused(
    ls.changePassword(newPassword: 'third long phrase ${a.tag}'),
    _currentRequired,
  );
  await ls.changePassword(
    currentPassword: fresh,
    newPassword: 'third long phrase ${a.tag}',
  );
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

  // The signed-in change counts against the pair like a failed login, and is
  // not locked by failures from other addresses.
  final other = address('203.0.113');
  final mine = await a.signInWithPassword(name, good, address: other);
  for (var i = 0; i < 5; i++) {
    await expectRefused(
      mine.changePassword(
        currentPassword: 'not mine $i',
        newPassword: 'changed long phrase ${a.tag}',
      ),
      _currentWrong,
      why: 'wrong current $i',
    );
  }
  _expectLocked(
    await _refused(
      mine.changePassword(
        currentPassword: good,
        newPassword: 'changed long phrase ${a.tag}',
      ),
    ),
    why: 'the pair of the change is locked',
  );
  // The pair of the home address is a different one (and had failures of its
  // own): a session there is not locked by what happened at `other`.
  final calm = await personWithPassword(a, 'pairc', 'cat long phrase ${a.tag}');
  final calmAtHome = await a.signInWithPassword(
    calm.username!,
    'cat long phrase ${a.tag}',
    address: home,
  );
  await _wrongTries(a, calm.username!, attacker, 5);
  await calmAtHome.changePassword(
    currentPassword: 'cat long phrase ${a.tag}',
    newPassword: 'cat second phrase ${a.tag}',
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
