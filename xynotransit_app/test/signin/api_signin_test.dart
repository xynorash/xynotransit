import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:xynotransit_app/data/repository.dart';
import 'package:xynotransit_app/domain/enums.dart';

import '../api/api_client_test.dart' show json;
import '../api/api_repository_test.dart' show repoFor;

Matcher fails(String message) => throwsA(
  isA<RepositoryException>().having((e) => e.message, 'message', message),
);

Map<String, Object?> okLink() => {
  'url': 'https://reports.example/auth/verify?token=abc_DEF-123',
  'expires_at': '2026-06-02T09:00:00Z',
  'person_id': 'p7',
};

void main() {
  test('createSignInLink posts the hours and parses the answer', () async {
    late http.Request seen;
    final repo = await repoFor((r) async {
      seen = r;
      return json(okLink(), 201);
    });
    final l = await repo.createSignInLink('p7', hours: 168);
    expect(seen.method, 'POST');
    expect(seen.url.path, '/api/persons/p7/sign-in-link');
    expect(jsonDecode(seen.body), {'hours': 168, 'recovery': false});
    expect(seen.headers['Authorization'], 'Bearer tok');
    expect(l.url, 'https://reports.example/auth/verify?token=abc_DEF-123');
    expect(l.personId, 'p7');
    expect(l.expiresAt, DateTime.utc(2026, 6, 2, 9));
    expect(l.expiresAt.isUtc, isTrue);
  });

  test('recovery is sent, and the answer says whether it was kept', () async {
    late Object? body;
    final repo = await repoFor((r) async {
      body = jsonDecode(r.body);
      return json({...okLink(), 'recovery': true}, 201);
    });
    final l = await repo.createSignInLink('p7', recovery: true);
    expect(body, {'hours': 24, 'recovery': true});
    expect(l.recovery, isTrue);
    final plain = await (await repoFor((r) async => json(okLink(), 201)))
        .createSignInLink('p7');
    expect(plain.recovery, isFalse);
  });

  test('the default is 24 hours', () async {
    late Object? body;
    final repo = await repoFor((r) async {
      body = jsonDecode(r.body);
      return json(okLink(), 201);
    });
    await repo.createSignInLink('p7');
    expect(body, {'hours': 24, 'recovery': false});
  });

  test('an id with odd characters cannot change the path', () async {
    late Uri url;
    final repo = await repoFor((r) async {
      url = r.url;
      return json(okLink(), 201);
    });
    await repo.createSignInLink('a/b?c');
    expect(url.path, '/api/persons/a%2Fb%3Fc/sign-in-link');
  });

  for (final (status, message) in [
    (403, 'Only the manager can do this.'),
    (404, 'That person does not exist.'),
    (409, 'This person is switched off.'),
    (429, 'Too many sign-in links created. Try again later.'),
    (400, 'Choose a validity from 1 hour to 168 hours.'),
  ]) {
    test('$status shows the words of the server', () async {
      final repo = await repoFor((r) async => json({'error': message}, status));
      await expectLater(repo.createSignInLink('p7'), fails(message));
    });
  }

  test('a refusal without words still reads plainly', () async {
    final repo = await repoFor((r) async => http.Response('', 429));
    await expectLater(
      repo.createSignInLink('p7'),
      fails('Too many requests. Try again later.'),
    );
  });

  test(
    'no connection is a NetworkException and nothing is sent twice',
    () async {
      var calls = 0;
      final repo = await repoFor((r) async {
        calls++;
        throw http.ClientException('down');
      });
      await expectLater(
        repo.createSignInLink('p7'),
        throwsA(isA<NetworkException>()),
      );
      expect(calls, 1, reason: 'a second link must not be made by a retry');
    },
  );

  test('an answer the app cannot read is one plain failure', () async {
    for (final body in [
      <String, Object?>{'url': 'x'},
      {'url': 1, 'expires_at': 'x', 'person_id': 'p'},
      {'url': 'x', 'expires_at': 'not a date', 'person_id': 'p'},
    ]) {
      final repo = await repoFor((r) async => json(body, 201));
      await expectLater(
        repo.createSignInLink('p7'),
        fails('The server sent an answer the app cannot read.'),
      );
    }
  });

  group('savePerson without an email', () {
    test(
      'create sends no email field and returns the generated address',
      () async {
        late Map<String, Object?> body;
        final repo = await repoFor((r) async {
          body = (jsonDecode(r.body) as Map).cast<String, Object?>();
          return json({
            'id': 'p8',
            'full_name': 'Rosa Rakoto',
            'email': 'rosa.rakoto@xynotransit.internal',
            'app_role': 'contributor',
            'active': true,
          }, 201);
        });
        final p = await repo.savePerson(
          fullName: 'Rosa Rakoto',
          email: '  ',
          role: AppRole.contributor,
        );
        expect(body, {'full_name': 'Rosa Rakoto', 'app_role': 'contributor'});
        expect(p.email, 'rosa.rakoto@xynotransit.internal');
      },
    );

    test(
      'update with an empty email does not send one (keeps the old)',
      () async {
        late Map<String, Object?> body;
        final repo = await repoFor((r) async {
          body = (jsonDecode(r.body) as Map).cast<String, Object?>();
          return json({
            'id': 'p8',
            'full_name': 'Rosa',
            'email': 'rosa@xynotransit.internal',
            'app_role': 'contributor',
            'active': true,
          });
        });
        await repo.savePerson(
          id: 'p8',
          fullName: 'Rosa',
          email: '',
          role: AppRole.contributor,
        );
        expect(body.containsKey('email'), isFalse);
      },
    );
  });
}
