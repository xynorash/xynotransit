// A real company: 500 people, 1,000 reports. These are microbenchmarks with
// generous limits: they catch an accidental O(n squared) or a huge copy, not
// a few milliseconds. The numbers are printed so a run shows the real cost.
import 'package:flutter_test/flutter_test.dart';
import 'package:xynotransit_app/data/api/api_models.dart';
import 'package:xynotransit_app/data/memory_repository.dart';
import 'package:xynotransit_app/domain/catalog.dart';
import 'package:xynotransit_app/domain/deck.dart';
import 'package:xynotransit_app/domain/enums.dart';
import 'package:xynotransit_app/domain/period.dart';
import 'package:xynotransit_app/domain/report.dart';
import 'package:xynotransit_app/domain/snapshot.dart';
import 'package:xynotransit_app/domain/summary_compute.dart';

const people = 500;
const teamCount = 10;

Catalog bigCatalog({int n = people}) {
  final teams = [
    for (var t = 0; t < teamCount; t++)
      Team(id: 't$t', code: 'team-$t', name: 'Team $t', sort: t + 1),
  ];
  final persons = [
    for (var i = 0; i < n; i++)
      Person(id: 'p$i', fullName: 'Person $i', email: 'p$i@x.example'),
  ];
  final seats = [
    for (var i = 0; i < n; i++)
      Assignment(
        id: 'a$i',
        code: 'seat-$i',
        personId: 'p$i',
        teamId: 't${i % teamCount}',
        roleTitle: 'Role ${i % 7}',
        sort: i ~/ teamCount + 1,
        metrics: [
          for (var m = 0; m < 8; m++)
            MetricDef(id: 'a$i/m$m', key: 'm$m', label: 'Count $m', series: m),
        ],
        kpis: [
          for (var k = 0; k < 10; k++)
            KpiDef(id: 'a$i/k$k', sort: k + 1, text: 'Target $k of seat $i'),
        ],
      ),
  ];
  return Catalog(teams: teams, persons: persons, assignments: seats);
}

Report reportFor(Assignment a, String periodId, int salt) => Report(
  id: 'r-$periodId-${a.id}',
  periodId: periodId,
  assignmentId: a.id,
  status: ReportStatus.submitted,
  submittedAt: DateTime(2026, 5, 6, 9),
  values: {
    for (final m in a.metrics)
      m.id: [1000000000, 1000000000 - salt, salt % 1000],
  },
  kpis: {
    for (final (i, k) in a.kpis.indexed)
      k.id: KpiResult(KpiStatus.values[(i + salt) % 3]),
  },
  notes: {
    NoteKind.well: ['Went well $salt'],
    NoteKind.wrong: ['Went wrong'],
    NoteKind.next: ['Next', 'Then'],
  },
  reporter: Reporter(
    name: 'Person ${a.personId}',
    country: 'Country ${salt % 12}',
    role: a.roleTitle,
  ),
);

/// Runs [f], prints the time, and fails when it takes longer than [limit].
T timed<T>(String what, Duration limit, T Function() f) {
  final sw = Stopwatch()..start();
  final v = f();
  sw.stop();
  // ignore: avoid_print
  print(
    'scale: $what took ${sw.elapsedMilliseconds} ms (limit ${limit.inMilliseconds} ms)',
  );
  expect(sw.elapsed, lessThan(limit), reason: what);
  return v;
}

void main() {
  late final Catalog cat;
  late final Period p0;
  late final Period p1;
  late final List<Report> r0;
  late final List<Report> r1;
  setUpAll(() {
    cat = bigCatalog();
    p0 = Period(id: 'p0', startMonth: DateTime(2026, 2));
    p1 = Period(id: 'p1', startMonth: DateTime(2026, 5));
    r0 = [for (final (i, a) in cat.assignments.indexed) reportFor(a, 'p0', i)];
    r1 = [
      for (final (i, a) in cat.assignments.indexed) reportFor(a, 'p1', i + 1),
    ];
  });

  test(
    'a catalog of $people seats with 8 counts and 10 targets builds fast',
    () {
      timed('build the catalog', const Duration(seconds: 2), bigCatalog);
    },
  );

  test('lookups by id cost one step', () {
    timed(
      '2 x 500 lookups by id, person, team',
      const Duration(milliseconds: 200),
      () {
        for (final a in cat.assignments) {
          expect(cat.assignmentById(a.id), same(a));
          cat.personOf(a);
          cat.teamOf(a);
          cat.assignmentByCode(a.code);
        }
        for (final t in cat.teams) {
          expect(cat.assignmentsOfTeam(t), hasLength(people ~/ teamCount));
        }
        for (final p in cat.persons) {
          expect(cat.assignmentsOfPerson(p.id), hasLength(1));
        }
      },
    );
    // And the cost does not grow with the square: 4 times the people, about
    // 4 times the work (we allow 12).
    int work(int n) {
      final c = bigCatalog(n: n);
      final sw = Stopwatch()..start();
      for (var rep = 0; rep < 20; rep++) {
        for (final a in c.assignments) {
          c.personOf(a);
          c.teamOf(a);
          c.assignmentById(a.id);
        }
      }
      return sw.elapsedMicroseconds + 1;
    }

    work(50); // warm up
    final small = work(250);
    final big = work(1000);
    expect(big / small, lessThan(12), reason: 'small $small us, big $big us');
  });

  test('the summary of $people seats, $teamCount teams, 1,000 reports', () {
    final s = timed(
      'computeSummary',
      const Duration(seconds: 3),
      () => computeSummary(
        period: p1,
        allPeriods: [p0, p1],
        catalog: cat,
        reports: {'p0': r0, 'p1': r1},
      ),
    );
    expect(s.expected, people);
    expect(s.submitted, people);
    expect(s.people, hasLength(people));
    expect(s.trend, hasLength(2));
    expect(s.metrics, hasLength(8));
    // 500 seats x 3 months of up to a billion: far beyond 32 bits, exact in a double.
    expect(s.metrics.first.total, greaterThan(100000000000));
    // Still exact in a JavaScript number (2^53 is about 9e15).
    expect(
      s.metrics.fold(0, (n, m) => n + m.total),
      lessThan(9007199254740992),
    );
  });

  test('snapshots, validation and the deck of 500 reports', () {
    final snaps = timed(
      '500 snapshots',
      const Duration(seconds: 2),
      () => [
        for (final r in r1)
          ReportSnapshot.build(
            report: r,
            assignment: cat.assignmentById(r.assignmentId)!,
            catalog: cat,
            period: p1,
          ),
      ],
    );
    expect(snaps, hasLength(people));
    timed('500 validations', const Duration(seconds: 1), () {
      for (final r in r1) {
        expect(r.validate(cat.assignmentById(r.assignmentId)!, p1), isEmpty);
      }
    });
    final run = DeckRun(
      id: 'd',
      periodId: 'p1',
      generatedAt: DateTime(2026, 8),
      expectedCount: people,
      includedCount: people,
      items: [
        for (final (i, s) in snaps.indexed)
          DeckItem(reportId: 'r$i', sort: i + 1, snapshot: s),
      ],
    );
    final slides = timed(
      'buildDeck',
      const Duration(seconds: 1),
      () => buildDeck(run, p1),
    );
    // cover + (divider per country) + 2 per person + suggestions
    expect(slides.length, 1 + 12 + 2 * people + 1);
  });

  test('the in-memory server: send 1,000 reports, summary, deck', () async {
    final big = bigCatalog();
    final repo = MemoryRepository(
      catalog: big,
      currentUser: () => DemoAuth.controller,
    );
    final a = await repo.ensurePeriod(DateTime(2026, 2));
    final b = await repo.ensurePeriod(DateTime(2026, 5));
    final sw = Stopwatch()..start();
    for (final (i, seat) in big.assignments.indexed) {
      await repo.sendReport(reportFor(seat, a.id, i));
      await repo.sendReport(reportFor(seat, b.id, i + 1));
    }
    // ignore: avoid_print
    print('scale: 1000 sendReport took ${sw.elapsedMilliseconds} ms');
    expect(sw.elapsed, lessThan(const Duration(seconds: 20)));
    sw
      ..reset()
      ..start();
    final summary = await repo.loadSummary(b.id);
    final deck = await repo.generateDeck(b, big);
    // ignore: avoid_print
    print(
      'scale: loadSummary + generateDeck took ${sw.elapsedMilliseconds} ms',
    );
    expect(sw.elapsed, lessThan(const Duration(seconds: 10)));
    expect(summary.submitted, people);
    expect(deck.items, hasLength(people));
  });

  test('parsing 500 reports and a 500 seat catalog from JSON', () {
    final json = {
      'teams': [
        for (final t in cat.teams)
          {'id': t.id, 'code': t.code, 'name': t.name, 'sort': t.sort},
      ],
      'persons': [
        for (final p in cat.persons)
          {
            'id': p.id,
            'full_name': p.fullName,
            'email': p.email,
            'app_role': 'contributor',
            'active': true,
          },
      ],
      'assignments': [
        for (final a in cat.assignments)
          {
            'id': a.id,
            'code': a.code,
            'person_id': a.personId,
            'team_id': a.teamId,
            'role_title': a.roleTitle,
            'sort': a.sort,
            'active': true,
            'metrics': [
              for (final m in a.metrics)
                {
                  'id': m.id,
                  'key': m.key,
                  'label': m.label,
                  'series': m.series,
                },
            ],
            'kpis': [
              for (final k in a.kpis)
                {'id': k.id, 'sort': k.sort, 'text': k.text},
            ],
          },
      ],
    };
    final parsed = timed(
      'parseCatalog',
      const Duration(seconds: 2),
      () => parseCatalog(json),
    );
    expect(parsed.assignments, hasLength(people));
    final rows = [
      for (final r in r1)
        {
          'id': r.id,
          'period_id': 'p1',
          'assignment_id': r.assignmentId,
          'status': 'submitted',
          'submitted_at': '2026-05-06T09:00:00.000Z',
          'reporter': r.reporter!.toJson(),
          'values': [
            for (final e in r.values.entries)
              for (var i = 0; i < 3; i++)
                {
                  'metric_def_id': e.key,
                  'month_offset': i,
                  'value': e.value[i],
                },
          ],
          'kpis': [
            for (final e in r.kpis.entries)
              {
                'kpi_def_id': e.key,
                'status': e.value.status.name,
                'comment': null,
              },
          ],
          'notes': [
            for (final k in NoteKind.values)
              for (final (i, t) in r.notesOf(k).indexed)
                {'kind': k.name, 'position': i + 1, 'text': t},
          ],
        },
    ];
    final back = timed(
      'parseReports',
      const Duration(seconds: 2),
      () => parseReports(rows),
    );
    expect(back, hasLength(people));
    expect(
      back.first.totalOf(back.first.values.keys.first),
      r1.first.totalOf(r1.first.values.keys.first),
    );
  });
}
