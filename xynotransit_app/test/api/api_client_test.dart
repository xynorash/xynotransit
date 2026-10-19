import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xynotransit_app/data/api/api_client.dart';
import 'package:xynotransit_app/data/repository.dart';

Future<ApiClient> clientFor(
  MockClientHandler handler, {
  String? token,
  String base = '/api',
}) async {
  SharedPreferences.setMockInitialValues({TokenStore.tokenKey: ?token});
  final prefs = await SharedPreferences.getInstance();
  return ApiClient(
    baseUrl: base,
    tokens: TokenStore(prefs),
    client: MockClient(handler),
    timeout: const Duration(milliseconds: 200),
    retryDelay: (_) => Duration.zero,
  );
}

http.Response json(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

void main() {
  test(
    'sends bearer token, JSON body and builds the url under the base',
    () async {
      late http.Request seen;
      final api = await clientFor((r) async {
        seen = r;
        return json({'ok': true});
      }, token: 'tok');
      final out = await api.post('/periods/ensure', body: {'a': 1});
      expect(out, {'ok': true});
      expect(seen.method, 'POST');
      expect(seen.url.path, '/api/periods/ensure');
      expect(seen.headers['Authorization'], 'Bearer tok');
      expect(seen.headers['Content-Type'], contains('application/json'));
      expect(jsonDecode(seen.body), {'a': 1});
    },
  );

  test('no token means no Authorization header; auth false skips it', () async {
    final seen = <http.Request>[];
    final api = await clientFor((r) async {
      seen.add(r);
      return json({});
    });
    await api.get('/me');
    expect(seen.single.headers.containsKey('Authorization'), isFalse);
    final api2 = await clientFor((r) async {
      seen.add(r);
      return json({});
    }, token: 'tok');
    await api2.post('/auth/verify', auth: false);
    expect(seen.last.headers.containsKey('Authorization'), isFalse);
  });

  test('query parameters and trailing slash base', () async {
    late Uri url;
    final api = await clientFor((r) async {
      url = r.url;
      return json({});
    }, base: 'http://h:8081/api/');
    await api.get('/events', query: {'ticket': 'a b', 'period_id': 'x'});
    expect(url.toString(), 'http://h:8081/api/events?ticket=a+b&period_id=x');
  });

  test('null and empty bodies decode to null', () async {
    var n = 0;
    final api = await clientFor((r) async {
      return n++ == 0 ? http.Response('null', 200) : http.Response('', 204);
    });
    expect(await api.get('/x'), isNull);
    expect(await api.get('/x'), isNull);
  });

  for (final c in [
    (400, 'Enter a number for "Imports" in March.'),
    (403, 'You can only send your own report.'),
    (404, 'Not found.'),
    (409, 'Clash.'),
    (429, 'Too many links requested. Try again later.'),
    (500, 'Something broke.'),
  ]) {
    test('${c.$1} surfaces the server error text', () async {
      final api = await clientFor((r) async => json({'error': c.$2}, c.$1));
      await expectLater(
        api.get('/x'),
        throwsA(
          isA<ApiException>()
              .having((e) => e.statusCode, 'status', c.$1)
              .having((e) => e.message, 'message', c.$2),
        ),
      );
    });
  }

  test(
    '401 with a token clears via onUnauthorized; without a token it does not',
    () async {
      var calls = 0;
      final api = await clientFor(
        (r) async => json({'error': 'Sign in.'}, 401),
        token: 'old',
      );
      api.onUnauthorized = () => calls++;
      await expectLater(api.get('/me'), throwsA(isA<UnauthorizedException>()));
      expect(calls, 1);
      await expectLater(
        api.post('/auth/verify', auth: false),
        throwsA(isA<UnauthorizedException>()),
      );
      expect(calls, 1);
    },
  );

  test('transport failures become NetworkException', () async {
    final api = await clientFor(
      (r) async => throw http.ClientException('down'),
    );
    await expectLater(api.get('/x'), throwsA(isA<NetworkException>()));
  });

  test('a slow server becomes NetworkException', () async {
    final api = await clientFor((r) async {
      await Future<void>.delayed(const Duration(seconds: 2));
      return json({});
    });
    await expectLater(api.get('/x'), throwsA(isA<NetworkException>()));
  });

  test('a 200 that is not JSON is a readable failure', () async {
    final api = await clientFor((r) async => http.Response('<html>', 200));
    await expectLater(
      api.get('/x'),
      throwsA(
        isA<RepositoryException>().having(
          (e) => e.message,
          'message',
          contains('cannot read'),
        ),
      ),
    );
  });

  test('TokenStore round trip', () async {
    SharedPreferences.setMockInitialValues({});
    final t = TokenStore(await SharedPreferences.getInstance());
    expect(t.token, isNull);
    await t.save('abc');
    await t.saveUser('{}');
    expect(t.token, 'abc');
    await t.clear();
    expect(t.token, isNull);
    expect(t.cachedUser, isNull);
  });

  group('429 with Retry-After says when to try again (D12)', () {
    http.Response limited(String? retryAfter, [String? error]) => http.Response(
      jsonEncode({
        'error': error ?? 'Too many links requested. Try again later.',
      }),
      429,
      headers: {'content-type': 'application/json', 'retry-after': ?retryAfter},
    );

    for (final c in [
      ('1', 'Too many links requested. Try again in 1 second.'),
      ('45', 'Too many links requested. Try again in 45 seconds.'),
      ('60', 'Too many links requested. Try again in 1 minute.'),
      ('61', 'Too many links requested. Try again in 2 minutes.'),
      ('1800', 'Too many links requested. Try again in 30 minutes.'),
      ('3600', 'Too many links requested. Try again in 1 hour.'),
      ('7201', 'Too many links requested. Try again in 3 hours.'),
    ]) {
      test('Retry-After ${c.$1}', () async {
        final api = await clientFor((r) async => limited(c.$1));
        await expectLater(
          api.post('/auth/magic-link', auth: false),
          throwsA(
            isA<ApiException>()
                .having((e) => e.statusCode, 'status', 429)
                .having((e) => e.retryAfterSeconds, 'seconds', int.parse(c.$1))
                .having((e) => e.message, 'message', c.$2),
          ),
        );
      });
    }

    test('a message without "Try again later" gets the wait added', () async {
      final api = await clientFor(
        (r) async => limited('120', 'Too many sign-in links created.'),
      );
      await expectLater(
        api.get('/x'),
        throwsA(
          isA<ApiException>().having(
            (e) => e.message,
            'message',
            'Too many sign-in links created. Try again in 2 minutes.',
          ),
        ),
      );
    });

    for (final bad in [
      null,
      '',
      'soon',
      '-5',
      'Wed, 21 Oct 2026 07:28:00 GMT',
    ]) {
      test(
        'no usable header (${bad ?? 'none'}) keeps the server words',
        () async {
          final api = await clientFor((r) async => limited(bad));
          await expectLater(
            api.get('/x'),
            throwsA(
              isA<ApiException>()
                  .having((e) => e.retryAfterSeconds, 'seconds', isNull)
                  .having(
                    (e) => e.message,
                    'message',
                    'Too many links requested. Try again later.',
                  ),
            ),
          );
        },
      );
    }

    test('only a 429 reads the header', () async {
      final api = await clientFor(
        (r) async => http.Response(
          jsonEncode({'error': 'Clash.'}),
          409,
          headers: {'content-type': 'application/json', 'retry-after': '30'},
        ),
      );
      await expectLater(
        api.get('/x'),
        throwsA(
          isA<ApiException>()
              .having((e) => e.retryAfterSeconds, 'seconds', isNull)
              .having((e) => e.message, 'message', 'Clash.'),
        ),
      );
    });
  });
}
