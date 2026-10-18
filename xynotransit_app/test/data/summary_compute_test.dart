import 'package:flutter_test/flutter_test.dart';
import 'package:xynotransit_app/domain/catalog.dart';
import 'package:xynotransit_app/domain/enums.dart';
import 'package:xynotransit_app/domain/period.dart';
import 'package:xynotransit_app/domain/report.dart';
import 'package:xynotransit_app/domain/summary.dart';
import 'package:xynotransit_app/domain/summary_compute.dart';

MetricDef m(String id, String label, int series) =>
    MetricDef(id: id, key: id, label: label, series: series);

KpiDef k(String id, int sort) => KpiDef(id: id, sort: sort, text: id);

Assignment seat(
  String id,
  String person,
  String team,
  int sort, {
  List<MetricDef> metrics = const [],
  List<KpiDef> kpis = const [],
  bool active = true,
}) => Assignment(
  id: id,
  code: id,
  personId: person,
  teamId: team,
  roleTitle: 'Role $id',
  sort: sort,
  metrics: metrics,
  kpis: kpis,
  active: active,
);

Report report(
  String period,
  String seatId, {
  Map<String, List<int?>> values = const {},
  Map<String, KpiStatus> kpis = const {},
  bool submitted = true,
}) => Report(
  id: 'r-$period-$seatId',
  periodId: period,
  assignmentId: seatId,
  status: submitted ? ReportStatus.submitted : ReportStatus.draft,
  values: values,
  kpis: {for (final e in kpis.entries) e.key: KpiResult(e.value)},
);

void main() {
  final catalog = Catalog(
    teams: const [
      Team(id: 't1', code: 'alpha', name: 'Alpha', sort: 1),
      Team(id: 't2', code: 'beta', name: 'Beta', sort: 2),
      Team(id: 't3', code: 'gone', name: 'Gone', sort: 3),
    ],
    persons: const [
      Person(id: 'p1', fullName: 'Ann'),
      Person(id: 'p2', fullName: 'Bob'),
      Person(id: 'p3', fullName: 'Cy'),
    ],
    assignments: [
      seat(
        's1',
        'p1',
        't1',
        1,
        metrics: [m('m1', 'Sea', 0), m('m2', 'Air', 1)],
        kpis: [k('k1', 1), k('k2', 2)],
      ),
      seat(
        's2',
        'p2',
        't1',
        2,
        metrics: [m('m3', 'sea', 0)],
        kpis: [k('kx', 1)],
      ),
      seat('s3', 'p3', 't2', 1, kpis: [k('k3', 1)]),
      seat('s4', 'p3', 't2', 2, active: false),
    ],
  );
  final p0 = Period(id: 'P0', startMonth: DateTime(2025, 11));
  final p1 = Period(id: 'P1', startMonth: DateTime(2026, 2));
  final reports = {
    'P1': [
      report(
        'P1',
        's1',
        values: {
          'm1': [1, 2, 3],
          'm2': [10, 0, 5],
        },
        kpis: {'k1': KpiStatus.met, 'k2': KpiStatus.partly},
      ),
      report(
        'P1',
        's2',
        values: {
          'm3': [4, 4, 4],
        },
        kpis: {'kx': KpiStatus.met},
      ),
      report('P1', 's3', kpis: {'k3': KpiStatus.missed}, submitted: false),
    ],
    'P0': [
      report(
        'P0',
        's1',
        values: {
          'm1': [2, 2, 2],
        },
        kpis: {'k1': KpiStatus.missed},
      ),
    ],
  };

  test('hand computed numbers for the shown period', () {
    final s = computeSummary(
      period: p1,
      allPeriods: [p1, p0],
      catalog: catalog,
      reports: reports,
    );
    expect(s.periodId, 'P1');
    expect(s.periodLabel, 'Feb to Apr 2026');
    expect(s.months.map((x) => x.short), ['Feb', 'Mar', 'Apr']);
    expect(s.expected, 3); // s4 is inactive
    expect(s.submitted, 2); // the draft does not count

    // Teams with active seats only, in team order.
    expect(s.teams.map((t) => t.name), ['Alpha', 'Beta']);
    final alpha = s.teams[0];
    expect(
      [alpha.expected, alpha.submitted, alpha.met, alpha.partly, alpha.missed],
      [2, 2, 2, 1, 0],
    );
    expect(alpha.volumeByMonth, [15, 6, 12]);
    final beta = s.teams[1];
    expect(
      [beta.expected, beta.submitted, beta.met, beta.missed],
      [1, 0, 0, 0],
    );
    expect(beta.volumeByMonth, [0, 0, 0]);
    expect([s.met, s.partly, s.missed], [2, 1, 0]);
    expect(s.metRate, closeTo(2 / 3, 1e-9));

    // Grouped by lower case label, first label shown, biggest first.
    expect(s.metrics.map((x) => x.label), ['Sea', 'Air']);
    expect(s.metrics[0].total, 18);
    expect(s.metrics[0].byMonth, [5, 6, 7]);
    expect(s.metrics[0].byTeam, [(team: 'Alpha', total: 18)]);
    expect(s.metrics[1].total, 15);
    expect(s.metrics[1].byMonth, [10, 0, 5]);

    expect(s.people.map((x) => x.assignmentId), ['s1', 's2', 's3']);
    final ann = s.people[0];
    expect(
      [ann.submitted, ann.met, ann.partly, ann.missed, ann.volumeTotal],
      [true, 1, 1, 0, 21],
    );
    expect(s.people[1].volumeTotal, 12);
    expect(s.people[2].submitted, isFalse);
    expect(s.people[2].volumeTotal, 0);
  });

  test(
    'trend: oldest first, shown period last, expected is active seats now',
    () {
      final s = computeSummary(
        period: p1,
        allPeriods: [p1, p0],
        catalog: catalog,
        reports: reports,
      );
      expect(s.trend.map((t) => t.periodId), ['P0', 'P1']);
      final a = s.trend[0];
      expect(
        [a.expected, a.submitted, a.met, a.partly, a.missed, a.volumeTotal],
        [3, 1, 0, 0, 1, 6],
      );
      final b = s.trend[1];
      expect(
        [b.expected, b.submitted, b.met, b.partly, b.missed, b.volumeTotal],
        [3, 2, 2, 1, 0, 33],
      );
      expect(b.submissionRate, closeTo(2 / 3, 1e-9));
    },
  );

  test(
    'trend 1 keeps only the shown period; a later period is not in the past',
    () {
      final p2 = Period(id: 'P2', startMonth: DateTime(2026, 5));
      final s = computeSummary(
        period: p1,
        allPeriods: [p0, p1, p2],
        catalog: catalog,
        reports: reports,
        trend: 1,
      );
      expect(s.trend.map((t) => t.periodId), ['P1']);
      final all = computeSummary(
        period: p1,
        allPeriods: [p0, p1, p2],
        catalog: catalog,
        reports: reports,
      );
      expect(all.trend.map((t) => t.periodId), ['P0', 'P1']);
    },
  );

  test('counts taken off a seat still count in old reports', () {
    final withOld = {
      'P1': [
        report(
          'P1',
          's1',
          values: {
            'm1': [1, 2, 3],
            'm9': [1, 1, 1],
          },
        ),
      ],
    };
    final s = computeSummary(
      period: p1,
      allPeriods: [p1],
      catalog: catalog,
      reports: withOld,
      retired: {
        's1': [m('m9', 'Old', 5)],
      },
    );
    expect(s.metrics.map((x) => (x.label, x.total)), [
      ('Sea', 6),
      ('Old', 3),
      ('Air', 0),
    ]);
    expect(s.people[0].volumeTotal, 9);
  });

  test('an empty period has zeros and no division by zero', () {
    final s = computeSummary(
      period: p1,
      allPeriods: [p1],
      catalog: catalog,
      reports: const {},
    );
    expect(s.submitted, 0);
    expect(s.metRate, 0);
    expect(s.trend.single.submissionRate, 0);
    expect(s.metrics.every((x) => x.total == 0), isTrue);
  });

  test('toJson then fromJson keeps every number', () {
    final s = computeSummary(
      period: p1,
      allPeriods: [p1, p0],
      catalog: catalog,
      reports: reports,
    );
    expect(Summary.fromJson(s.toJson()).toJson(), s.toJson());
  });
}
