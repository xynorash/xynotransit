import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:xynotransit_app/data/api/api_client.dart';
import 'package:xynotransit_app/data/api/api_models.dart';
import 'package:xynotransit_app/data/api/api_repository.dart';
import 'package:xynotransit_app/data/repository.dart';
import 'package:xynotransit_app/data/seed_data.dart';
import 'package:xynotransit_app/domain/admin.dart';
import 'package:xynotransit_app/domain/deck_text.dart';
import 'package:xynotransit_app/domain/enums.dart';
import 'package:xynotransit_app/domain/period.dart';
import 'package:xynotransit_app/domain/report.dart';

import 'api_client_test.dart' show clientFor, json;
import 'api_models_test.dart' show catalogJson, reportJson;

Future<ApiRepository> repoFor(
  MockClientHandler h, {
  String? token = 'tok',
}) async => ApiRepository(
  await clientFor(h, token: token),
  useDefaultSse: false,
  pollInterval: const Duration(milliseconds: 40),
);

Report sample() => Report(
  periodId: 'per1',
  assignmentId: 'a1',
  values: {
    'm0': [1, 2, 3],
  },
  kpis: {'k1': const KpiResult(KpiStatus.met)},
  notes: {
    NoteKind.well: ['A'],
    NoteKind.wrong: <String>[],
    NoteKind.next: <String>[],
  },
);

void main() {
  test('loadCatalog and ensurePeriod hit the contract paths', () async {
    final seen = <String>[];
    final repo = await repoFor((r) async {
      seen.add('${r.method} ${r.url.path}');
      if (r.url.path == '/api/catalog') return json(catalogJson());
      expect(jsonDecode(r.body), {'start_month': '2026-02-01'});
      return json({
        'id': 'per1',
        'start_month': '2026-02-01',
        'meeting_date': null,
        'status': 'open',
      });
    });
    final c = await repo.loadCatalog();
    expect(c.assignments, hasLength(2));
    final p = await repo.ensurePeriod(DateTime(2026, 2, 17));
    expect(p.id, 'per1');
    expect(seen, ['GET /api/catalog', 'POST /api/periods/ensure']);
  });

  test('ensurePeriod sends the first of the month', () async {
    late Object? body;
    final repo = await repoFor((r) async {
      body = jsonDecode(r.body);
      return json({
        'id': 'p',
        'start_month': '2026-02-01',
        'meeting_date': null,
        'status': 'open',
      });
    });
    await repo.ensurePeriod(DateTime(2026, 2));
    expect(body, {'start_month': '2026-02-01'});
  });

  test('setMeetingDate patches with a date or null; 403 is readable', () async {
    final bodies = <Object?>[];
    var deny = false;
    final repo = await repoFor((r) async {
      expect(r.method, 'PATCH');
      expect(r.url.path, '/api/periods/per1');
      bodies.add(jsonDecode(r.body));
      return deny
          ? json({'error': 'Only the manager can do this.'}, 403)
          : json({
              'id': 'per1',
              'start_month': '2026-02-01',
              'meeting_date': null,
              'status': 'open',
            });
    });
    await repo.setMeetingDate('per1', DateTime(2026, 6, 9));
    await repo.setMeetingDate('per1', null);
    expect(bodies, [
      {'meeting_date': '2026-06-09'},
      {'meeting_date': null},
    ]);
    deny = true;
    await expectLater(
      repo.setMeetingDate('per1', null),
      throwsA(
        isA<RepositoryException>().having(
          (e) => e.message,
          'm',
          'Only the manager can do this.',
        ),
      ),
    );
  });

  test(
    'sendReport PUTs the contract shape and returns the saved report',
    () async {
      late http.Request seen;
      final repo = await repoFor((r) async {
        seen = r;
        return json(reportJson());
      });
      final saved = await repo.sendReport(sample());
      expect(seen.method, 'PUT');
      expect(seen.url.path, '/api/periods/per1/reports/a1');
      expect(seen.headers['Authorization'], 'Bearer tok');
      expect(jsonDecode(seen.body), {
        'values': [
          {'metric_def_id': 'm0', 'month_offset': 0, 'value': 1},
          {'metric_def_id': 'm0', 'month_offset': 1, 'value': 2},
          {'metric_def_id': 'm0', 'month_offset': 2, 'value': 3},
        ],
        'kpis': [
          {'kpi_def_id': 'k1', 'status': 'met', 'comment': null},
        ],
        'notes': [
          {'kind': 'well', 'position': 1, 'text': 'A'},
        ],
      });
      expect(saved.id, 'r1');
      expect(saved.isSubmitted, isTrue);
    },
  );

  for (final c in [
    (403, 'You can only send your own report.'),
    (403, 'This period is closed.'),
    (400, 'Enter a number for "Imports" in March.'),
    (400, 'Answer all targets in step 3 (2 left).'),
    (429, 'Too many links requested. Try again later.'),
  ]) {
    test('sendReport surfaces ${c.$1}: ${c.$2}', () async {
      final repo = await repoFor((r) async => json({'error': c.$2}, c.$1));
      await expectLater(
        repo.sendReport(sample()),
        throwsA(isA<RepositoryException>().having((e) => e.message, 'm', c.$2)),
      );
    });
  }

  test('network failure becomes NetworkException', () async {
    final repo = await repoFor((r) async => throw http.ClientException('x'));
    await expectLater(
      repo.sendReport(sample()),
      throwsA(isA<NetworkException>()),
    );
    await expectLater(repo.loadCatalog(), throwsA(isA<NetworkException>()));
  });

  test('getReport: report, and 404 means null', () async {
    var found = true;
    final repo = await repoFor((r) async {
      expect(r.url.path, '/api/periods/per1/reports/a1');
      return found ? json(reportJson()) : json({'error': 'Not found.'}, 404);
    });
    expect((await repo.getReport('per1', 'a1'))!.id, 'r1');
    found = false;
    expect(await repo.getReport('per1', 'a1'), isNull);
  });

  test('getReport rethrows other failures', () async {
    final repo = await repoFor((r) async => json({'error': 'Boom.'}, 500));
    await expectLater(
      repo.getReport('per1', 'a1'),
      throwsA(isA<ApiException>()),
    );
  });

  test('generateDeck posts and parses; non manager gets 403 words', () async {
    var deny = false;
    final repo = await repoFor((r) async {
      expect(r.method, 'POST');
      expect(r.url.path, '/api/periods/per1/deck');
      if (deny) {
        return json({'error': 'Only the manager can do this.'}, 403);
      }
      return json({
        'id': 'd1',
        'period_id': 'per1',
        'generated_at': '2026-06-01T08:00:00Z',
        'expected_count': 14,
        'included_count': 0,
        'items': <Object?>[],
      }, 201);
    });
    final period = Period(id: 'per1', startMonth: DateTime(2026, 2));
    final catalog = buildSeedCatalog();
    expect((await repo.generateDeck(period, catalog)).id, 'd1');
    deny = true;
    await expectLater(
      repo.generateDeck(period, catalog),
      throwsA(
        isA<RepositoryException>().having(
          (e) => e.message,
          'm',
          'Only the manager can do this.',
        ),
      ),
    );
  });

  test(
    'watchReports loads, then polls when there is no live connection',
    () async {
      var n = 0;
      final repo = await repoFor((r) async {
        if (r.url.path == '/api/periods/per1/reports') {
          n++;
          return json(n == 1 ? [] : [reportJson()]);
        }
        return json({}, 500);
      });
      final got = <int>[];
      final sub = repo.watchReports('per1').listen((l) => got.add(l.length));
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await sub.cancel();
      expect(got.first, 0);
      expect(got, contains(1));
    },
  );

  test('watchReports keeps the last list when a refetch fails', () async {
    var n = 0;
    final repo = await repoFor((r) async {
      n++;
      if (n == 1) return json([reportJson()]);
      throw http.ClientException('down');
    });
    final got = <int>[];
    final errors = <Object>[];
    final sub = repo
        .watchReports('per1')
        .listen((l) => got.add(l.length), onError: errors.add);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await sub.cancel();
    expect(got, [1]);
    expect(errors, isEmpty);
    expect(n, greaterThan(1));
  });

  test('watchReports fails loudly when the first load fails', () async {
    final repo = await repoFor((r) async => throw http.ClientException('down'));
    await expectLater(
      repo.watchReports('per1'),
      emitsError(isA<NetworkException>()),
    );
  });

  test('watchDeck emits null for JSON null', () async {
    final repo = await repoFor((r) async => http.Response('null', 200));
    final first = await repo.watchDeck('per1').first;
    expect(first, isNull);
  });

  group('manager calls', () {
    Map<String, dynamic> seatJson({String id = 'a9', bool active = true}) => {
      'id': id,
      'code': 'new-seat',
      'person_id': 'p1',
      'team_id': '1',
      'role_title': 'Import',
      'sort': 3,
      'active': active,
      'metrics': [
        {'id': 'm1', 'key': 'sea', 'label': 'Sea', 'series': 0},
        {'id': 'm2', 'key': 'air', 'label': 'Air', 'series': 1},
      ],
      'kpis': [
        {'id': 'k1', 'sort': 1, 'text': 'On time'},
      ],
    };

    test('loadCatalog asks for inactive rows only when told to', () async {
      final seen = <Uri>[];
      final repo = await repoFor((r) async {
        seen.add(r.url);
        return json(catalogJson());
      });
      await repo.loadCatalog();
      await repo.loadCatalog(includeInactive: true);
      expect(seen[0].query, isEmpty);
      expect(seen[1].queryParameters, {'include_inactive': 'true'});
    });

    test('saveTeam creates with POST and renames with PATCH', () async {
      final seen = <String>[];
      final repo = await repoFor((r) async {
        seen.add('${r.method} ${r.url.path} ${r.body}');
        return json({'id': 't1', 'code': 'tana', 'name': 'Tana', 'sort': 2});
      });
      final t = await repo.saveTeam(name: ' Tana ');
      expect(t.code, 'tana');
      await repo.saveTeam(id: 't1', name: 'Tana');
      expect(seen, [
        'POST /api/teams {"name":"Tana"}',
        'PATCH /api/teams/t1 {"name":"Tana"}',
      ]);
    });

    test('deleteTeam sends DELETE; the 409 text reaches the caller', () async {
      var refuse = false;
      final repo = await repoFor((r) async {
        expect(r.method, 'DELETE');
        expect(r.url.path, '/api/teams/t1');
        return refuse
            ? json({
                'error': 'Move or remove the seats of this team first.',
              }, 409)
            : http.Response('', 204);
      });
      await repo.deleteTeam('t1');
      refuse = true;
      await expectLater(
        repo.deleteTeam('t1'),
        throwsA(
          isA<RepositoryException>().having(
            (e) => e.message,
            'message',
            'Move or remove the seats of this team first.',
          ),
        ),
      );
    });

    test(
      'savePerson: POST for new, PATCH for existing, 409 readable',
      () async {
        final seen = <String>[];
        var clash = false;
        final repo = await repoFor((r) async {
          seen.add('${r.method} ${r.url.path} ${r.body}');
          if (clash) return json({'error': 'That email is already used.'}, 409);
          return json({
            'id': 'p7',
            'full_name': 'Mina',
            'email': 'mina@x.example',
            'app_role': 'controller',
            'active': true,
          });
        });
        final p = await repo.savePerson(
          fullName: 'Mina',
          email: 'Mina@X.example',
          role: AppRole.controller,
        );
        expect(p.appRole, AppRole.controller);
        await repo.savePerson(
          id: 'p7',
          fullName: 'Mina',
          email: 'mina@x.example',
          role: AppRole.contributor,
          active: false,
        );
        expect(
          seen[0],
          'POST /api/persons {"full_name":"Mina","email":"mina@x.example","app_role":"controller"}',
        );
        expect(seen[1], startsWith('PATCH /api/persons/p7 '));
        expect(jsonDecode(seen[1].split(' ').skip(2).join(' ')), {
          'full_name': 'Mina',
          'email': 'mina@x.example',
          'app_role': 'contributor',
          'active': false,
        });
        clash = true;
        await expectLater(
          repo.savePerson(
            fullName: 'Other',
            email: 'mina@x.example',
            role: AppRole.contributor,
          ),
          throwsA(
            isA<RepositoryException>().having(
              (e) => e.message,
              'message',
              'That email is already used.',
            ),
          ),
        );
      },
    );

    test('a new inactive person is created, then switched off', () async {
      final seen = <String>[];
      final repo = await repoFor((r) async {
        seen.add('${r.method} ${r.url.path}');
        return json({
          'id': 'p7',
          'full_name': 'Mina',
          'email': 'm@x.example',
          'app_role': 'contributor',
          'active': r.method == 'POST',
        });
      });
      final p = await repo.savePerson(
        fullName: 'Mina',
        email: 'm@x.example',
        role: AppRole.contributor,
        active: false,
      );
      expect(seen, ['POST /api/persons', 'PATCH /api/persons/p7']);
      expect(p.active, isFalse);
    });

    test(
      'saveAssignment: POST new, PATCH existing, duplicate is readable',
      () async {
        final seen = <String>[];
        var clash = false;
        final repo = await repoFor((r) async {
          seen.add('${r.method} ${r.url.path} ${r.body}');
          if (clash) {
            return json({
              'error': 'That person already has this role in this team.',
            }, 409);
          }
          return json(seatJson());
        });
        final a = await repo.saveAssignment(
          personId: 'p1',
          teamId: '1',
          roleTitle: ' Import ',
        );
        expect(a.metrics.map((m) => m.label), ['Sea', 'Air']);
        await repo.saveAssignment(
          id: 'a9',
          personId: 'p1',
          teamId: '2',
          roleTitle: 'Export',
          active: false,
        );
        expect(
          seen[0],
          'POST /api/assignments {"person_id":"p1","team_id":"1","role_title":"Import"}',
        );
        expect(
          seen[1],
          'PATCH /api/assignments/a9 {"team_id":"2","role_title":"Export","active":false}',
        );
        clash = true;
        await expectLater(
          repo.saveAssignment(personId: 'p1', teamId: '1', roleTitle: 'Import'),
          throwsA(
            isA<RepositoryException>().having(
              (e) => e.message,
              'message',
              'That person already has this role in this team.',
            ),
          ),
        );
      },
    );

    test('saveDefinitions PUTs ids and labels and parses the seat', () async {
      late http.Request seen;
      final repo = await repoFor((r) async {
        seen = r;
        return json(seatJson());
      });
      final a = await repo.saveDefinitions(
        'a9',
        metrics: const [
          MetricInput(id: 'm1', label: 'Sea'),
          MetricInput(label: 'Air'),
        ],
        kpis: const [KpiInput(id: 'k1', text: 'On time')],
      );
      expect(seen.method, 'PUT');
      expect(seen.url.path, '/api/assignments/a9/definitions');
      expect(jsonDecode(seen.body), {
        'metrics': [
          {'id': 'm1', 'label': 'Sea'},
          {'label': 'Air'},
        ],
        'kpis': [
          {'id': 'k1', 'text': 'On time'},
        ],
      });
      expect(a.metrics, hasLength(2));
      expect(a.kpis.single.text, 'On time');
    });

    test('saveDefinitions shows the server words for a bad label', () async {
      final repo = await repoFor(
        (r) async => json({'error': 'Two counts have the same name.'}, 400),
      );
      await expectLater(
        repo.saveDefinitions(
          'a9',
          metrics: const [
            MetricInput(label: 'A'),
            MetricInput(label: 'a'),
          ],
          kpis: const [],
        ),
        throwsA(
          isA<RepositoryException>().having(
            (e) => e.message,
            'message',
            'Two counts have the same name.',
          ),
        ),
      );
    });

    test('loadSummary sends period and trend and parses', () async {
      late Uri seen;
      final repo = await repoFor((r) async {
        seen = r.url;
        return json({
          'period_id': 'per1',
          'period_label': 'Feb to Apr 2026',
          'months': [
            {'offset': 0, 'year': 2026, 'month': 2, 'short': 'Feb'},
          ],
          'expected': 3,
          'submitted': 2,
          'teams': <Object?>[],
          'metrics': <Object?>[],
          'trend': <Object?>[],
          'people': <Object?>[],
        });
      });
      final s = await repo.loadSummary('per1', trend: 4);
      expect(seen.path, '/api/summary');
      expect(seen.queryParameters, {'period_id': 'per1', 'trend': '4'});
      expect(s.expected, 3);
      expect(s.months.single.short, 'Feb');
    });

    test('loadSummary: 403 is readable', () async {
      final repo = await repoFor(
        (r) async => json({'error': 'Only managers can see the summary.'}, 403),
      );
      await expectLater(
        repo.loadSummary('per1'),
        throwsA(isA<RepositoryException>()),
      );
    });

    test('watchCatalog emits again after an admin write', () async {
      var teams = 1;
      final repo = await repoFor((r) async {
        if (r.url.path == '/api/catalog') {
          return json({
            'teams': [
              for (var i = 0; i < teams; i++)
                {'id': 't$i', 'code': 'c$i', 'name': 'T$i', 'sort': i},
            ],
            'persons': <Object?>[],
            'assignments': <Object?>[],
          });
        }
        teams++;
        return json({'id': 't1', 'code': 'c1', 'name': 'T1', 'sort': 1});
      });
      final got = <int>[];
      final sub = repo.watchCatalog().listen((c) => got.add(c.teams.length));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await repo.saveTeam(name: 'T1');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await sub.cancel();
      expect(got, [1, 2]);
    });
  });

  test(
    'the people list is read again after a password reset or removal',
    () async {
      var reads = 0;
      final repo = await repoFor((r) async {
        if (r.url.path == '/api/catalog') {
          reads++;
          return json({
            'teams': <Object?>[],
            'persons': <Object?>[],
            'assignments': <Object?>[],
          });
        }
        if (r.method == 'DELETE') return json(<String, Object?>{}, 204);
        return json({'username': 'a', 'temporary_password': 'b'}, 201);
      });
      final sub = repo.watchCatalog().listen((_) {});
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final first = reads;
      await repo.resetPassword('p1');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(reads, first + 1);
      await repo.removePassword('p1');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(reads, first + 2);
      await sub.cancel();
    },
  );

  group('deck texts', () {
    test('loadDeckTexts parses settings and inherited_from', () async {
      final repo = await repoFor((r) async {
        expect(r.method, 'GET');
        expect(r.url.path, '/api/periods/per1/deck-text');
        return json({
          'settings': {...DeckTexts.defaults.toJson(), 'title': 'Board'},
          'inherited_from': 'Feb to Apr 2026',
          'updated_at': null,
        });
      });
      final s = await repo.loadDeckTexts('per1');
      expect(s.texts['title'], 'Board');
      expect(s.texts['footer'], DeckTexts.defaults['footer']);
      expect(s.inheritedFrom, 'Feb to Apr 2026');
    });

    test('saveDeckTexts puts every key and parses the answer', () async {
      final repo = await repoFor((r) async {
        expect(r.method, 'PUT');
        expect(r.url.path, '/api/periods/per1/deck-text');
        final body = jsonDecode(r.body) as Map<String, dynamic>;
        expect((body['settings'] as Map).keys, [
          for (final f in deckTextFields) f.key,
        ]);
        expect(body['settings']['title'], 'Mine');
        return json({
          'settings': body['settings'],
          'inherited_from': null,
          'updated_at': '2026-06-01T08:00:00Z',
        });
      });
      final s = await repo.saveDeckTexts(
        'per1',
        DeckTexts.defaults.withValue('title', 'Mine'),
      );
      expect(s.texts['title'], 'Mine');
      expect(s.inheritedFrom, isNull);
    });

    test('errors surface as RepositoryException with the words', () async {
      final repo = await repoFor(
        (r) async => json({'error': 'Meeting title cannot be empty.'}, 400),
      );
      await expectLater(
        repo.saveDeckTexts('per1', DeckTexts.defaults),
        throwsA(
          isA<RepositoryException>().having(
            (e) => e.message,
            'm',
            'Meeting title cannot be empty.',
          ),
        ),
      );
    });

    test('deck json: texts parsed, missing means defaults', () {
      Map<String, Object?> deck([Object? texts]) => {
        'id': 'd',
        'period_id': 'p',
        'generated_at': '2026-06-01T08:00:00Z',
        'expected_count': 1,
        'included_count': 0,
        'items': <Object?>[],
        'texts': ?texts,
      };
      expect(parseDeck(deck()).texts, DeckTexts.defaults);
      expect(parseDeck(deck(<String, Object?>{})).texts, DeckTexts.defaults);
      final t = parseDeck(deck({'title': 'Old words'})).texts;
      expect(t['title'], 'Old words');
      expect(t['subtitle'], DeckTexts.defaults['subtitle']);
    });
  });
}
