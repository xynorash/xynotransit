import 'package:flutter_test/flutter_test.dart';
import 'package:xynotransit_app/data/api/api_client.dart';
import 'package:xynotransit_app/data/api/api_models.dart';
import 'package:xynotransit_app/data/repository.dart';
import 'package:xynotransit_app/domain/admin.dart';
import 'package:xynotransit_app/domain/period.dart';
import 'package:xynotransit_app/domain/summary.dart';
import 'package:xynotransit_app/domain/enums.dart';
import 'package:xynotransit_app/domain/report.dart';

Map<String, dynamic> catalogJson() => {
  'teams': [
    {'id': '2', 'code': 'ops', 'name': 'Operations', 'sort': 2},
    {'id': '1', 'code': 'cs', 'name': 'Customer Service', 'sort': 1},
  ],
  'persons': [
    {
      'id': 'p1',
      'full_name': 'Rova',
      'email': 'rova@x.example',
      'app_role': 'controller',
    },
    {
      'id': 'p2',
      'full_name': 'Mina',
      'email': null,
      'app_role': 'contributor',
      'active': false,
    },
  ],
  'assignments': [
    {
      'id': 'a2',
      'code': 'mina',
      'person_id': 'p2',
      'team_id': '1',
      'role_title': 'Agent',
      'active': false,
      'sort': 2,
      'metrics': <Object?>[],
      'kpis': <Object?>[],
    },
    {
      'id': 'a1',
      'code': 'rova',
      'person_id': 'p1',
      'team_id': '2',
      'role_title': 'Import',
      'sort': 1,
      'metrics': [
        {'id': 'm1', 'key': 'exports', 'label': 'Exports', 'series': 1},
        {'id': 'm0', 'key': 'imports', 'label': 'Imports', 'series': 0},
      ],
      'kpis': [
        {'id': 'k2', 'sort': 2, 'text': 'Second'},
        {'id': 'k1', 'sort': 1, 'text': 'First'},
      ],
    },
  ],
};

Map<String, dynamic> reportJson() => {
  'id': 'r1',
  'period_id': 'per1',
  'assignment_id': 'a1',
  'status': 'submitted',
  'submitted_at': '2026-05-04T10:30:00+03:00',
  'values': [
    {'metric_def_id': 'm0', 'month_offset': 0, 'value': 5},
    // month 1 missing for m0 (gap)
    {'metric_def_id': 'm0', 'month_offset': 2, 'value': 7},
    {'metric_def_id': 'm1', 'month_offset': 1, 'value': 0},
    {'metric_def_id': 'm1', 'month_offset': 9, 'value': 1}, // out of range
    {'metric_def_id': 'm1', 'month_offset': 0, 'value': null},
  ],
  'kpis': [
    {'kpi_def_id': 'k1', 'status': 'met', 'comment': null},
    {'kpi_def_id': 'k2', 'status': 'partly', 'comment': 'Almost'},
    {'kpi_def_id': 'k3', 'status': 'weird', 'comment': ''},
  ],
  'notes': [
    {'kind': 'well', 'position': 2, 'text': 'Second'},
    {'kind': 'well', 'position': 1, 'text': 'First'},
    {'kind': 'next', 'position': 1, 'text': 'Plan'},
    {'kind': 'other', 'position': 1, 'text': 'Dropped'},
  ],
};

void main() {
  test('request bodies: trimmed, lowercased, ids only when known', () {
    expect(teamToJson('  Tana '), {'name': 'Tana'});
    expect(
      personToJson(
        fullName: ' Mina ',
        email: ' Mina@X.Example ',
        role: AppRole.controller,
        active: false,
      ),
      {
        'full_name': 'Mina',
        'email': 'mina@x.example',
        'app_role': 'controller',
        'active': false,
      },
    );
    expect(
      assignmentToJson(personId: 'p', teamId: 't', roleTitle: ' Import '),
      {'person_id': 'p', 'team_id': 't', 'role_title': 'Import'},
    );
    expect(
      definitionsToJson(
        metrics: const [
          MetricInput(id: 'm1', label: ' Sea '),
          MetricInput(label: 'Air'),
        ],
        kpis: const [
          KpiInput(text: ' On time '),
          KpiInput(id: 'k1', text: 'Safe'),
        ],
      ),
      {
        'metrics': [
          {'id': 'm1', 'label': 'Sea'},
          {'label': 'Air'},
        ],
        'kpis': [
          {'text': 'On time'},
          {'id': 'k1', 'text': 'Safe'},
        ],
      },
    );
  });

  test('summary parses and an unreadable one is a readable failure', () {
    final s = Summary(
      periodId: 'p',
      periodLabel: 'Feb to Apr 2026',
      months: Period(id: 'p', startMonth: DateTime(2026, 2)).months,
      expected: 2,
      submitted: 1,
      teams: const [
        TeamSummary(
          teamId: 't',
          name: 'Tana',
          expected: 2,
          submitted: 1,
          met: 3,
          partly: 1,
          missed: 0,
          volumeByMonth: [1, 2, 3],
        ),
      ],
      metrics: const [
        MetricSummary(
          label: 'Sea',
          total: 6,
          byMonth: [1, 2, 3],
          byTeam: [(team: 'Tana', total: 6)],
        ),
      ],
      trend: [
        TrendPoint(
          periodId: 'p',
          label: 'Feb to Apr 2026',
          startMonth: DateTime(2026, 2),
          expected: 2,
          submitted: 1,
          met: 3,
          partly: 1,
          missed: 0,
          volumeTotal: 6,
        ),
      ],
      people: const [],
    );
    final back = parseSummary(s.toJson());
    expect(back.toJson(), s.toJson());
    expect(
      () => parseSummary({'period_id': 'p'}),
      throwsA(isA<RepositoryException>()),
    );
    expect(() => parseSummary(null), throwsA(isA<RepositoryException>()));
  });

  test('catalog: ids as strings, ordering, active flags', () {
    final c = parseCatalog(catalogJson());
    expect(c.teams.map((t) => t.id), ['1', '2']);
    expect(c.persons[0].appRole, AppRole.controller);
    expect(c.persons[1].email, isNull);
    expect(c.persons[0].active, isTrue); // missing flag reads as active
    expect(c.persons[1].active, isFalse);
    expect(c.assignmentByCode('mina')!.active, isFalse);
    expect(c.assignmentByCode('rova')!.active, isTrue);
    // Deck order: team sort first.
    expect(c.assignments.map((a) => a.code), ['mina', 'rova']);
    final rova = c.assignmentByCode('rova')!;
    expect(rova.teamId, '2');
    expect(rova.metrics.map((m) => m.key), ['imports', 'exports']);
    expect(rova.kpis.map((k) => k.text), ['First', 'Second']);
    expect(c.assignmentByCode('mina')!.hasCounts, isFalse);
  });

  test('catalog accepts a numeric team id and empty lists', () {
    final j = catalogJson();
    (j['teams'] as List<dynamic>)[0]['id'] = 2;
    expect(parseCatalog(j).teams.last.id, '2');
    final empty = parseCatalog({
      'teams': <Object?>[],
      'persons': <Object?>[],
      'assignments': <Object?>[],
    });
    expect(empty.assignments, isEmpty);
    expect(parseCatalog(<String, dynamic>{}).teams, isEmpty);
  });

  test('catalog that is not an object is a readable failure', () {
    expect(() => parseCatalog([1]), throwsA(isA<RepositoryException>()));
    expect(() => parseCatalog(null), throwsA(isA<RepositoryException>()));
  });

  test('period with and without meeting date', () {
    final p = parsePeriod({
      'id': 'per1',
      'start_month': '2026-02-01',
      'meeting_date': '2026-06-09',
      'status': 'open',
    });
    expect(p.startMonth, DateTime(2026, 2));
    expect(p.meetingDate, DateTime(2026, 6, 9));
    final q = parsePeriod({
      'id': 'per2',
      'start_month': '2026-11-01',
      'meeting_date': null,
      'status': 'closed',
    });
    expect(q.meetingDate, isNull);
    expect(q.status, PeriodStatus.closed);
    expect(q.label, 'Nov 2026 to Jan 2027');
  });

  test('report: gaps stay null, bad rows are skipped, notes ordered', () {
    final r = parseReport(reportJson());
    expect(r.id, 'r1');
    expect(r.isSubmitted, isTrue);
    expect(r.submittedAt, DateTime.utc(2026, 5, 4, 7, 30).toLocal());
    expect(r.values['m0'], [5, null, 7]);
    expect(r.values['m1'], [null, 0, null]);
    expect(r.kpis['k1']!.status, KpiStatus.met);
    expect(r.kpis['k1']!.comment, isNull);
    expect(r.kpis['k2']!.comment, 'Almost');
    expect(r.kpis.containsKey('k3'), isFalse);
    expect(r.notesOf(NoteKind.well), ['First', 'Second']);
    expect(r.notesOf(NoteKind.next), ['Plan']);
    expect(r.notesOf(NoteKind.wrong), isEmpty);
  });

  test('report: draft with nulls and empty lists', () {
    final r = parseReport({
      'id': 'r2',
      'period_id': 'per1',
      'assignment_id': 'a1',
      'status': 'draft',
      'submitted_at': null,
      'values': <Object?>[],
      'kpis': <Object?>[],
      'notes': <Object?>[],
    });
    expect(r.isSubmitted, isFalse);
    expect(r.submittedAt, isNull);
    expect(r.values, isEmpty);
    expect(r.noteCount, 0);
    expect(parseReports(null), isEmpty);
    expect(parseReports([reportJson(), reportJson()]), hasLength(2));
  });

  test('reportToJson sends typed numbers only, with positions', () {
    final r = Report(
      periodId: 'per1',
      assignmentId: 'a1',
      values: {
        'm0': [1, null, 3],
      },
      kpis: {
        'k1': const KpiResult(KpiStatus.missed, comment: '  late  '),
        'k2': const KpiResult(KpiStatus.met, comment: '  '),
      },
      notes: {
        NoteKind.well: ['A', 'B'],
        NoteKind.wrong: <String>[],
        NoteKind.next: ['C'],
      },
    );
    final j = reportToJson(r);
    expect(j['values'], [
      {'metric_def_id': 'm0', 'month_offset': 0, 'value': 1},
      {'metric_def_id': 'm0', 'month_offset': 2, 'value': 3},
    ]);
    expect(j['kpis'], [
      {'kpi_def_id': 'k1', 'status': 'missed', 'comment': 'late'},
      {'kpi_def_id': 'k2', 'status': 'met', 'comment': null},
    ]);
    expect(j['notes'], [
      {'kind': 'well', 'position': 1, 'text': 'A'},
      {'kind': 'well', 'position': 2, 'text': 'B'},
      {'kind': 'next', 'position': 1, 'text': 'C'},
    ]);
  });

  test('deck: null, and a run with items out of order', () {
    expect(parseDeckOrNull(null), isNull);
    final snap = {
      'assignmentCode': 'rova',
      'name': 'Rova',
      'role': 'Import',
      'team': 'Operations',
      'periodLabel': 'Feb to Apr 2026',
      'months': [
        {'offset': 0, 'year': 2026, 'month': 2, 'short': 'Feb'},
        {'offset': 1, 'year': 2026, 'month': 3, 'short': 'Mar'},
        {'offset': 2, 'year': 2026, 'month': 4, 'short': 'Apr'},
      ],
      'metrics': [
        {
          'key': 'imports',
          'label': 'Imports',
          'series': 0,
          'values': [1, 2, 3],
        },
      ],
      'targets': [
        {'text': 'First', 'status': 'met'},
        {'text': 'Second', 'status': null},
      ],
      'well': ['A'],
      'wrong': <Object?>[],
      'next': ['B', 'C'],
    };
    final d = parseDeck({
      'id': 'd1',
      'period_id': 'per1',
      'generated_at': '2026-06-01T08:00:00Z',
      'expected_count': 14,
      'included_count': 2,
      'items': [
        {'report_id': 'r2', 'sort': 1, 'snapshot': snap},
        {'report_id': 'r1', 'sort': 0, 'snapshot': snap},
      ],
    });
    expect(d.expectedCount, 14);
    expect(d.items.map((i) => i.reportId), ['r1', 'r2']);
    final s = d.items.first.snapshot;
    expect(s.months[1].short, 'Mar');
    expect(s.metrics.single.values, [1, 2, 3]);
    expect(s.targets[1].status, isNull);
    expect(s.next, ['B', 'C']);
    expect(d.generatedAt, DateTime.utc(2026, 6, 1, 8).toLocal());
    final empty = parseDeck({
      'id': 'd2',
      'period_id': 'per1',
      'generated_at': '2026-06-01T08:00:00Z',
      'expected_count': 14,
      'included_count': 0,
      'items': <Object?>[],
    });
    expect(empty.items, isEmpty);
  });

  test('user and role', () {
    final u = parseUser({
      'person_id': 'p1',
      'role': 'controller',
      'label': 'Rova',
    });
    expect(u.isController, isTrue);
    expect(parseUser(userToJson(u)).label, 'Rova');
    final anon = parseUser({'person_id': null, 'role': 'contributor'});
    expect(anon.personId, isNull);
    expect(anon.isController, isFalse);
    expect(anon.label, 'Signed in');
  });

  group('error mapping', () {
    test('uses the server words', () {
      final e = errorFromResponse(403, '{"error":"This period is closed."}');
      expect(e.statusCode, 403);
      expect(e.message, 'This period is closed.');
    });
    test('401 is unauthorized', () {
      expect(
        errorFromResponse(401, '{"error":"Nope."}'),
        isA<UnauthorizedException>(),
      );
    });
    test('falls back to plain words for HTML, empty or odd bodies', () {
      for (final body in [
        '<html>bad gateway</html>',
        '',
        '{"error":""}',
        '[]',
      ]) {
        final e = errorFromResponse(502, body);
        expect(e.message, fallbackMessage(502));
        expect(e.message, isNot(contains('html')));
      }
      expect(errorFromResponse(429, '').message, contains('Too many'));
    });
  });
}
