import 'package:flutter_test/flutter_test.dart';
import 'package:xynotransit_app/data/api/api_client.dart';
import 'package:xynotransit_app/data/memory_repository.dart';
import 'package:xynotransit_app/data/repository.dart';
import 'package:xynotransit_app/domain/catalog.dart';
import 'package:xynotransit_app/domain/enums.dart';

Matcher fails(String message) => throwsA(
  isA<RepositoryException>().having((e) => e.message, 'message', message),
);

const boss = Person(
  id: 'boss',
  fullName: 'Ana Boss',
  email: 'ana@example.com',
  appRole: AppRole.controller,
);
const rosa = Person(
  id: 'rosa',
  fullName: 'Rosa Rakoto',
  email: 'rosa.rakoto@example.com',
);
const gone = Person(
  id: 'gone',
  fullName: 'Gone Person',
  email: 'gone@example.com',
  active: false,
);

void main() {
  late MemoryRepository repo;
  late DemoAuth auth;
  late DateTime now;
  AppUser? actor;

  /// Runs [f] as the manager, whoever is signed in.
  Future<T> asBoss<T>(Future<T> Function() f) async {
    final before = actor;
    actor = repo.sessionFor('boss');
    try {
      return await f();
    } finally {
      actor = before;
    }
  }

  setUp(() {
    now = DateTime(2026, 6, 1, 9);
    final catalog = Catalog(
      teams: const [],
      persons: const [boss, rosa, gone],
      assignments: const [],
    );
    auth = DemoAuth(catalog, requireSignIn: true);
    late final MemoryRepository r;
    r = MemoryRepository(
      catalog: catalog,
      currentUser: () => actor ?? auth.currentUser ?? r.sessionFor('boss'),
      clock: () => now,
    );
    repo = r;
    actor = null;
  });

  /// A manager and the person: a reset, then the person's own password.
  Future<void> give(String id, String password) async {
    final t = await asBoss(() => repo.resetPassword(id));
    repo.changePasswordOf(
      repo.sessionFor(id),
      currentPassword: t.password,
      newPassword: password,
    );
  }

  group('usernames', () {
    test('existing people get the start of their email', () async {
      final c = await repo.loadCatalog(includeInactive: true);
      expect(c.persons.map((p) => p.username), ['ana', 'rosa.rakoto', 'gone']);
      expect(c.persons.every((p) => !p.hasPassword), isTrue);
    });

    test('a new person gets one, numbered on conflict', () async {
      Future<Person> add(String email) => repo.savePerson(
        fullName: 'X',
        email: email,
        role: AppRole.contributor,
      );
      expect((await add('rosa.rakoto@other.org')).username, 'rosa.rakoto2');
      expect((await add('rosa.rakoto@third.org')).username, 'rosa.rakoto3');
      final p = await repo.savePerson(
        fullName: 'Typed',
        email: 'typed@example.com',
        role: AppRole.contributor,
        username: ' Typed.Name ',
      );
      expect(p.username, 'typed.name');
    });

    test('the manager edits it: rules, conflicts, own name', () async {
      Future<Person> edit(String u) => repo.savePerson(
        id: 'rosa',
        fullName: rosa.fullName,
        email: rosa.email!,
        role: AppRole.contributor,
        username: u,
      );
      await expectLater(
        edit('no spaces'),
        fails(
          'Usernames use letters, digits, dots, dashes and underscores, '
          '3 to 40 characters.',
        ),
      );
      await expectLater(edit('ab'), fails(UsernameRulesText.invalid));
      await expectLater(edit('ANA'), fails('That username is already used.'));
      expect((await edit('Rosa_R')).username, 'rosa_r');
      // Saving the same name again is not a conflict with itself.
      expect((await edit('rosa_r')).username, 'rosa_r');
      // Empty keeps the name.
      expect((await edit('')).username, 'rosa_r');
    });

    test('only a manager edits usernames', () async {
      auth.actAs(repo.sessionFor('rosa'));
      await expectLater(
        repo.savePerson(
          id: 'rosa',
          fullName: 'Rosa',
          email: 'rosa.rakoto@example.com',
          role: AppRole.contributor,
          username: 'newname',
        ),
        fails('Only the manager can do this.'),
      );
    });
  });

  group('signing in with a password', () {
    test('a password the person chose lets them in', () async {
      await give('rosa', 'a purple bicycle');
      await auth.signInWithPassword(' Rosa.Rakoto ', 'a purple bicycle');
      final u = auth.currentUser!;
      expect(u.personId, 'rosa');
      expect(u.username, 'rosa.rakoto');
      expect(u.hasPassword, isTrue);
      expect(u.mustChangePassword, isFalse);
      expect(u.role, AppRole.contributor);
    });

    test('every refusal says the same words', () async {
      await give('rosa', 'a purple bicycle');
      final late = await repo.savePerson(
        fullName: 'Late Leaver',
        email: 'late@example.com',
        role: AppRole.contributor,
      );
      await give(late.id, 'another long phrase');
      await repo.savePerson(
        id: late.id,
        fullName: late.fullName,
        email: late.email!,
        role: AppRole.contributor,
        active: false,
      );
      const words = 'Username or password is wrong.';
      for (final (u, p) in [
        ('nobody', 'a purple bicycle'),
        ('rosa.rakoto', 'wrong'),
        ('rosa.rakoto', 'A purple bicycle'),
        ('late', 'another long phrase'),
        ('ana', 'anything at all'), // a person without a password
      ]) {
        await expectLater(
          auth.signInWithPassword(u, p),
          throwsA(
            isA<UnauthorizedException>().having(
              (e) => e.message,
              'message',
              words,
            ),
          ),
          reason: u,
        );
      }
      expect(auth.currentUser, isNull);
    });

    test(
      '5 failures lock the name for 15 minutes, with when to retry',
      () async {
        await give('rosa', 'a purple bicycle');
        for (var i = 0; i < 5; i++) {
          await expectLater(
            auth.signInWithPassword('rosa.rakoto', 'nope $i'),
            throwsA(isA<UnauthorizedException>()),
          );
        }
        // Even the right password waits now.
        Object? err;
        try {
          await auth.signInWithPassword('rosa.rakoto', 'a purple bicycle');
        } catch (e) {
          err = e;
        }
        expect(err, isA<ApiException>());
        final e = err! as ApiException;
        expect(e.statusCode, 429);
        expect(e.retryAfterSeconds, 900);
        expect(
          e.message,
          'Too many sign-in attempts. Try again in 15 minutes.',
        );
        now = now.add(const Duration(minutes: 10));
        await expectLater(
          auth.signInWithPassword('rosa.rakoto', 'a purple bicycle'),
          throwsA(
            isA<ApiException>().having((e) => e.retryAfterSeconds, 'wait', 300),
          ),
        );
        now = now.add(const Duration(minutes: 5, seconds: 1));
        await auth.signInWithPassword('rosa.rakoto', 'a purple bicycle');
        expect(auth.currentUser!.personId, 'rosa');
      },
    );

    test('an unknown name locks the same way, other names are free', () async {
      await give('rosa', 'a purple bicycle');
      for (var i = 0; i < 5; i++) {
        await expectLater(
          auth.signInWithPassword('Ghost', 'nope $i'),
          throwsA(isA<UnauthorizedException>()),
        );
      }
      await expectLater(
        auth.signInWithPassword('ghost', 'nope'),
        throwsA(isA<ApiException>().having((e) => e.statusCode, 'status', 429)),
      );
      await auth.signInWithPassword('rosa.rakoto', 'a purple bicycle');
      expect(auth.currentUser!.personId, 'rosa');
    });

    test('a success starts that name again from zero', () async {
      await give('rosa', 'a purple bicycle');
      for (var round = 0; round < 3; round++) {
        for (var i = 0; i < 4; i++) {
          await expectLater(
            auth.signInWithPassword('rosa.rakoto', 'nope $i'),
            throwsA(isA<UnauthorizedException>()),
          );
        }
        await auth.signInWithPassword('rosa.rakoto', 'a purple bicycle');
      }
    });

    test('a success does not clear the counter of others', () async {
      await give('rosa', 'a purple bicycle');
      await give('boss', 'a green kitchen');
      for (var i = 0; i < 4; i++) {
        await expectLater(
          auth.signInWithPassword('rosa.rakoto', 'nope $i'),
          throwsA(isA<UnauthorizedException>()),
        );
      }
      await auth.signInWithPassword('ana', 'a green kitchen');
      await expectLater(
        auth.signInWithPassword('rosa.rakoto', 'nope again'),
        throwsA(isA<UnauthorizedException>()),
      );
      await expectLater(
        auth.signInWithPassword('rosa.rakoto', 'a purple bicycle'),
        throwsA(isA<ApiException>().having((e) => e.statusCode, 's', 429)),
      );
    });
  });

  group('a temporary password', () {
    test('the manager sees it once; it has 16 clear characters', () async {
      final t = await repo.resetPassword('rosa');
      expect(t.username, 'rosa.rakoto');
      expect(t.password, hasLength(16));
      expect(t.password, matches(RegExp(r'^[A-HJ-NP-Za-km-z2-9]{16}$')));
      expect(
        (await repo.loadCatalog(includeInactive: true)).persons
            .firstWhere((p) => p.id == 'rosa')
            .hasPassword,
        isTrue,
      );
      final t2 = await repo.resetPassword('rosa');
      expect(t2.password, isNot(t.password));
      await expectLater(
        auth.signInWithPassword('rosa.rakoto', t.password),
        throwsA(isA<UnauthorizedException>()),
      );
      await auth.signInWithPassword('rosa.rakoto', t2.password);
      expect(auth.currentUser!.mustChangePassword, isTrue);
    });

    test('nothing works until the person has chosen their own', () async {
      final t = await repo.resetPassword('rosa');
      await auth.signInWithPassword('rosa.rakoto', t.password);
      await expectLater(
        repo.loadCatalog(),
        throwsA(
          isA<ApiException>()
              .having((e) => e.statusCode, 'status', 403)
              .having(
                (e) => e.message,
                'message',
                'Choose a new password first.',
              ),
        ),
      );
      await expectLater(
        repo.ensurePeriod(DateTime(2026, 2)),
        throwsA(isA<ApiException>()),
      );
      await auth.changePassword(
        currentPassword: t.password,
        newPassword: 'my own long phrase',
      );
      expect(auth.currentUser!.mustChangePassword, isFalse);
      expect((await repo.loadCatalog()).persons, isNotEmpty);
    });

    test('a switched off or unknown person gets none', () async {
      await expectLater(
        repo.resetPassword('gone'),
        fails('This person is switched off.'),
      );
      await expectLater(
        repo.resetPassword('nobody'),
        fails('That person does not exist.'),
      );
    });

    test('only a manager makes one', () async {
      auth.actAs(repo.sessionFor('rosa'));
      await expectLater(
        repo.resetPassword('boss'),
        fails('Only the manager can do this.'),
      );
      await expectLater(
        repo.removePassword('boss'),
        fails('Only the manager can do this.'),
      );
    });

    test('30 an hour, then 429 with when to retry', () async {
      for (var i = 0; i < 30; i++) {
        await repo.resetPassword('rosa');
      }
      Object? err;
      try {
        await repo.resetPassword('rosa');
      } catch (e) {
        err = e;
      }
      expect(err, isA<ApiException>());
      expect((err! as ApiException).statusCode, 429);
      expect((err as ApiException).retryAfterSeconds, 3600);
      now = now.add(const Duration(hours: 1));
      await repo.resetPassword('rosa');
    });

    test('the audit never holds a password', () async {
      final t = await repo.resetPassword('rosa');
      await repo.removePassword('rosa');
      expect(repo.passwordAudit.map((a) => a.kind), ['reset', 'remove']);
      expect(repo.passwordAudit.every((a) => a.issuedBy == 'boss'), isTrue);
      expect('${repo.passwordAudit}', isNot(contains(t.password)));
    });
  });

  group('changing a password', () {
    test(
      'needs the current one, and a wrong one counts as a failure',
      () async {
        await give('rosa', 'a purple bicycle');
        await auth.signInWithPassword('rosa.rakoto', 'a purple bicycle');
        for (var i = 0; i < 4; i++) {
          await expectLater(
            auth.changePassword(
              currentPassword: 'wrong one $i',
              newPassword: 'a brand new phrase',
            ),
            throwsA(
              isA<ApiException>()
                  .having((e) => e.statusCode, 'status', 403)
                  .having(
                    (e) => e.message,
                    'message',
                    'Your current password is not right.',
                  ),
            ),
          );
        }
        // The fifth failure comes from a sign-in attempt for the same name.
        await expectLater(
          auth.signInWithPassword('rosa.rakoto', 'wrong'),
          throwsA(isA<UnauthorizedException>()),
        );
        await expectLater(
          auth.changePassword(
            currentPassword: 'a purple bicycle',
            newPassword: 'a brand new phrase',
          ),
          throwsA(isA<ApiException>().having((e) => e.statusCode, 's', 429)),
        );
      },
    );

    test('applies the policy with the same words', () async {
      await give('rosa', 'a purple bicycle');
      await auth.signInWithPassword('rosa.rakoto', 'a purple bicycle');
      for (final (pw, msg) in [
        ('short', 'Use at least 10 characters.'),
        (
          'password123',
          'That password is too common. Pick something only you would think of.',
        ),
        (
          'rosa.rakoto@example.com',
          'Do not use your username, email address or name as a password.',
        ),
        ('Rosa', 'Use at least 10 characters.'),
        (
          '0123456789',
          'Do not use a simple run such as 1234567890 or abcdefghij.',
        ),
        (
          'a purple bicycle',
          'Choose a password different from the current one.',
        ),
      ]) {
        await expectLater(
          auth.changePassword(
            currentPassword: 'a purple bicycle',
            newPassword: pw,
          ),
          fails(msg),
          reason: pw,
        );
      }
    });

    test('the first password after a link needs no current one', () async {
      final link = await repo.createSignInLink('rosa');
      await auth.exchangeToken(Uri.parse(link.url).queryParameters['token']!);
      expect(auth.currentUser!.hasPassword, isFalse);
      await auth.changePassword(newPassword: 'chosen after the link');
      expect(auth.currentUser!.hasPassword, isTrue);
      await auth.signOut();
      await auth.signInWithPassword('rosa.rakoto', 'chosen after the link');
      expect(auth.currentUser!.personId, 'rosa');
    });

    test('swaps in a fresh session and ends every older one', () async {
      await give('rosa', 'a purple bicycle');
      await auth.signInWithPassword('rosa.rakoto', 'a purple bicycle');
      final old = auth.currentUser!;
      await auth.changePassword(
        currentPassword: 'a purple bicycle',
        newPassword: 'a green kitchen sink',
      );
      expect(auth.currentUser!.sessionEpoch, greaterThan(old.sessionEpoch));
      expect((await repo.loadCatalog()).persons, isNotEmpty);
      // The old session, held by another device, is refused.
      actor = old;
      await expectLater(
        repo.loadCatalog(),
        throwsA(isA<UnauthorizedException>()),
      );
      actor = null;
      // The old password is gone.
      await expectLater(
        auth.signInWithPassword('rosa.rakoto', 'a purple bicycle'),
        throwsA(isA<UnauthorizedException>()),
      );
    });

    test('a reset and a removal end sessions too', () async {
      await give('rosa', 'a purple bicycle');
      await auth.signInWithPassword('rosa.rakoto', 'a purple bicycle');
      final old = auth.currentUser!;
      await asBoss(() => repo.removePassword('rosa'));
      actor = old;
      await expectLater(
        repo.loadCatalog(),
        throwsA(isA<UnauthorizedException>()),
      );
      actor = null;
      await expectLater(
        auth.signInWithPassword('rosa.rakoto', 'a purple bicycle'),
        throwsA(isA<UnauthorizedException>()),
      );
      final c = await asBoss(() => repo.loadCatalog(includeInactive: true));
      expect(c.persons.firstWhere((p) => p.id == 'rosa').hasPassword, isFalse);
    });

    test('a switched off person is signed out whatever the password', () async {
      await give('rosa', 'a purple bicycle');
      await auth.signInWithPassword('rosa.rakoto', 'a purple bicycle');
      await asBoss(
        () => repo.savePerson(
          id: 'rosa',
          fullName: rosa.fullName,
          email: rosa.email!,
          role: AppRole.contributor,
          active: false,
        ),
      );
      await expectLater(
        repo.loadCatalog(),
        throwsA(isA<UnauthorizedException>()),
      );
    });
  });

  group('removing a password', () {
    test('the person is link-only again', () async {
      await give('rosa', 'a purple bicycle');
      await asBoss(() => repo.removePassword('rosa'));
      await expectLater(
        auth.signInWithPassword('rosa.rakoto', 'a purple bicycle'),
        throwsA(isA<UnauthorizedException>()),
      );
      final link = await repo.createSignInLink('rosa');
      await auth.exchangeToken(Uri.parse(link.url).queryParameters['token']!);
      expect(auth.currentUser!.hasPassword, isFalse);
    });
  });

  group('the demo (no sign-in)', () {
    test('the manager can choose a password from the account menu', () async {
      final catalog = Catalog(
        teams: const [],
        persons: const [rosa],
        assignments: const [],
      );
      final demo = DemoAuth(catalog);
      late final MemoryRepository r;
      r = MemoryRepository(
        catalog: catalog,
        currentUser: () => demo.currentUser ?? r.sessionFor(null),
      );
      expect(demo.needsSignIn, isFalse);
      expect(demo.currentUser!.hasPassword, isFalse);
      await demo.changePassword(newPassword: 'the demo manager phrase');
      expect(demo.currentUser!.hasPassword, isTrue);
      expect(demo.currentUser!.username, 'manager');
      // Still works afterwards.
      expect(
        (await r.loadCatalog(includeInactive: true)).persons,
        hasLength(1),
      );
      // Acting as someone else and back keeps working (fresh sessions).
      demo.actAs(demo.choices.last);
      demo.actAs(demo.choices.first);
      expect((await r.loadCatalog()).persons, hasLength(1));
      await demo.signOut();
      expect(demo.currentUser!.personId, isNull);
    });
  });
}

/// The words, spelled once for the tests that compare them.
abstract final class UsernameRulesText {
  static const invalid =
      'Usernames use letters, digits, dots, dashes and underscores, '
      '3 to 40 characters.';
}
