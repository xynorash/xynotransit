import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xynotransit_app/data/api/api_auth.dart';
import 'package:xynotransit_app/data/api/api_client.dart';
import 'package:xynotransit_app/data/repository.dart';

import 'api_client_test.dart' show json;

Future<(ApiAuthService, ApiClient, TokenStore)> make(
  MockClientHandler h, {
  Map<String, Object> prefs = const {},
}) async {
  SharedPreferences.setMockInitialValues(prefs);
  final tokens = TokenStore(await SharedPreferences.getInstance());
  final client = ApiClient(
    baseUrl: '/api',
    tokens: tokens,
    client: MockClient(h),
    timeout: const Duration(milliseconds: 200),
    retryDelay: (_) => Duration.zero,
  );
  return (ApiAuthService(client), client, tokens);
}

Map<String, Object?> verifyOk() => {
  'access_token': 'jwt1',
  'expires_at': '2026-10-25T00:00:00Z',
  'user': {'person_id': 'p1', 'role': 'controller', 'label': 'Rova'},
};

void main() {
  test('signInWithEmail posts the email without a token', () async {
    late http.Request seen;
    final (auth, _, _) = await make((r) async {
      seen = r;
      return json({}, 202);
    }, prefs: {TokenStore.tokenKey: 'old'});
    await auth.signInWithEmail('a@b.example');
    expect(seen.url.path, '/api/auth/magic-link');
    expect(jsonDecode(seen.body), {'email': 'a@b.example'});
    expect(seen.headers.containsKey('Authorization'), isFalse);
  });

  test('rate limit message reaches the caller', () async {
    final (auth, _, _) = await make(
      (r) async =>
          json({'error': 'Too many links requested. Try again later.'}, 429),
    );
    await expectLater(
      auth.signInWithEmail('a@b.example'),
      throwsA(
        isA<RepositoryException>().having(
          (e) => e.message,
          'm',
          'Too many links requested. Try again later.',
        ),
      ),
    );
  });

  test('exchangeToken stores token and user, and announces the user', () async {
    final (auth, _, tokens) = await make((r) async {
      expect(r.url.path, '/api/auth/verify');
      expect(jsonDecode(r.body), {'token': 'abc'});
      return json(verifyOk());
    });
    final seen = <AppUser?>[];
    final sub = auth.userChanges.listen(seen.add);
    await auth.exchangeToken('abc');
    await Future<void>.delayed(Duration.zero);
    expect(tokens.token, 'jwt1');
    expect(auth.currentUser!.label, 'Rova');
    expect(auth.currentUser!.isController, isTrue);
    expect(seen.last!.personId, 'p1');
    await sub.cancel();
  });

  test('exchangeToken with an expired link shows the server words', () async {
    const words =
        'This link has expired or was already used. Ask for a new one.';
    final (auth, _, tokens) = await make(
      (r) async => json({'error': words}, 401),
    );
    await expectLater(
      auth.exchangeToken('abc'),
      throwsA(isA<RepositoryException>().having((e) => e.message, 'm', words)),
    );
    expect(tokens.token, isNull);
    expect(auth.currentUser, isNull);
  });

  test('exchangeToken rejects an answer without a token', () async {
    final (auth, _, _) = await make(
      (r) async => json({'user': <String, Object?>{}}),
    );
    await expectLater(
      auth.exchangeToken('abc'),
      throwsA(isA<RepositoryException>()),
    );
  });

  test('restore keeps a valid session', () async {
    final (auth, _, tokens) = await make((r) async {
      expect(r.url.path, '/api/me');
      expect(r.headers['Authorization'], 'Bearer jwt1');
      return json({'person_id': 'p2', 'role': 'contributor', 'label': 'Mina'});
    }, prefs: {TokenStore.tokenKey: 'jwt1'});
    await auth.restore();
    expect(auth.currentUser!.label, 'Mina');
    expect(tokens.token, 'jwt1');
  });

  test('restore with a rejected token signs out and clears it', () async {
    final (auth, _, tokens) = await make(
      (r) async => json({'error': 'Please sign in again.'}, 401),
      prefs: {TokenStore.tokenKey: 'stale'},
    );
    await auth.restore();
    expect(auth.currentUser, isNull);
    expect(tokens.token, isNull);
  });

  test('restore offline falls back to the last known person', () async {
    final (auth, _, tokens) = await make(
      (r) async => throw http.ClientException('down'),
      prefs: {
        TokenStore.tokenKey: 'jwt1',
        TokenStore.userKey: jsonEncode({
          'person_id': 'p1',
          'role': 'controller',
          'label': 'Rova',
        }),
      },
    );
    await auth.restore();
    expect(auth.currentUser!.label, 'Rova');
    expect(tokens.token, 'jwt1');
  });

  test('restore without a token does nothing', () async {
    final (auth, _, _) = await make((r) async => fail('no call expected'));
    await auth.restore();
    expect(auth.currentUser, isNull);
  });

  test('a 401 on any call clears the token and signs out', () async {
    var signedIn = true;
    final (auth, client, tokens) = await make((r) async {
      if (r.url.path == '/api/auth/verify') return json(verifyOk());
      return signedIn
          ? json({'ok': true})
          : json({'error': 'Please sign in again.'}, 401);
    });
    await auth.exchangeToken('abc');
    final seen = <AppUser?>[];
    final sub = auth.userChanges.listen(seen.add);
    await client.get('/catalog');
    signedIn = false;
    await expectLater(
      client.get('/catalog'),
      throwsA(isA<UnauthorizedException>()),
    );
    await Future<void>.delayed(Duration.zero);
    expect(tokens.token, isNull);
    expect(auth.currentUser, isNull);
    expect(seen.last, isNull);
    await sub.cancel();
  });

  test('signOut clears everything', () async {
    final (auth, _, tokens) = await make((r) async => json(verifyOk()));
    await auth.exchangeToken('abc');
    await auth.signOut();
    expect(tokens.token, isNull);
    expect(tokens.cachedUser, isNull);
    expect(auth.currentUser, isNull);
  });

  test('needsSignIn is true', () async {
    final (auth, _, _) = await make((r) async => json({}));
    expect(auth.needsSignIn, isTrue);
  });
}
