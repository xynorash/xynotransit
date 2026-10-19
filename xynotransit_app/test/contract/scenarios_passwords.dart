// Usernames and passwords: the same answers from the in-memory demo and from
// the real API. Sign-in links stay the way to start and to recover.
import 'package:flutter_test/flutter_test.dart';
import 'package:xynotransit_app/data/api/api_client.dart';
import 'package:xynotransit_app/domain/catalog.dart';
import 'package:xynotransit_app/domain/enums.dart';
import 'package:xynotransit_app/domain/text_rules.dart';

import 'arena.dart';
import 'scenarios_admin.dart' show onlyController;

const _wrong = 'Username or password is wrong.';
const _mustChange = 'Choose a new password first.';
const _signInAgain = 'Please sign in again.';
const _invalidName =
    'Usernames use letters, digits, dots, dashes and underscores, '
    '3 to 40 characters.';

/// Makes a person that has a password of its own, the way it happens for
/// real: the manager resets, the person signs in and chooses.
Future<Person> personWithPassword(Arena a, String who, String password) async {
  final p = await a.makePerson(who);
  final t = await a.boss.resetPassword(p.id);
  final s = await a.signInWithPassword(t.username, t.password);
  await s.changePassword(currentPassword: t.password, newPassword: password);
  return (await a.boss.loadCatalog(includeInactive: true)).persons
      .firstWhere((x) => x.id == p.id);
}

Future<Person> _fresh(Arena a, Person p) async =>
    (await a.boss.loadCatalog(includeInactive: true)).persons
        .firstWhere((x) => x.id == p.id);

/// The whole life of a password.
Future<void> passwordLifecycle(Arena a) async {
  final boss = a.boss;

  // A new person gets a username from the start of the email, numbered on
  // conflict; they have no password yet.
  final name = 'CT${a.tag} Rosa Rakoto';
  final local = internalLocalOf(name);
  final rosa = await boss.savePerson(
    fullName: name,
    email: '',
    role: AppRole.contributor,
  );
  expect(rosa.username, local);
  expect(rosa.hasPassword, isFalse);
  final twin = await boss.savePerson(
    fullName: name,
    email: '',
    role: AppRole.contributor,
  );
  expect(twin.username, '${local}2');
  final typed = await boss.savePerson(
    fullName: 'CT${a.tag} Typed',
    email: a.email('typed'),
    role: AppRole.contributor,
    username: 'CT${a.tag}_Typed',
  );
  expect(typed.username, 'ct${a.tag.toLowerCase()}_typed');
  final byEmail = await a.makePerson('mailer');
  expect(byEmail.username, 'ct${a.tag.toLowerCase()}-mailer');

  // The manager edits a username: rules, uniqueness (ignoring case), own name.
  Future<Person> rename(Person p, String u) => boss.savePerson(
    id: p.id,
    fullName: p.fullName,
    email: p.email!,
    role: AppRole.contributor,
    username: u,
  );
  await expectRefused(rename(rosa, 'no spaces'), _invalidName);
  await expectRefused(rename(rosa, 'ab'), _invalidName);
  await expectRefused(rename(rosa, 'x' * 41), _invalidName);
  await expectRefused(
    rename(rosa, typed.username!.toUpperCase()),
    'That username is already used.',
  );
  final renamed = await rename(rosa, 'CT${a.tag}.Rosa');
  final rosaName = 'ct${a.tag.toLowerCase()}.rosa';
  expect(renamed.username, rosaName);
  expect((await rename(renamed, rosaName)).username, rosaName);

  // Nothing signs in without a password; unknown names answer the same.
  await expectRefused(
    a.signInWithPassword(rosaName, 'whatever long enough'),
    _wrong,
    why: 'a person without a password',
  );
  await expectRefused(
    a.signInWithPassword('ct${a.tag}.nobody', 'whatever long enough'),
    _wrong,
    why: 'an unknown name',
  );

  // The manager makes a temporary password. It is shown once, 16 clear
  // characters; another one replaces it.
  final t1 = await boss.resetPassword(rosa.id);
  expect(t1.username, rosaName);
  expect(t1.password, matches(RegExp(r'^[A-HJ-NP-Za-km-z2-9]{16}$')));
  expect((await _fresh(a, rosa)).hasPassword, isTrue);
  final t2 = await boss.resetPassword(rosa.id);
  expect(t2.password, isNot(t1.password));
  await expectRefused(
    a.signInWithPassword(rosaName, t1.password),
    _wrong,
    why: 'the replaced temporary password',
  );

  // The temporary password signs in, but nothing works until a new one is chosen.
  final s = await a.signInWithPassword(
    ' ${rosaName.toUpperCase()} ',
    t2.password,
  );
  final me = await s.me();
  expect(me.username, rosaName);
  expect(me.hasPassword, isTrue);
  expect(me.mustChangePassword, isTrue);
  expect(me.role, AppRole.contributor);
  await expectRefused(s.repo.loadCatalog(), _mustChange);
  await expectRefused(
    s.repo.ensurePeriod(a.start(0)),
    _mustChange,
    why: 'a report route',
  );

  // Changing it: the current one is checked, the policy applies in plain words.
  await expectRefused(
    s.changePassword(
      currentPassword: 'not the temporary one',
      newPassword: 'purple bicycle ${a.tag}',
    ),
    'Your current password is not right.',
  );
  await expectRefused(
    s.changePassword(newPassword: 'purple bicycle ${a.tag}'),
    'Enter your current password.',
    why: 'the current password is needed',
  );
  for (final (pw, words) in [
    ('', 'Enter a new password.'),
    ('short', 'Use at least 10 characters.'),
    ('x' * 129, 'Use at most 128 characters.'),
    (
      'password123',
      'That password is too common. Pick something only you would think of.',
    ),
    ('1234567890', 'Do not use a simple run such as 1234567890 or abcdefghij.'),
    ('zzzzzzzzzzzz', 'Do not repeat one character.'),
    (
      rosaName,
      'Do not use your username, email address or name as a password.',
    ),
    (t2.password, 'Choose a password different from the current one.'),
  ]) {
    await expectRefused(
      s.changePassword(currentPassword: t2.password, newPassword: pw),
      words,
      why: 'new password "$pw"',
    );
  }

  // It works: the fresh session is in place, the page opens, spaces are kept.
  final mine = '  purple bicycle ${a.tag}  ';
  await s.changePassword(currentPassword: t2.password, newPassword: mine);
  expect((await s.me()).mustChangePassword, isFalse);
  expect(await s.repo.loadCatalog(), isNotNull);
  await expectRefused(
    a.signInWithPassword(rosaName, t2.password),
    _wrong,
    why: 'the temporary password is gone',
  );
  await expectRefused(
    a.signInWithPassword(rosaName, mine.trim()),
    _wrong,
    why: 'spaces are part of the password',
  );

  // A second device signs in. Changing the password ends its session, not ours.
  final other = await a.signInWithPassword(rosaName, mine);
  expect(await other.repo.loadCatalog(), isNotNull);
  final next = 'green kitchen sink ${a.tag}';
  await s.changePassword(currentPassword: mine, newPassword: next);
  await expectRefused(other.repo.loadCatalog(), _signInAgain);
  expect(await s.repo.loadCatalog(), isNotNull);

  // Employees cannot make or remove passwords, nor edit usernames.
  await expectRefused(
    s.repo.resetPassword(twin.id),
    onlyController,
    why: 'an employee resets a password',
  );
  await expectRefused(
    s.repo.removePassword(twin.id),
    onlyController,
    why: 'an employee removes a password',
  );
  final p = (await s.repo.loadCatalog()).persons.first;
  await expectRefused(
    s.repo.savePerson(
      id: p.id,
      fullName: p.fullName,
      email: p.email ?? 'x@example.com',
      role: AppRole.contributor,
      username: 'sneaky.name',
    ),
    onlyController,
    why: 'an employee edits a username',
  );

  // Refusals of the manager's own calls.
  await expectRefused(
    boss.resetPassword(a.unknownId),
    'That person does not exist.',
  );
  await boss.savePerson(
    id: twin.id,
    fullName: twin.fullName,
    email: twin.email!,
    role: AppRole.contributor,
    active: false,
  );
  await expectRefused(
    boss.resetPassword(twin.id),
    'This person is switched off.',
  );

  // Removing the password: link-only again, sessions end.
  await boss.removePassword(rosa.id);
  expect((await _fresh(a, rosa)).hasPassword, isFalse);
  await expectRefused(a.signInWithPassword(rosaName, next), _wrong);
  await expectRefused(s.repo.loadCatalog(), _signInAgain);

  // The link brings them back; the first password needs no current one.
  final link = await boss.createSignInLink(rosa.id);
  final ls = await a.signInWithLinkSession(link.url);
  final back = await ls.me();
  expect(back.hasPassword, isFalse);
  expect(back.mustChangePassword, isFalse);
  expect(back.username, rosaName);
  expect(await ls.repo.loadCatalog(), isNotNull);
  await ls.changePassword(newPassword: 'chosen after the link ${a.tag}');
  expect((await ls.me()).hasPassword, isTrue);
  final again = await a.signInWithPassword(
    rosaName,
    'chosen after the link ${a.tag}',
  );
  expect(await again.repo.loadCatalog(), isNotNull);
  expect((await _fresh(a, rosa)).hasPassword, isTrue);

  // A switched off person is out, password or not.
  await boss.savePerson(
    id: rosa.id,
    fullName: rosa.fullName,
    email: rosa.email!,
    role: AppRole.contributor,
    active: false,
  );
  await expectRefused(
    a.signInWithPassword(rosaName, 'chosen after the link ${a.tag}'),
    _wrong,
  );
  await expectRefused(again.repo.loadCatalog(), 'Please sign in.');
}

/// Five wrong tries lock a name for a while, an unknown name too, and one
/// person's success does not clear another's count.
Future<void> loginLimit(Arena a) async {
  final ana = await personWithPassword(
    a,
    'ana',
    'ana is a long phrase ${a.tag}',
  );
  final ben = await personWithPassword(
    a,
    'ben',
    'ben is a long phrase ${a.tag}',
  );
  final anaName = ana.username!;
  final benName = ben.username!;

  Future<ApiException> locked(String user, String pw) async {
    try {
      await a.signInWithPassword(user, pw);
    } on ApiException catch (e) {
      return e;
    }
    fail('expected a lock for $user');
  }

  void expectLockWords(ApiException e) {
    expect(e.statusCode, 429);
    expect(e.retryAfterSeconds, isNotNull, reason: '429 carries Retry-After');
    expect(e.retryAfterSeconds, inInclusiveRange(1, 900));
    expect(
      e.message,
      matches(
        RegExp(
          r'^Too many sign-in attempts\. Try again in \d+ (second|minute)s?\.$',
        ),
      ),
      reason: e.message,
    );
  }

  for (var i = 0; i < 4; i++) {
    await expectRefused(a.signInWithPassword(anaName, 'wrong try $i'), _wrong);
  }
  // Ben signs in fine; that does not clear Ana's count.
  expect(
    await (await a.signInWithPassword(
      benName,
      'ben is a long phrase ${a.tag}',
    )).repo.loadCatalog(),
    isNotNull,
  );
  await expectRefused(a.signInWithPassword(anaName, 'wrong try 5'), _wrong);
  // The sixth is refused before the password is looked at, right or wrong.
  expectLockWords(await locked(anaName, 'ana is a long phrase ${a.tag}'));

  // Ben is free; an unknown name locks the same way after the same tries.
  expect(
    await a.signInWithPassword(benName, 'ben is a long phrase ${a.tag}'),
    isNotNull,
  );
  final ghost = 'ct${a.tag.toLowerCase()}.ghost';
  for (var i = 0; i < 5; i++) {
    await expectRefused(a.signInWithPassword(ghost, 'wrong try $i'), _wrong);
  }
  expectLockWords(await locked(ghost, 'wrong try again'));
}
