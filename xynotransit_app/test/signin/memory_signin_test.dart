import 'package:flutter_test/flutter_test.dart';
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
const gone = Person(
  id: 'gone',
  fullName: 'Gone Person',
  email: 'gone@example.com',
  appRole: AppRole.contributor,
  active: false,
);

void main() {
  late MemoryRepository repo;
  late AppUser user;
  late DateTime now;

  const asBoss = AppUser(
    personId: 'boss',
    role: AppRole.controller,
    label: 'Ana Boss',
  );

  setUp(() {
    user = asBoss;
    now = DateTime(2026, 6, 1, 9);
    repo = MemoryRepository(
      catalog: Catalog(
        teams: const [],
        persons: const [boss, gone],
        assignments: const [],
      ),
      currentUser: () => user,
      clock: () => now,
    );
  });

  Future<Person> add(String name, {String email = ''}) =>
      repo.savePerson(fullName: name, email: email, role: AppRole.contributor);

  group('savePerson without an email', () {
    test('makes an internal address from the name', () async {
      final p = await add('Rosa Rakoto');
      expect(p.email, 'rosa.rakoto@xynotransit.internal');
      final c = await repo.loadCatalog(includeInactive: true);
      expect(c.persons.map((x) => x.email), contains(p.email));
    });

    test('blank spaces count as empty', () async {
      expect(
        (await add('Rosa Rakoto', email: '  \t ')).email,
        contains('@xynotransit.internal'),
      );
    });

    test(
      'numbers conflicts, also with a typed address and inactive people',
      () async {
        await add('Rosa Rakoto', email: 'Rosa.Rakoto@xynotransit.internal');
        final b = await add('Rosa Rakoto');
        final c = await add('Rosa Rakoto');
        expect(b.email, 'rosa.rakoto2@xynotransit.internal');
        expect(c.email, 'rosa.rakoto3@xynotransit.internal');
        await repo.savePerson(
          id: c.id,
          fullName: c.fullName,
          email: c.email!,
          role: AppRole.contributor,
          active: false,
        );
        expect(
          (await add('Rosa Rakoto')).email,
          'rosa.rakoto4@xynotransit.internal',
        );
      },
    );

    test('keeps the typed internal address as typed (lower case)', () async {
      expect(
        (await add('X', email: ' Chat.User@XYNOTRANSIT.internal ')).email,
        'chat.user@xynotransit.internal',
      );
    });

    test('an empty email on an existing person keeps their address', () async {
      final p = await add('Rosa Rakoto');
      final q = await repo.savePerson(
        id: p.id,
        fullName: 'Rosa R. Rakoto',
        email: '',
        role: AppRole.controller,
      );
      expect(q.email, p.email);
      expect(q.appRole, AppRole.controller);
    });

    test('an invalid typed email is still refused', () async {
      await expectLater(
        add('Rosa', email: 'nope'),
        fails('Enter a valid email address.'),
      );
    });

    test('only a manager may add people', () async {
      user = const AppUser(
        personId: 'gone',
        role: AppRole.contributor,
        label: 'x',
      );
      // A switched off person is signed out; any non manager is refused.
      await expectLater(add('Rosa'), throwsA(isA<Exception>()));
    });
  });

  group('createSignInLink', () {
    test('makes a demo link that expires after the hours asked', () async {
      final p = await add('Rosa Rakoto');
      final l = await repo.createSignInLink(p.id, hours: 1);
      expect(l.personId, p.id);
      expect(
        l.url,
        matches(
          RegExp(
            r'^https://demo\.invalid/auth/verify\?token=demo-[a-z0-9]{12}$',
          ),
        ),
      );
      expect(l.expiresAt, now.add(const Duration(hours: 1)));
      final d = await repo.createSignInLink(p.id);
      expect(d.expiresAt, now.add(const Duration(hours: 24)));
      expect(d.url, isNot(l.url));
    });

    test('hours 1 to 168 only', () async {
      final p = await add('Rosa');
      for (final h in [0, -1, 169, 1000]) {
        await expectLater(
          repo.createSignInLink(p.id, hours: h),
          fails('Choose a validity from 1 hour to 168 hours.'),
          reason: '$h',
        );
      }
      await repo.createSignInLink(p.id, hours: 168);
      await repo.createSignInLink(p.id, hours: 1);
    });

    test('unknown person and switched off person', () async {
      await expectLater(
        repo.createSignInLink('nobody'),
        fails('That person does not exist.'),
      );
      await expectLater(
        repo.createSignInLink('gone'),
        fails('This person is switched off.'),
      );
    });

    test('managers only', () async {
      final p = await add('Rosa');
      user = AppUser(personId: p.id, role: AppRole.contributor, label: 'Rosa');
      await expectLater(
        repo.createSignInLink(p.id),
        fails('Only the manager can do this.'),
      );
    });

    test('30 links per manager per hour', () async {
      final p = await add('Rosa');
      for (var i = 0; i < 30; i++) {
        await repo.createSignInLink(p.id);
      }
      await expectLater(
        repo.createSignInLink(p.id),
        fails('Too many sign-in links created. Try again later.'),
      );
      now = now.add(const Duration(hours: 1, seconds: 1));
      await repo.createSignInLink(p.id);
    });

    test(
      'a link signs in once, and making another does not revoke it',
      () async {
        final p = await add('Rosa Rakoto');
        final a = await repo.createSignInLink(p.id);
        final b = await repo.createSignInLink(p.id);
        final u = repo.redeemSignInLink(a.url);
        expect(u.personId, p.id);
        expect(u.role, AppRole.contributor);
        expect(
          () => repo.redeemSignInLink(a.url),
          throwsA(isA<RepositoryException>()),
        );
        expect(repo.redeemSignInLink(b.url).personId, p.id);
      },
    );

    test('an expired link and a made up link do nothing', () async {
      final p = await add('Rosa');
      final a = await repo.createSignInLink(p.id, hours: 1);
      now = now.add(const Duration(hours: 1));
      expect(
        () => repo.redeemSignInLink(a.url),
        throwsA(isA<RepositoryException>()),
      );
      expect(
        () => repo.redeemSignInLink(
          'https://demo.invalid/auth/verify?token=demo-x',
        ),
        throwsA(isA<RepositoryException>()),
      );
      expect(
        () => repo.redeemSignInLink('nonsense'),
        throwsA(isA<RepositoryException>()),
      );
    });

    test('a link of a person switched off afterwards does nothing', () async {
      final p = await add('Rosa');
      final a = await repo.createSignInLink(p.id);
      await repo.savePerson(
        id: p.id,
        fullName: p.fullName,
        email: p.email!,
        role: AppRole.contributor,
        active: false,
      );
      expect(
        () => repo.redeemSignInLink(a.url),
        throwsA(isA<RepositoryException>()),
      );
    });
  });
}
