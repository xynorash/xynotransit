import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xynotransit_app/data/api/api_auth.dart';
import 'package:xynotransit_app/data/api/api_client.dart';
import 'package:xynotransit_app/data/api/api_models.dart';
import 'package:xynotransit_app/data/repository.dart';
import 'package:xynotransit_app/domain/enums.dart';

import '../api/api_client_test.dart' show json;
import '../api/api_repository_test.dart' show repoFor;

Matcher fails(String message) => throwsA(
  isA<RepositoryException>().having((e) => e.message, 'message', message),
);

Future<(ApiAuthService, TokenStore, List<http.Request>)> authFor(
  MockClientHandler h, {
  String? token,
}) async {
  SharedPreferences.setMockInitialValues({TokenStore.tokenKey: ?token});
  final prefs = await SharedPreferences.getInstance();
  final tokens = TokenStore(prefs);
  final seen = <http.Request>[];
  final auth = ApiAuthService(
    ApiClient(
      baseUrl: '/api',
      tokens: tokens,
      client: MockClient((r) {
        seen.add(r);
        return h(r);
      }),
      timeout: const Duration(milliseconds: 200),
      retryDelay: (_) => Duration.zero,
    ),
  );
  return (auth, tokens, seen);
}

Map<String, Object?> loginAnswer({
  bool must = false,
  String token = 'tok-login',
}) => {
  'access_token': token,
  'expires_at': '2026-10-26T00:00:00Z',
  'user': {'person_id': 'p1', 'role': 'contributor', 'label': 'Rosa Rakoto'},
  'must_change_password': must,
  'has_password': true,
};

void main() {
  group('sign in with a password', () {
    test(
      'posts the username (trimmed, lower case) and the password as typed',
      () async {
        final (auth, tokens, seen) = await authFor(
          (r) async => json(loginAnswer()),
        );
        await auth.signInWithPassword('  Rosa.Rakoto ', '  two spaces kept  ');
        expect(seen.single.method, 'POST');
        expect(seen.single.url.path, '/api/auth/login');
        expect(seen.single.headers.containsKey('Authorization'), isFalse);
        expect(jsonDecode(seen.single.body), {
          'username': 'rosa.rakoto',
          'password': '  two spaces kept  ',
        });
        expect(tokens.token, 'tok-login');
        final u = auth.currentUser!;
        expect(u.personId, 'p1');
        expect(u.role, AppRole.contributor);
        expect(u.username, 'rosa.rakoto');
        expect(u.hasPassword, isTrue);
        expect(u.mustChangePassword, isFalse);
        // The user is kept for an offline start.
        expect(
          jsonDecode(tokens.cachedUser!),
          containsPair('username', 'rosa.rakoto'),
        );
      },
    );

    test('must_change_password reaches the user', () async {
      final (auth, _, _) = await authFor(
        (r) async => json(loginAnswer(must: true)),
      );
      await auth.signInWithPassword('rosa.rakoto', 'AbCdEfGh23456789');
      expect(auth.currentUser!.mustChangePassword, isTrue);
    });

    test('a wrong login shows the server words and signs nobody in', () async {
      final (auth, tokens, _) = await authFor(
        (r) async => json({'error': 'Username or password is wrong.'}, 401),
      );
      await expectLater(
        auth.signInWithPassword('rosa.rakoto', 'nope'),
        fails('Username or password is wrong.'),
      );
      expect(auth.currentUser, isNull);
      expect(tokens.token, isNull);
    });

    test('a 429 says when to retry, from Retry-After', () async {
      final (auth, _, _) = await authFor(
        (r) async => http.Response(
          jsonEncode({'error': 'Too many sign-in attempts. Try again later.'}),
          429,
          headers: {'retry-after': '840', 'content-type': 'application/json'},
        ),
      );
      Object? err;
      try {
        await auth.signInWithPassword('rosa.rakoto', 'nope');
      } catch (e) {
        err = e;
      }
      final e = err! as ApiException;
      expect(e.statusCode, 429);
      expect(e.retryAfterSeconds, 840);
      expect(e.message, 'Too many sign-in attempts. Try again in 14 minutes.');
    });

    test('a proxy 503 is a network failure, not a refusal', () async {
      final (auth, _, _) = await authFor(
        (r) async => http.Response('<html>Bad gateway</html>', 503),
      );
      await expectLater(
        auth.signInWithPassword('rosa.rakoto', 'a purple bicycle'),
        throwsA(isA<NetworkException>()),
      );
    });

    test('the API\'s own busy 503 keeps its words', () async {
      final (auth, _, _) = await authFor(
        (r) async => json({'error': 'Busy, try again in a moment.'}, 503),
      );
      await expectLater(
        auth.signInWithPassword('rosa.rakoto', 'a purple bicycle'),
        fails('Busy, try again in a moment.'),
      );
    });

    test('an answer without a token is refused in plain words', () async {
      final (auth, _, _) = await authFor(
        (r) async => json({'user': <String, Object?>{}}),
      );
      await expectLater(
        auth.signInWithPassword('a b c', 'whatever one'),
        fails('The server sent an answer the app cannot read.'),
      );
    });
  });

  group('the sign-in link answer', () {
    test('has_password and must_change_password reach the app', () async {
      final (auth, _, seen) = await authFor((r) async {
        if (r.url.path == '/api/me') {
          return json({
            'person_id': 'p1',
            'role': 'contributor',
            'label': 'Rosa Rakoto',
            'username': 'rosa.rakoto',
            'has_password': false,
            'must_change_password': false,
          });
        }
        return json({
          'access_token': 'tok-link',
          'expires_at': '2026-10-26T00:00:00Z',
          'user': {
            'person_id': 'p1',
            'role': 'contributor',
            'label': 'Rosa Rakoto',
          },
          'has_password': false,
          'must_change_password': false,
        });
      });
      await auth.exchangeToken('abc');
      expect(seen.map((r) => r.url.path), ['/api/auth/verify', '/api/me']);
      expect(auth.currentUser!.hasPassword, isFalse);
      expect(auth.currentUser!.username, 'rosa.rakoto');
    });

    test('works when /me cannot be read right then', () async {
      final (auth, tokens, _) = await authFor((r) async {
        if (r.url.path == '/api/me') return json({}, 502);
        return json({
          'access_token': 'tok-link',
          'expires_at': '2026-10-26T00:00:00Z',
          'user': {'person_id': 'p1', 'role': 'controller', 'label': 'Ana'},
          'has_password': true,
          'must_change_password': true,
        });
      });
      await auth.exchangeToken('abc');
      expect(tokens.token, 'tok-link');
      expect(auth.currentUser!.mustChangePassword, isTrue);
      expect(auth.currentUser!.hasPassword, isTrue);
      expect(auth.currentUser!.username, isNull);
    });
  });

  group('a 403 asking for a new password', () {
    test('sends the person to the new password screen', () async {
      final (auth, _, _) = await authFor((r) async {
        if (r.url.path == '/api/auth/login') return json(loginAnswer());
        return json({'error': 'Choose a new password first.'}, 403);
      });
      await auth.signInWithPassword('rosa.rakoto', 'a purple bicycle');
      expect(auth.currentUser!.mustChangePassword, isFalse);
      final events = <bool>[];
      final sub = auth.userChanges.listen(
        (u) => events.add(u?.mustChangePassword ?? false),
      );
      await expectLater(
        auth.testClient.get('/catalog'),
        throwsA(isA<ApiException>()),
      );
      await Future<void>.delayed(Duration.zero);
      expect(auth.currentUser!.mustChangePassword, isTrue);
      expect(events, contains(true));
      await sub.cancel();
    });
  });

  group('/me', () {
    test('username and password state are read at start', () async {
      final (auth, _, _) = await authFor((r) async {
        return json({
          'person_id': 'p1',
          'role': 'controller',
          'label': 'Ana',
          'username': 'ana',
          'has_password': true,
          'must_change_password': true,
        });
      }, token: 'old');
      await auth.restore();
      final u = auth.currentUser!;
      expect(u.username, 'ana');
      expect(u.hasPassword, isTrue);
      expect(u.mustChangePassword, isTrue);
    });

    test('older answers without the new fields read as no password', () {
      final u = parseUser({
        'person_id': 'p',
        'role': 'contributor',
        'label': 'x',
      });
      expect(u.hasPassword, isFalse);
      expect(u.mustChangePassword, isFalse);
      expect(u.username, isNull);
    });
  });

  group('change password', () {
    test('sends both passwords and swaps the token', () async {
      final (auth, tokens, seen) = await authFor((r) async {
        if (r.url.path == '/api/auth/password') {
          return json({
            'access_token': 'tok-new',
            'expires_at': '2026-10-26T00:00:00Z',
          });
        }
        return json(loginAnswer());
      });
      await auth.signInWithPassword('rosa.rakoto', 'a purple bicycle');
      await auth.changePassword(
        currentPassword: 'a purple bicycle',
        newPassword: ' a green kitchen sink ',
      );
      final r = seen.last;
      expect(r.method, 'POST');
      expect(r.url.path, '/api/auth/password');
      expect(r.headers['Authorization'], 'Bearer tok-login');
      expect(jsonDecode(r.body), {
        'current_password': 'a purple bicycle',
        'new_password': ' a green kitchen sink ',
      });
      expect(tokens.token, 'tok-new');
      expect(auth.currentUser!.personId, 'p1');
      expect(auth.currentUser!.hasPassword, isTrue);
      expect(auth.currentUser!.mustChangePassword, isFalse);
    });

    test('the first password has no current_password at all', () async {
      final (auth, tokens, seen) = await authFor((r) async {
        if (r.url.path == '/api/auth/password') {
          return json({'access_token': 'tok-new', 'expires_at': 'x'});
        }
        return json(loginAnswer());
      });
      await auth.signInWithPassword('rosa.rakoto', 'a purple bicycle');
      await auth.changePassword(newPassword: 'chosen after the link');
      expect(jsonDecode(seen.last.body), {
        'new_password': 'chosen after the link',
      });
      expect(tokens.token, 'tok-new');
    });

    test('clears must_change_password in the kept user', () async {
      final (auth, tokens, seen) = await authFor((r) async {
        if (r.url.path == '/api/auth/password') {
          return json({'access_token': 'tok-new', 'expires_at': 'x'});
        }
        return json(loginAnswer(must: true));
      });
      await auth.signInWithPassword('rosa.rakoto', 'AbCdEfGh23456789');
      expect(auth.currentUser!.mustChangePassword, isTrue);
      await auth.changePassword(
        currentPassword: 'AbCdEfGh23456789',
        newPassword: 'my own long phrase',
      );
      expect(seen, hasLength(2));
      expect(auth.currentUser!.mustChangePassword, isFalse);
      expect(
        jsonDecode(tokens.cachedUser!),
        containsPair('must_change_password', false),
      );
    });

    for (final (status, msg) in [
      (403, 'Your current password is not right.'),
      (400, 'Use at least 10 characters.'),
      (400, 'Choose a password different from the current one.'),
      (429, 'Too many sign-in attempts. Try again later.'),
    ]) {
      test('$status: $msg', () async {
        final (auth, tokens, _) = await authFor((r) async {
          if (r.url.path == '/api/auth/password') {
            return json({'error': msg}, status);
          }
          return json(loginAnswer());
        });
        await auth.signInWithPassword('rosa.rakoto', 'a purple bicycle');
        await expectLater(
          auth.changePassword(
            currentPassword: 'x',
            newPassword: 'a green kitchen sink',
          ),
          throwsA(
            isA<ApiException>()
                .having((e) => e.statusCode, 'status', status)
                .having(
                  (e) => e.message,
                  'message',
                  startsWith(msg.replaceAll(' Try again later.', '')),
                ),
          ),
        );
        // The old session is kept when the change is refused.
        expect(tokens.token, 'tok-login');
        expect(auth.currentUser, isNotNull);
      });
    }

    test('a 401 (an older session) signs out', () async {
      final (auth, tokens, _) = await authFor((r) async {
        if (r.url.path == '/api/auth/password') {
          return json({'error': 'Please sign in again.'}, 401);
        }
        return json(loginAnswer());
      });
      await auth.signInWithPassword('rosa.rakoto', 'a purple bicycle');
      await expectLater(
        auth.changePassword(
          currentPassword: 'x',
          newPassword: 'a green kitchen sink',
        ),
        throwsA(isA<UnauthorizedException>()),
      );
      expect(auth.currentUser, isNull);
      expect(tokens.token, isNull);
    });
  });

  group('the repository', () {
    test(
      'resetPassword posts an empty body and reads the temporary password',
      () async {
        late http.Request seen;
        final repo = await repoFor((r) async {
          seen = r;
          return json({
            'username': 'rosa.rakoto',
            'temporary_password': 'AbCdEfGh23456789',
            'must_change_password': true,
          }, 201);
        });
        final t = await repo.resetPassword('p7');
        expect(seen.method, 'POST');
        expect(seen.url.path, '/api/persons/p7/password-reset');
        expect(jsonDecode(seen.body), <String, Object?>{});
        expect(seen.headers['Authorization'], 'Bearer tok');
        expect(t.username, 'rosa.rakoto');
        expect(t.password, 'AbCdEfGh23456789');
      },
    );

    test('an id with odd characters cannot change the path', () async {
      late Uri url;
      final repo = await repoFor((r) async {
        url = r.url;
        return json({'username': 'a', 'temporary_password': 'b'}, 201);
      });
      await repo.resetPassword('a/b?c');
      expect(url.path, '/api/persons/a%2Fb%3Fc/password-reset');
    });

    for (final (status, message) in [
      (403, 'Only the manager can do this.'),
      (404, 'That person does not exist.'),
      (409, 'This person is switched off.'),
      (429, 'Too many temporary passwords created. Try again later.'),
    ]) {
      test('reset: $status shows the words of the server', () async {
        final repo = await repoFor(
          (r) async => json({'error': message}, status),
        );
        await expectLater(repo.resetPassword('p7'), fails(message));
      });
    }

    test('a reset is never sent twice by itself', () async {
      var calls = 0;
      final repo = await repoFor((r) async {
        calls++;
        return http.Response('', 502);
      });
      await expectLater(
        repo.resetPassword('p7'),
        throwsA(isA<NetworkException>()),
      );
      expect(calls, 1);
    });

    test('a 429 on reset says when to retry', () async {
      final repo = await repoFor(
        (r) async => http.Response(
          jsonEncode({
            'error': 'Too many temporary passwords created. Try again later.',
          }),
          429,
          headers: {'retry-after': '1800'},
        ),
      );
      await expectLater(
        repo.resetPassword('p7'),
        fails('Too many temporary passwords created. Try again in 30 minutes.'),
      );
    });

    test('removePassword deletes /persons/{id}/password', () async {
      late http.Request seen;
      final repo = await repoFor((r) async {
        seen = r;
        return http.Response('', 204);
      });
      await repo.removePassword('p7');
      expect(seen.method, 'DELETE');
      expect(seen.url.path, '/api/persons/p7/password');
    });

    test('savePerson sends the username on create and on update', () async {
      final seen = <http.Request>[];
      final repo = await repoFor((r) async {
        seen.add(r);
        return json({
          'id': 'p9',
          'full_name': 'Rosa',
          'email': 'rosa@example.com',
          'app_role': 'contributor',
          'active': true,
          'username': 'rosa_r',
          'has_password': true,
        }, r.method == 'POST' ? 201 : 200);
      });
      final created = await repo.savePerson(
        fullName: 'Rosa',
        email: 'rosa@example.com',
        role: AppRole.contributor,
        username: ' Rosa_R ',
      );
      expect(jsonDecode(seen.first.body), containsPair('username', 'rosa_r'));
      expect(created.username, 'rosa_r');
      expect(created.hasPassword, isTrue);
      await repo.savePerson(
        id: 'p9',
        fullName: 'Rosa',
        email: 'rosa@example.com',
        role: AppRole.contributor,
        username: 'new.name',
      );
      expect(seen.last.method, 'PATCH');
      expect(jsonDecode(seen.last.body), containsPair('username', 'new.name'));
    });

    test(
      'without a username none is sent (the server makes one or keeps it)',
      () async {
        late Object? body;
        final repo = await repoFor((r) async {
          body = jsonDecode(r.body);
          return json({
            'id': 'p9',
            'full_name': 'Rosa',
            'email': 'rosa@example.com',
            'app_role': 'contributor',
            'active': true,
            'username': 'rosa',
            'has_password': false,
          }, 201);
        });
        await repo.savePerson(
          fullName: 'Rosa',
          email: 'rosa@example.com',
          role: AppRole.contributor,
          username: '  ',
        );
        expect(body, isNot(contains('username')));
      },
    );

    for (final (status, message) in [
      (
        400,
        'Usernames use letters, digits, dots, dashes and underscores, 3 to 40 characters.',
      ),
      (409, 'That username is already used.'),
    ]) {
      test('username $status shows the server words', () async {
        final repo = await repoFor(
          (r) async => json({'error': message}, status),
        );
        await expectLater(
          repo.savePerson(
            id: 'p9',
            fullName: 'Rosa',
            email: 'rosa@example.com',
            role: AppRole.contributor,
            username: 'x y',
          ),
          fails(message),
        );
      });
    }

    test('a person answer without the new fields reads as no password', () {
      final p = parsePerson({
        'id': 'p1',
        'full_name': 'Rosa',
        'email': null,
        'app_role': 'contributor',
        'active': true,
      });
      expect(p.username, isNull);
      expect(p.hasPassword, isFalse);
    });
  });
}
