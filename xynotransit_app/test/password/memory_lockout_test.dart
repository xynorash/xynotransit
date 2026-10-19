// The in-memory demo holds the same lockout design and link recovery rule as
// the API: per pair limits, the username backstop, trusted addresses, the
// address cap, and a new password after a link without the old one.
import 'package:flutter_test/flutter_test.dart';
import 'package:xynotransit_app/data/api/api_client.dart';
import 'package:xynotransit_app/data/memory_repository.dart';
import 'package:xynotransit_app/data/repository.dart';
import 'package:xynotransit_app/domain/catalog.dart';
import 'package:xynotransit_app/domain/enums.dart';
import 'package:xynotransit_app/domain/password_rules.dart';

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
    ApiException? tryChange(AppUser who, String current, String? from) {
      try {
        repo.changePasswordOf(
          who,
          currentPassword: current,
          newPassword: 'another long one',
          address: from,
        );
      } on ApiException catch (e) {
        return e;
      }
      return null;
    }

    AppUser signedIn(String? from) =>
        repo.loginWithPassword('rosa.rakoto', _good, address: from);

    test('an outsider\'s failed logins never block the change', () async {
      await give('rosa', _good);
      final mine = signedIn('203.0.113.7');
      wrongTries('rosa.rakoto', '203.0.113.7', 5);
      // 40 more failures from the same address: the address is locked too.
      for (var i = 0; i < 40; i++) {
        try {
          repo.loginWithPassword('ghost${i ~/ 4}', 'x', address: '203.0.113.7');
        } on ApiException {
          // Wrong or locked: either way a failed login.
        }
      }
      expect(
        () => repo.loginWithPassword(
          'rosa.rakoto',
          _good,
          address: '203.0.113.7',
        ),
        locked(),
      );
      expect(tryChange(mine, 'nope', '203.0.113.7')?.statusCode, 403);
      repo.changePasswordOf(
        mine,
        currentPassword: _good,
        newPassword: 'another long one',
        address: '203.0.113.7',
      );
    });

    test('wrong changes never count toward the login locks', () async {
      await give('rosa', _good);
      final mine = signedIn('203.0.113.7');
      for (var i = 0; i < 9; i++) {
        expect(tryChange(mine, 'nope $i', '203.0.113.7')?.statusCode, 403);
      }
      expect(signedIn('203.0.113.7').personId, 'rosa');
    });

    test(
      '10 failures from 10 addresses trigger the cap and end sessions',
      () async {
        await give('rosa', _good);
        final sessions = [
          for (var i = 0; i < 10; i++) signedIn('198.51.100.${i + 1}'),
        ];
        for (var i = 0; i < 9; i++) {
          expect(
            tryChange(
              sessions[i],
              'guess $i',
              '198.51.100.${i + 1}',
            )?.statusCode,
            403,
          );
        }
        final tenth = tryChange(sessions[9], 'guess 9', '198.51.100.10')!;
        expect(tenth.statusCode, 401);
        expect(tenth.message, PasswordRules.signedOutForSafety);
        expect(repo.passwordAudit.last.kind, 'change-lock');
        // Every token is dead.
        for (final s in sessions) {
          expect(
            () => repo.changePasswordOf(
              s,
              currentPassword: _good,
              newPassword: 'x',
            ),
            throwsA(isA<UnauthorizedException>()),
          );
        }
        // The person signs in again, with the password.
        final back = signedIn('203.0.113.7');
        // Not even the right current password is checked now (no 11th check).
        now = now.add(const Duration(minutes: 5));
        final e = tryChange(back, _good, '203.0.113.7')!;
        expect(e.statusCode, 429);
        expect(
          e.message,
          'Too many password attempts. Try again in 10 minutes.',
        );
        expect(e.retryAfterSeconds, 600);
        expect(repo.loginWithPassword('rosa.rakoto', _good).personId, 'rosa');
        // When the window has passed, they can change it.
        now = now.add(const Duration(minutes: 10));
        expect(tryChange(back, _good, '203.0.113.7'), isNull);
      },
    );

    test('failures older than 15 minutes do not count', () async {
      await give('rosa', _good);
      final mine = signedIn(null);
      for (var i = 0; i < 9; i++) {
        expect(tryChange(mine, 'nope $i', null)?.statusCode, 403);
      }
      now = now.add(const Duration(minutes: 15));
      expect(tryChange(mine, 'nope', null)?.statusCode, 403);
    });

    test('the cap is per person: another person is not affected', () async {
      await give('rosa', _good);
      await give('ben', _good);
      final ben = repo.loginWithPassword('ben', _good);
      final rosa = signedIn(null);
      for (var i = 0; i < 10; i++) {
        tryChange(rosa, 'nope $i', null);
      }
      expect(tryChange(ben, 'nope', null)?.statusCode, 403);
    });

    test(
      'a plain link counts a wrong current like any other session',
      () async {
        await give('rosa', _good);
        final link = await asBoss(() => repo.createSignInLink('rosa'));
        final s = repo.redeemSignInLink(link.url);
        for (var i = 0; i < 9; i++) {
          expect(tryChange(s, 'nope $i', null)?.statusCode, 403);
        }
        expect(tryChange(s, 'nope', null)?.statusCode, 401);
      },
    );
  });

  group('recovery by link', () {
    Future<AppUser> linkSession({bool recovery = true}) async {
      final link = await asBoss(
        () => repo.createSignInLink('rosa', recovery: recovery),
      );
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
      final link = await asBoss(
        () => repo.createSignInLink('rosa', recovery: true),
      );
      expect(link.recovery, isFalse, reason: 'ignored without a password');
      final s = repo.redeemSignInLink(link.url);
      expect(repo.refreshed(s).recentLinkSession, isFalse);
      repo.changePasswordOf(s, newPassword: 'a green kitchen sink');
      expect(repo.passwordAudit.last.kind, 'change');
    });

    test(
      'a manager link without recovery needs the current password',
      () async {
        await give('rosa', _good);
        final link = await asBoss(() => repo.createSignInLink('rosa'));
        expect(link.recovery, isFalse);
        final s = repo.redeemSignInLink(link.url);
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
        expect(
          () => repo.changePasswordOf(
            s,
            currentPassword: 'nope',
            newPassword: 'a green kitchen sink',
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
        repo.changePasswordOf(
          s,
          currentPassword: _good,
          newPassword: 'a green kitchen sink',
        );
      },
    );

    test('a recovery link is used once', () async {
      await give('rosa', _good);
      final link = await asBoss(
        () => repo.createSignInLink('rosa', recovery: true),
      );
      expect(link.recovery, isTrue);
      repo.redeemSignInLink(link.url);
      expect(
        () => repo.redeemSignInLink(link.url),
        throwsA(isA<RepositoryException>()),
      );
    });

    test('a link from the mailbox allows recovery', () async {
      await give('rosa', _good);
      final s = repo.emailLinkSession('rosa');
      expect(repo.refreshed(s).recentLinkSession, isTrue);
      repo.changePasswordOf(s, newPassword: 'a green kitchen sink');
    });

    test('the first password after any link needs no old one', () async {
      for (final recovery in [false, true]) {
        final s = await linkSession(recovery: recovery);
        repo.changePasswordOf(s, newPassword: 'a green kitchen sink');
        await asBoss(() => repo.removePassword('rosa'));
      }
    });
  });
}
