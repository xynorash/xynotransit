// How the client behaves when the network or a proxy misbehaves: what counts as
// "try again later" (NetworkException), what is retried, and that a rejected
// sign-in is cleared once and never loops.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xynotransit_app/data/api/api_auth.dart';
import 'package:xynotransit_app/data/api/api_client.dart';
import 'package:xynotransit_app/data/api/api_repository.dart';
import 'package:xynotransit_app/data/api/sse.dart';
import 'package:xynotransit_app/data/repository.dart';
import 'package:xynotransit_app/domain/enums.dart';
import 'package:xynotransit_app/domain/report.dart';

import 'api_client_test.dart' show json;

const _nginx502 =
    '<html><head><title>502 Bad Gateway</title></head><body>nginx</body></html>';

Matcher network([String? text]) => isA<NetworkException>().having(
  (e) => e.message,
  'message',
  text == null ? isNotEmpty : contains(text),
);

Future<ApiClient> client(MockClientHandler h, {String? token}) async {
  SharedPreferences.setMockInitialValues({TokenStore.tokenKey: ?token});
  return ApiClient(
    baseUrl: '/api',
    tokens: TokenStore(await SharedPreferences.getInstance()),
    client: MockClient(h),
    timeout: const Duration(milliseconds: 100),
    retryDelay: (_) => Duration.zero,
  );
}

void main() {
  group('what is a NetworkException', () {
    for (final status in [502, 503, 504, 408]) {
      test('$status with an HTML page from the proxy', () async {
        final api = await client(
          (r) async => http.Response(
            _nginx502,
            status,
            headers: {'content-type': 'text/html'},
          ),
        );
        await expectLater(api.get('/x'), throwsA(network()));
      });
    }

    test('503 with the API own JSON is also "not there right now"', () async {
      final api = await client(
        (r) async => json({
          'error': 'The service is not ready. Try again in a moment.',
        }, 503),
      );
      await expectLater(api.get('/x'), throwsA(network('Try again')));
    });

    test('500 and 429 are answers, not a missing network', () async {
      for (final status in [500, 429, 413]) {
        final api = await client((r) async => http.Response('oops', status));
        await expectLater(
          api.post('/x'),
          throwsA(isA<ApiException>().having((e) => e.statusCode, 's', status)),
        );
      }
    });

    test('an error body that is not UTF-8 does not crash the client', () async {
      final api = await client(
        (r) async => http.Response.bytes([0xff, 0xfe, 0x00, 0xc3], 500),
      );
      await expectLater(api.get('/x'), throwsA(isA<ApiException>()));
    });

    test(
      'a 200 HTML page (a proxy fallback) is unreadable, not a crash',
      () async {
        final api = await client(
          (r) async => http.Response('<!doctype html><html></html>', 200),
        );
        await expectLater(
          api.get('/x'),
          throwsA(
            isA<RepositoryException>().having(
              (e) => e.message,
              'm',
              contains('cannot read'),
            ),
          ),
        );
      },
    );

    test('truncated JSON is unreadable', () async {
      final api = await client((r) async => http.Response('{"a": [1, 2', 200));
      await expectLater(api.get('/x'), throwsA(isA<RepositoryException>()));
    });

    test('a connection that dies in the middle of the body', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final c = ApiClient(
        baseUrl: '/api',
        tokens: TokenStore(prefs),
        client: MockClient.streaming((req, body) async {
          final s = Stream<List<int>>.multi((m) {
            m.add(utf8.encode('{"a":'));
            m.addError(const SocketException('Connection reset by peer'));
            m.close();
          });
          return http.StreamedResponse(s, 200);
        }),
        maxAttempts: 1,
      );
      await expectLater(c.get('/x'), throwsA(network()));
    });

    test(
      'a failure that is not a ClientException is still the network',
      () async {
        final api = await client(
          (r) async => throw const SocketException('Failed host lookup'),
        );
        await expectLater(api.get('/x'), throwsA(network()));
      },
    );
  });

  group('retries', () {
    test('GET is retried after a network failure and then succeeds', () async {
      var calls = 0;
      final api = await client((r) async {
        calls++;
        if (calls < 3) throw http.ClientException('down');
        return json({'ok': 1});
      });
      expect(await api.get('/x'), {'ok': 1});
      expect(calls, 3);
    });

    test('GET gives up after three tries', () async {
      var calls = 0;
      final api = await client((r) async {
        calls++;
        return http.Response(_nginx502, 502);
      });
      await expectLater(api.get('/x'), throwsA(network()));
      expect(calls, 3);
    });

    test('a timeout is retried once, not twice', () async {
      var calls = 0;
      final api = await client((r) async {
        calls++;
        await Future<void>.delayed(const Duration(milliseconds: 400));
        return json({});
      });
      await expectLater(api.get('/x'), throwsA(isA<RequestTimeout>()));
      expect(calls, 2);
    });

    test('a refusal is never retried', () async {
      var calls = 0;
      final api = await client((r) async {
        calls++;
        return json({'error': 'No.'}, 403);
      });
      await expectLater(api.get('/x'), throwsA(isA<ApiException>()));
      expect(calls, 1);
    });

    test('POST, PATCH, PUT and DELETE are sent once unless marked', () async {
      for (final m in ['POST', 'PATCH', 'PUT', 'DELETE']) {
        var calls = 0;
        final api = await client((r) async {
          calls++;
          throw http.ClientException('down');
        });
        await expectLater(
          api.request(m, '/x', body: m == 'DELETE' ? null : {'a': 1}),
          throwsA(network()),
        );
        expect(calls, 1, reason: m);
      }
    });

    test('a call marked idempotent is retried with the same body', () async {
      final bodies = <String>[];
      final api = await client((r) async {
        bodies.add(r.body);
        if (bodies.length == 1) throw http.ClientException('down');
        return json({'ok': true});
      });
      await api.put('/x', body: {'a': 1}, idempotent: true);
      expect(bodies, ['{"a":1}', '{"a":1}']);
    });

    test('sending a report is retried through a restart of the API', () async {
      final seen = <String>[];
      final api = await client((r) async {
        seen.add('${r.method} ${r.url.path} ${r.body.hashCode}');
        if (seen.length == 1) return http.Response(_nginx502, 502);
        return json({
          'id': 'r1',
          'period_id': 'p',
          'assignment_id': 'a',
          'status': 'submitted',
          'values': <Object?>[],
          'kpis': <Object?>[],
          'notes': <Object?>[],
        });
      });
      final repo = ApiRepository(api, useDefaultSse: false);
      final saved = await repo.sendReport(
        Report(
          periodId: 'p',
          assignmentId: 'a',
          reporter: const Reporter(name: 'n', country: 'c', role: 'r'),
        ),
      );
      expect(saved.isSubmitted, isTrue);
      expect(seen, hasLength(2));
      expect(seen[0], seen[1], reason: 'same method, path and body');
    });

    test('creating a person is never repeated blindly', () async {
      var calls = 0;
      final api = await client((r) async {
        calls++;
        return http.Response(_nginx502, 502);
      });
      final repo = ApiRepository(api, useDefaultSse: false);
      await expectLater(
        repo.savePerson(
          fullName: 'A',
          email: 'a@b.co',
          role: AppRole.contributor,
        ),
        throwsA(network()),
      );
      expect(calls, 1);
    });
  });

  group('401', () {
    Future<(ApiAuthService, ApiClient, TokenStore, List<AppUser?>)> signedIn(
      MockClientHandler h,
    ) async {
      SharedPreferences.setMockInitialValues({TokenStore.tokenKey: 'old'});
      final tokens = TokenStore(await SharedPreferences.getInstance());
      final api = ApiClient(
        baseUrl: '/api',
        tokens: tokens,
        client: MockClient(h),
        timeout: const Duration(milliseconds: 100),
        retryDelay: (_) => Duration.zero,
      );
      final auth = ApiAuthService(api);
      await auth.restore();
      final seen = <AppUser?>[];
      auth.userChanges.listen(seen.add);
      await Future<void>.delayed(Duration.zero);
      return (auth, api, tokens, seen);
    }

    test('several calls in flight, one sign out, no loop', () async {
      var calls = 0;
      final (auth, api, tokens, seen) = await signedIn((r) async {
        if (r.url.path == '/api/me') {
          return json({'person_id': 'p', 'role': 'controller', 'label': 'A'});
        }
        calls++;
        return json({'error': 'Please sign in.'}, 401);
      });
      expect(auth.currentUser, isNotNull);
      final results = await Future.wait([
        for (var i = 0; i < 4; i++)
          api
              .get('/catalog')
              .then<Object?>((_) => null, onError: (Object e) => e),
      ]);
      expect(results, everyElement(isA<UnauthorizedException>()));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(tokens.token, isNull);
      expect(auth.currentUser, isNull);
      expect(seen.where((u) => u == null), hasLength(1));
      // Now signed out: more calls carry no token and change nothing.
      await expectLater(
        api.get('/catalog'),
        throwsA(isA<UnauthorizedException>()),
      );
      expect(seen.where((u) => u == null), hasLength(1));
      expect(calls, 5);
    });

    test('a late 401 for an old token does not undo a new sign in', () async {
      final gate = Completer<void>();
      final (auth, api, tokens, _) = await signedIn((r) async {
        if (r.url.path == '/api/me') {
          return json({'person_id': 'p', 'role': 'controller', 'label': 'A'});
        }
        await gate.future;
        return json({'error': 'Please sign in.'}, 401);
      });
      final slow = api
          .get('/catalog')
          .then<Object?>((_) => null, onError: (Object e) => e);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      // The person signs in again while the old call is still out.
      await tokens.save('new');
      gate.complete();
      expect(await slow, isA<UnauthorizedException>());
      expect(tokens.token, 'new');
      expect(auth.currentUser, isNotNull);
    });
  });

  group('live updates', () {
    test('a quiet connection still refetches on the safety tick', () async {
      final ctrl = StreamController<SseEvent>();
      final live = LiveChanges(
        source: _OneConn(ctrl),
        fetchTicket: () async => 't',
        buildUrl: (t) => Uri.parse('/e?ticket=$t'),
        backoff: (_) => const Duration(milliseconds: 5),
        pollInterval: const Duration(milliseconds: 20),
        safetyInterval: const Duration(milliseconds: 60),
        debounce: const Duration(milliseconds: 5),
      );
      final got = <LiveKind>[];
      final sub = live.stream.listen(got.add);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      ctrl.add(const SseOpened());
      await Future<void>.delayed(const Duration(milliseconds: 10));
      got.clear();
      // The connection says nothing for a while: no fast polling...
      await Future<void>.delayed(const Duration(milliseconds: 45));
      expect(got, isEmpty);
      // ...but the slow tick comes.
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(got, isNotEmpty);
      await sub.cancel();
      await ctrl.close();
    });
  });

  group('real sockets', () {
    late HttpServer server;
    late Uri base;
    var mode = 'ok';

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      base = Uri.parse('http://127.0.0.1:${server.port}/api');
      server.listen((req) async {
        switch (mode) {
          case 'ok':
            req.response
              ..headers.contentType = ContentType.json
              ..write('{"ok":true}');
            await req.response.close();
          case 'html502':
            req.response
              ..statusCode = 502
              ..headers.contentType = ContentType.html
              ..write(_nginx502);
            await req.response.close();
          case 'truncated':
            // Promise 100 bytes, send 5, hang up.
            final s = await req.response.detachSocket();
            s.write(
              'HTTP/1.1 200 OK\r\ncontent-type: application/json\r\n'
              'content-length: 100\r\n\r\n{"a":',
            );
            await s.flush();
            s.destroy();
          case 'hang':
            await Future<void>.delayed(const Duration(seconds: 3));
            await req.response.close();
        }
      });
    });
    tearDown(() => server.close(force: true));

    Future<ApiClient> real({int attempts = 1, String? url}) async {
      SharedPreferences.setMockInitialValues({});
      return ApiClient(
        baseUrl: url ?? base.toString(),
        tokens: TokenStore(await SharedPreferences.getInstance()),
        timeout: const Duration(milliseconds: 400),
        maxAttempts: attempts,
        retryDelay: (_) => Duration.zero,
      );
    }

    test('works', () async {
      expect(await (await real()).get('/x'), {'ok': true});
    });

    test('connection refused', () async {
      final api = await real(url: 'http://127.0.0.1:1/api');
      await expectLater(api.get('/x'), throwsA(network()));
    });

    test('a host name that does not exist', () async {
      final api = await real(url: 'http://no-such-host.invalid/api');
      await expectLater(api.get('/x'), throwsA(network()));
    });

    test('nginx 502 page', () async {
      mode = 'html502';
      addTearDown(() => mode = 'ok');
      await expectLater((await real()).get('/x'), throwsA(network()));
    });

    test('body cut short by a dropped connection', () async {
      mode = 'truncated';
      addTearDown(() => mode = 'ok');
      await expectLater((await real()).get('/x'), throwsA(network()));
    });

    test('a server that never answers', () async {
      mode = 'hang';
      addTearDown(() => mode = 'ok');
      await expectLater(
        (await real()).get('/x'),
        throwsA(isA<RequestTimeout>()),
      );
    });
  });
}

class _OneConn implements SseSource {
  _OneConn(this.c);
  final StreamController<SseEvent> c;
  @override
  Stream<SseEvent> open(Uri url) => c.stream;
}
