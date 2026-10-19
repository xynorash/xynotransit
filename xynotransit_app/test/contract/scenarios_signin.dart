// Signing in without a real email: an internal address, a one-time link made
// by a manager, and the link signing the person in once.
import 'package:flutter_test/flutter_test.dart';
import 'package:xynotransit_app/domain/enums.dart';
import 'package:xynotransit_app/domain/text_rules.dart';

import 'arena.dart';
import 'scenarios_admin.dart' show onlyController;

const _domain = 'xynotransit.internal';

Future<void> internalSignIn(Arena a) async {
  final boss = a.boss;

  // A person without an email gets an internal address made from the name.
  final name = 'CT${a.tag} Rosa Rakoto';
  final rosa = await boss.savePerson(
    fullName: name,
    email: '',
    role: AppRole.contributor,
  );
  final local = internalLocalOf(name);
  expect(rosa.email, '$local@$_domain');
  expect(rosa.email, startsWith('ct${a.tag.toLowerCase()}.rosa.rakoto@'));
  expect(rosa.active, isTrue);

  // The same name again: a number goes on the end.
  final twin = await boss.savePerson(
    fullName: name,
    email: '   ',
    role: AppRole.contributor,
  );
  expect(twin.email, '${local}2@$_domain');
  expect(twin.id, isNot(rosa.id));
  final third = await boss.savePerson(
    fullName: name,
    email: '',
    role: AppRole.contributor,
  );
  expect(third.email, '${local}3@$_domain');

  // An address at the internal domain that is typed is kept as typed.
  final typed = 'ct${a.tag}-typed@$_domain';
  final tp = await boss.savePerson(
    fullName: 'CT${a.tag} Typed',
    email: typed.toUpperCase(),
    role: AppRole.contributor,
  );
  expect(tp.email, typed);
  await expectRefused(
    boss.savePerson(
      fullName: 'CT${a.tag} Typed Again',
      email: typed,
      role: AppRole.contributor,
    ),
    'That email is already used.',
  );

  // Saving a person again with an empty email keeps their address.
  final kept = await boss.savePerson(
    id: rosa.id,
    fullName: rosa.fullName,
    email: '',
    role: AppRole.contributor,
  );
  expect(kept.email, rosa.email);

  // The address never receives mail, so asking for an email link gets nowhere.
  await expectLater(
    a.signInAs(rosa.email!, fresh: true),
    throwsA(isA<SignInRefused>()),
  );

  // The manager creates a link.
  final before = DateTime.now();
  final link = await boss.createSignInLink(rosa.id, hours: 1);
  expect(link.personId, rosa.id);
  expect(link.url, contains('/auth/verify?token='));
  final life = link.expiresAt.difference(before);
  expect(life, greaterThan(const Duration(minutes: 58)));
  expect(life, lessThan(const Duration(minutes: 62)));

  // A second link does not turn the first one off.
  final other = await boss.createSignInLink(rosa.id);
  expect(other.url, isNot(link.url));
  expect(
    other.expiresAt.difference(before),
    greaterThan(const Duration(hours: 23)),
    reason: 'the default is 24 hours',
  );

  // The first link signs her in, once.
  final rosaRepo = await a.signInWithLink(link.url);
  final catalog = await rosaRepo.loadCatalog();
  expect(catalog.persons.map((p) => p.id), contains(rosa.id));
  expect(
    await refusal(a.signInWithLink(link.url), why: 'the link used twice'),
    isNotEmpty,
  );

  // She is an employee like any other: no manager actions.
  await expectRefused(
    rosaRepo.createSignInLink(twin.id),
    onlyController,
    why: 'an employee makes a link',
  );
  await expectRefused(
    rosaRepo.saveTeam(name: 'CT${a.tag} Nope'),
    onlyController,
  );

  // The second link still works.
  final again = await a.signInWithLink(other.url);
  expect(await again.loadCatalog(), isNotNull);

  // Words of the refusals.
  await expectRefused(
    boss.createSignInLink(a.unknownId),
    'That person does not exist.',
    why: 'unknown person',
  );
  await expectRefused(
    boss.createSignInLink(rosa.id, hours: 0),
    'Choose a validity from 1 hour to 168 hours.',
  );
  await expectRefused(
    boss.createSignInLink(rosa.id, hours: 169),
    'Choose a validity from 1 hour to 168 hours.',
  );
  final longest = await boss.createSignInLink(rosa.id, hours: 168);
  expect(
    longest.expiresAt.difference(before),
    greaterThan(const Duration(hours: 167)),
  );

  // A switched off person gets no link, and an old link stops working.
  final old = await boss.createSignInLink(twin.id);
  await boss.savePerson(
    id: twin.id,
    fullName: twin.fullName,
    email: twin.email!,
    role: AppRole.contributor,
    active: false,
  );
  await expectRefused(
    boss.createSignInLink(twin.id),
    'This person is switched off.',
  );
  expect(
    await refusal(a.signInWithLink(old.url), why: 'link of a switched off one'),
    isNotEmpty,
  );
}

/// Too many sign-in requests: the app is told when to try again.
Future<void> signInLimit(Arena a) async {
  final limit = await a.provokeSignInLimit('ct${a.tag}-limit@contract.example');
  if (limit == null) return; // this backend has no limit (the demo)
  expect(limit.retryAfter, isNotNull, reason: 'a 429 carries Retry-After');
  expect(limit.retryAfter, inInclusiveRange(1, 3600));
  expect(
    limit.message,
    matches(
      RegExp(r'^Too many .*\. Try again in \d+ (second|minute|hour)s?\.$'),
    ),
    reason: limit.message,
  );
  expect(limit.message, isNot(contains('later')));
}
