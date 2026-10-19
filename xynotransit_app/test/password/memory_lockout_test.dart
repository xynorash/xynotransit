// The in-memory demo holds the same lockout design and link recovery rule as
// the API: per pair limits, the username backstop, trusted addresses, the
// address cap, and a new password after a link without the old one.
import 'package:flutter_test/flutter_test.dart';
import 'package:xynotransit_app/data/api/api_client.dart';
import 'package:xynotransit_app/data/memory_repository.dart';
import 'package:xynotransit_app/data/repository.dart';
import 'package:xynotransit_app/domain/catalog.dart';
import 'package:xynotransit_app/domain/enums.dart';

const _boss = Person(
  id: 'boss',
  fullName: 'Ana Boss',
  email: 'ana@example.com',
  appRole: AppRole.controller,
);
const _rosa = Person(
  id: 'rosa',
  fullName: 'Rosa Rakoto',
  email: 'rosa.rakoto@example.com',
);
const _ben = Person(id: 'ben', fullName: 'Ben Bako', email: 'ben@example.com');

const _good = 'a purple bicycle';
const _wrong = 'Username or password is wrong.';

void main() {
  late MemoryRepository repo;
  late DateTime now;
  AppUser? actor;

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
      persons: const [_boss, _rosa, _ben],
      assignments: const [],
    );
    DemoAuth(catalog, requireSignIn: true);
    late final MemoryRepository r;
    r = MemoryRepository(
      catalog: catalog,
      currentUser: () => actor ?? r.sessionFor('boss'),
      clock: () => now,
    );
    repo = r;
  });

  Future<void> give(String id, String password) async {
    final t = await asBoss(() => repo.resetPassword(id));
    repo.changePasswordOf(
      repo.sessionFor(id),
      currentPassword: t.password,
      newPassword: password,
    );
  }

  void wrongTries(String user, String? from, int n) {
    for (var i = 0; i < n; i++) {
      expect(
        () => repo.loginWithPassword(user, 'nope $i', address: from),
        throwsA(isA<UnauthorizedException>()),
      );
    }
  }

  Matcher locked([int? seconds]) => throwsA(
    isA<ApiException>()
        .having((e) => e.statusCode, 'status', 429)
        .having(
          (e) => e.retryAfterSeconds,
          'retry after',
          seconds ?? isNotNull,
        ),
  );

  group('per pair', () {
    test('five failures lock that pair only, even a right password', () async {
      await give('rosa', _good);
      wrongTries('rosa.rakoto', '198.51.100.1', 5);
      expect(
        () => repo.loginWithPassword(
          'rosa.rakoto',
          _good,
          address: '198.51.100.1',
        ),
        locked(900),
      );
      // The person at another address is free.
      expect(
        repo
            .loginWithPassword('rosa.rakoto', _good, address: '203.0.113.9')
            .personId,
        'rosa',
      );
    });

    test('Retry-After counts down and the lock ends', () async {
      await give('rosa', _good);
      wrongTries('rosa.rakoto', '198.51.100.1', 5);
      now = now.add(const Duration(minutes: 10));
      expect(
        () => repo.loginWithPassword(
          'rosa.rakoto',
          _good,
          address: '198.51.100.1',
        ),
        locked(300),
      );
      now = now.add(const Duration(minutes: 5));
      expect(
        repo
            .loginWithPassword('rosa.rakoto', _good, address: '198.51.100.1')
            .personId,
        'rosa',
      );
    });

    test('a success clears the pair, not the others', () async {
      await give('rosa', _good);
      wrongTries('rosa.rakoto', '198.51.100.1', 4);
      repo.loginWithPassword('rosa.rakoto', _good, address: '198.51.100.1');
      wrongTries('rosa.rakoto', '198.51.100.1', 4);
    });

    test('an unknown name answers the same words and locks the same', () {
      wrongTries('nobody.here', '198.51.100.1', 5);
      expect(
        () =>
            repo.loginWithPassword('nobody.here', 'x', address: '198.51.100.1'),
        locked(900),
      );
      expect(
        () =>
            repo.loginWithPassword('nobody.here', 'x', address: '198.51.100.2'),
        throwsA(
          isA<UnauthorizedException>().having(
            (e) => e.message,
            'message',
            _wrong,
          ),
        ),
      );
    });

    test('an unknown address shares one pair called unknown', () async {
      await give('rosa', _good);
      wrongTries('rosa.rakoto', null, 5);
      expect(() => repo.loginWithPassword('rosa.rakoto', _good), locked());
      // A known address is a different pair.
      expect(
        repo
            .loginWithPassword('rosa.rakoto', _good, address: '203.0.113.9')
            .personId,
        'rosa',
      );
    });
  });

  group('backstop and trusted addresses', () {
    test('100 failures lock strangers, not addresses that signed in', () async {
      await give('rosa', _good);
      await give('ben', _good);
      repo.loginWithPassword('rosa.rakoto', _good, address: '203.0.113.7');
      for (var i = 0; i < 100; i++) {
        expect(
          () => repo.loginWithPassword(
            'rosa.rakoto',
            'spray $i',
            address: '198.51.${100 + i ~/ 50}.${1 + i % 50}',
          ),
          throwsA(isA<UnauthorizedException>()),
        );
      }
      expect(
        () =>
            repo.loginWithPassword('rosa.rakoto', _good, address: '192.0.2.50'),
        locked(),
      );
      expect(
        repo
            .loginWithPassword('rosa.rakoto', _good, address: '203.0.113.7')
            .personId,
        'rosa',
      );
      // Someone else's username is not affected.
      expect(
        repo.loginWithPassword('ben', _good, address: '192.0.2.50').personId,
        'ben',
      );
    });

    test('a link sign-in makes an address trusted too', () async {
      await give('rosa', _good);
      final link = await asBoss(() => repo.createSignInLink('rosa'));
      repo.redeemSignInLink(link.url, address: '203.0.113.7');
      now = now.add(const Duration(days: 29));
      for (var i = 0; i < 100; i++) {
        expect(
          () => repo.loginWithPassword(
            'rosa.rakoto',
            'spray $i',
            address: '198.51.${100 + i ~/ 50}.${1 + i % 50}',
          ),
          throwsA(isA<UnauthorizedException>()),
        );
      }
      expect(
        repo
            .loginWithPassword('rosa.rakoto', _good, address: '203.0.113.7')
            .personId,
        'rosa',
      );
      // 31 days after the last sign-in the address is a stranger. The spray
      // is older than 15 minutes by then, so the backstop starts again.
      now = now.add(const Duration(days: 31));
      expect(
        repo
            .loginWithPassword('rosa.rakoto', _good, address: '203.0.113.7')
            .personId,
        'rosa',
      );
    });
  });

  group('per address', () {
    test(
      '30 failures lock a known address, an unknown one is exempt',
      () async {
        await give('rosa', _good);
        for (var i = 0; i < 30; i++) {
          expect(
            () => repo.loginWithPassword(
              'ghost${i ~/ 4}',
              'x',
              address: '192.0.2.9',
            ),
            throwsA(isA<UnauthorizedException>()),
          );
        }
        expect(
          () => repo.loginWithPassword(
            'rosa.rakoto',
            _good,
            address: '192.0.2.9',
          ),
          locked(),
        );
        // 30 failures without an address lock nobody by address.
        for (var i = 0; i < 40; i++) {
          expect(
            () => repo.loginWithPassword('ghost${i ~/ 4}', 'x'),
            throwsA(isA<UnauthorizedException>()),
          );
        }
        expect(repo.loginWithPassword('rosa.rakoto', _good).personId, 'rosa');
      },
    );
  });

  group('the signed-in change', () {
    test('wrong current counts for the pair, others cannot lock it', () async {
      await give('rosa', _good);
      final mine = repo.loginWithPassword(
        'rosa.rakoto',
        _good,
        address: '203.0.113.7',
      );
      wrongTries('rosa.rakoto', '198.51.100.1', 5);
      for (var i = 0; i < 4; i++) {
        expect(
          () => repo.changePasswordOf(
            mine,
            currentPassword: 'nope',
            newPassword: 'another long one',
            address: '203.0.113.7',
          ),
          throwsA(
            isA<ApiException>().having((e) => e.statusCode, 'status', 403),
          ),
        );
      }
      // The sixth try is locked: the five are wrong tries of this pair.
      expect(
        () => repo.changePasswordOf(
          mine,
          currentPassword: 'nope',
          newPassword: 'another long one',
          address: '203.0.113.7',
        ),
        throwsA(isA<ApiException>()),
      );
      expect(
        () => repo.changePasswordOf(
          mine,
          currentPassword: _good,
          newPassword: 'another long one',
          address: '203.0.113.7',
        ),
        locked(),
      );
    });
  });

  group('recovery by link', () {
    Future<AppUser> linkSession() async {
      final link = await asBoss(() => repo.createSignInLink('rosa'));
      return repo.redeemSignInLink(link.url);
    }

    test('no current password for a person with one, within 15 min', () async {
      await give('rosa', _good);
      final s = await linkSession();
      expect(repo.refreshed(s).recentLinkSession, isTrue);
      final fresh = repo.changePasswordOf(
        s,
        newPassword: 'a green kitchen sink',
      );
      expect(repo.refreshed(fresh).recentLinkSession, isFalse);
      expect(repo.passwordAudit.last.kind, 'change-via-link');
      expect(
        () => repo.loginWithPassword('rosa.rakoto', _good),
        throwsA(isA<UnauthorizedException>()),
      );
      expect(
        repo.loginWithPassword('rosa.rakoto', 'a green kitchen sink').personId,
        'rosa',
      );
    });

    test('exactly 15 minutes passes, one second more asks for it', () async {
      await give('rosa', _good);
      final s = await linkSession();
      now = now.add(const Duration(minutes: 15));
      expect(repo.refreshed(s).recentLinkSession, isTrue);
      now = now.add(const Duration(seconds: 1));
      expect(repo.refreshed(s).recentLinkSession, isFalse);
      expect(
        () => repo.changePasswordOf(s, newPassword: 'a green kitchen sink'),
        throwsA(
          isA<RepositoryException>().having(
            (e) => e.message,
            'message',
            'Enter your current password.',
          ),
        ),
      );
    });

    test('a password session always needs the current password', () async {
      await give('rosa', _good);
      final s = repo.loginWithPassword('rosa.rakoto', _good);
      expect(repo.refreshed(s).recentLinkSession, isFalse);
      expect(
        () => repo.changePasswordOf(s, newPassword: 'a green kitchen sink'),
        throwsA(isA<RepositoryException>()),
      );
    });

    test('a new session made by a change is a password session', () async {
      await give('rosa', _good);
      final s = await linkSession();
      final fresh = repo.changePasswordOf(
        s,
        newPassword: 'a green kitchen sink',
      );
      expect(
        () => repo.changePasswordOf(fresh, newPassword: 'a third kitchen sink'),
        throwsA(isA<RepositoryException>()),
      );
    });

    test('a person without a password is not a recovery', () async {
      final s = await linkSession();
      expect(repo.refreshed(s).recentLinkSession, isFalse);
      repo.changePasswordOf(s, newPassword: 'a green kitchen sink');
      expect(repo.passwordAudit.last.kind, 'change');
    });
  });
}
