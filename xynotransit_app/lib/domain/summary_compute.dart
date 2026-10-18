import 'catalog.dart';
import 'enums.dart';
import 'period.dart';
import 'report.dart';
import 'summary.dart';

/// Builds the dashboard numbers from reports. The API computes the same thing
/// in SQL; this is the version the in-memory demo uses.
///
/// Rules, shared with the API:
/// - only submitted reports count, a report counts whatever the seat's state is now;
/// - volume is the sum of every count of every month;
/// - [expected] is the number of active seats now, also for older periods;
/// - counts are grouped by lower case label across seats, the first label seen is shown;
/// - [retired] holds counts that were taken off a seat but still sit in old reports.
Summary computeSummary({
  required Period period,
  required List<Period> allPeriods,
  required Catalog catalog,
  required Map<String, List<Report>> reports,
  Map<String, List<MetricDef>> retired = const {},
  int trend = 6,
}) {
  final active = catalog.assignments.where((a) => a.active).toList();
  final byId = {for (final a in catalog.assignments) a.id: a};
  final teamName = {for (final t in catalog.teams) t.id: t.name};

  List<MetricDef> defsOf(Assignment a) => [
    ...a.metrics,
    ...(retired[a.id] ?? const <MetricDef>[]),
  ];

  List<Report> submittedOf(String periodId) => [
    for (final r in reports[periodId] ?? const <Report>[])
      if (r.isSubmitted && byId.containsKey(r.assignmentId)) r,
  ];

  /// Per month sums of the known counts of one report.
  List<int> monthsOf(Report r) {
    final out = [0, 0, 0];
    final defs = defsOf(byId[r.assignmentId]!);
    for (final m in defs) {
      for (var i = 0; i < 3; i++) {
        out[i] += r.valueOf(m.id, i);
      }
    }
    return out;
  }

  int volumeOf(Report r) => monthsOf(r).fold(0, (a, b) => a + b);

  // ---- the shown period ----
  final shown = submittedOf(period.id);

  final teams = <TeamSummary>[];
  for (final t in catalog.teams) {
    final seats = active.where((a) => a.teamId == t.id).length;
    if (seats == 0) continue;
    final rs = shown.where((r) => byId[r.assignmentId]!.teamId == t.id);
    final months = [0, 0, 0];
    for (final r in rs) {
      final m = monthsOf(r);
      for (var i = 0; i < 3; i++) {
        months[i] += m[i];
      }
    }
    teams.add(
      TeamSummary(
        teamId: t.id,
        name: t.name,
        expected: seats,
        submitted: rs.length,
        met: rs.fold(0, (n, r) => n + r.kpiCount(KpiStatus.met)),
        partly: rs.fold(0, (n, r) => n + r.kpiCount(KpiStatus.partly)),
        missed: rs.fold(0, (n, r) => n + r.kpiCount(KpiStatus.missed)),
        volumeByMonth: months,
      ),
    );
  }

  // Counts grouped by lower case label, in deck order of first sight.
  final order = <String>[];
  final display = <String, String>{};
  final monthsByLabel = <String, List<int>>{};
  final teamsByLabel = <String, Map<String, int>>{};
  for (final a in catalog.assignments) {
    for (final m in defsOf(a)) {
      final k = m.label.toLowerCase();
      if (!display.containsKey(k)) {
        order.add(k);
        display[k] = m.label;
        monthsByLabel[k] = [0, 0, 0];
        teamsByLabel[k] = {};
      }
    }
  }
  for (final r in shown) {
    final a = byId[r.assignmentId]!;
    for (final m in defsOf(a)) {
      final k = m.label.toLowerCase();
      final team = teamName[a.teamId] ?? '';
      var sum = 0;
      for (var i = 0; i < 3; i++) {
        final v = r.valueOf(m.id, i);
        monthsByLabel[k]![i] += v;
        sum += v;
      }
      teamsByLabel[k]![team] = (teamsByLabel[k]![team] ?? 0) + sum;
    }
  }
  final teamOrder = {for (final t in catalog.teams) t.name: t.sort};
  final metrics = [
    for (final k in order)
      MetricSummary(
        label: display[k]!,
        total: monthsByLabel[k]!.fold(0, (a, b) => a + b),
        byMonth: monthsByLabel[k]!,
        byTeam:
            [
              for (final e in teamsByLabel[k]!.entries)
                (team: e.key, total: e.value),
            ]..sort((a, b) {
              final c = b.total.compareTo(a.total);
              return c != 0
                  ? c
                  : (teamOrder[a.team] ?? 0).compareTo(teamOrder[b.team] ?? 0);
            }),
      ),
  ];
  // Dart's sort is not stable for lists, so the tie break is the first sight.
  final rank = {for (var i = 0; i < metrics.length; i++) metrics[i].label: i};
  metrics.sort((a, b) {
    final c = b.total.compareTo(a.total);
    return c != 0 ? c : rank[a.label]!.compareTo(rank[b.label]!);
  });

  final people = <PersonSummary>[];
  for (final a in active) {
    final r = shown.where((r) => r.assignmentId == a.id).firstOrNull;
    people.add(
      PersonSummary(
        assignmentId: a.id,
        name: catalog.personOf(a).fullName,
        role: a.roleTitle,
        team: teamName[a.teamId] ?? '',
        submitted: r != null,
        met: r?.kpiCount(KpiStatus.met) ?? 0,
        partly: r?.kpiCount(KpiStatus.partly) ?? 0,
        missed: r?.kpiCount(KpiStatus.missed) ?? 0,
        volumeTotal: r == null ? 0 : volumeOf(r),
      ),
    );
  }

  // ---- the trend ----
  final sorted = [...allPeriods]
    ..sort((a, b) => a.startMonth.compareTo(b.startMonth));
  final earlier = sorted.where((p) => p.startMonth.isBefore(period.startMonth));
  final keep = trend < 1 ? 0 : trend - 1;
  final older = earlier.toList();
  final window = older.length > keep
      ? older.sublist(older.length - keep)
      : older;
  final trendPoints = [
    for (final p in [...window, period])
      () {
        final rs = submittedOf(p.id);
        return TrendPoint(
          periodId: p.id,
          label: p.label,
          startMonth: p.startMonth,
          expected: active.length,
          submitted: rs.length,
          met: rs.fold(0, (n, r) => n + r.kpiCount(KpiStatus.met)),
          partly: rs.fold(0, (n, r) => n + r.kpiCount(KpiStatus.partly)),
          missed: rs.fold(0, (n, r) => n + r.kpiCount(KpiStatus.missed)),
          volumeTotal: rs.fold(0, (n, r) => n + volumeOf(r)),
        );
      }(),
  ];

  return Summary(
    periodId: period.id,
    periodLabel: period.label,
    months: period.months,
    expected: active.length,
    submitted: shown.length,
    teams: teams,
    metrics: metrics,
    trend: trendPoints,
    people: people,
  );
}
