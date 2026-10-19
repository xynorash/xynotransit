// Opening the app without a network: the last good catalog, period and deck
// words are used, never after the person signs out, and never to undo a fresher
// answer.
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:xynotransit_app/data/api/api_auth.dart';
import 'package:xynotransit_app/data/api/api_client.dart';
import 'package:xynotransit_app/data/api/api_repository.dart';
import 'package:xynotransit_app/data/repository.dart';

import 'api_client_test.dart' show clientFor, json;
import 'api_models_test.dart' show catalogJson;

const periodJson = {
  'id': 'per1',
  'start_month': '2026-02-01',
  'meeting_date': '2026-06-09',
  'status': 'open',
};

void main() {
  late bool online;
  late ApiRepository repo;
  late ApiClient api;

  setUp(() async {
    online = true;
    api = await clientFor((r) async {
      if (!online) throw http.ClientException('down');
      if (r.url.path == '/api/catalog') return json(catalogJson());
      if (r.url.path == '/api/periods/ensure') return json(periodJson);
      if (r.url.path.endsWith('/deck-text')) {
        return json({
          'settings': {'title': 'Words {period}'},
          'inherited_from': 'defaults',
        });
      }
      return json({});
    }, token: 'tok');
    repo = ApiRepository(
      api,
      useDefaultSse: false,
      pollInterval: const Duration(milliseconds: 40),
    );
  });

  test('the period opens from this device when offline', () async {
    final live = await repo.ensurePeriod(DateTime(2026, 2, 17));
    online = false;
    final kept = await repo.ensurePeriod(DateTime(2026, 2, 3));
    expect(kept.id, live.id);
    expect(kept.meetingDate, DateTime(2026, 6, 9));
    // A month never seen has nothing to fall back on.
    await expectLater(
      repo.ensurePeriod(DateTime(2026, 5)),
      throwsA(isA<NetworkException>()),
    );
  });

  test('deck words come from this device when offline', () async {
    final live = await repo.loadDeckTexts('per1');
    online = false;
    final kept = await repo.loadDeckTexts('per1');
    expect(kept.texts['title'], live.texts['title']);
    expect(kept.inheritedFrom, 'defaults');
    await expectLater(
      repo.loadDeckTexts('per2'),
      throwsA(isA<NetworkException>()),
    );
  });

  test('loadCatalog itself never serves old data', () async {
    await repo.loadCatalog();
    online = false;
    await expectLater(repo.loadCatalog(), throwsA(isA<NetworkException>()));
  });

  test('the catalog stream starts from this device, then goes live', () async {
    // First run online: the answer is kept.
    final first = await repo.watchCatalog().first;
    expect(first.assignments, hasLength(2));
    // Next start without a network.
    online = false;
    final seen = <int>[];
    final sub = repo.watchCatalog().listen(
      (c) => seen.add(c.assignments.length),
    );
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(seen, [2], reason: 'the kept catalog, and no error');
    // The network is back: the live catalog replaces it.
    online = true;
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(seen, [2, 2]);
    // And it stops asking.
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(seen, [2, 2]);
    await sub.cancel();
  });

  test('without anything kept the catalog stream fails as before', () async {
    online = false;
    await expectLater(
      repo.watchCatalog().first,
      throwsA(isA<NetworkException>()),
    );
  });

  test('a person of the catalog view is not mixed with another', () async {
    await repo.ensurePeriod(DateTime(2026, 2));
    await repo.watchCatalog().first;
    final auth = ApiAuthService(api);
    // Signing out removes everything kept.
    await auth.signOut();
    expect(api.tokens.cached('catalog'), isNull);
    expect(api.tokens.cached('period/2026-02-01'), isNull);
    online = false;
    await expectLater(
      repo.ensurePeriod(DateTime(2026, 2)),
      throwsA(isA<NetworkException>()),
    );
  });

  test('a rejected sign in removes them too', () async {
    await repo.ensurePeriod(DateTime(2026, 2));
    expect(api.tokens.cached('period/2026-02-01'), isNotNull);
    final auth = ApiAuthService(api);
    auth.expire();
    await Future<void>.delayed(Duration.zero);
    expect(api.tokens.cached('period/2026-02-01'), isNull);
  });

  test('a damaged kept answer is a network failure, not a crash', () async {
    await api.tokens.cache('period/2026-02-01', '{not json');
    online = false;
    await expectLater(
      repo.ensurePeriod(DateTime(2026, 2)),
      throwsA(isA<NetworkException>()),
    );
  });
}
