import 'catalog.dart';
import 'enums.dart';
import 'period.dart';
import 'report.dart';
import 'summary.dart';

/// Builds the dashboard numbers from reports. The API computes the same thing
/// in SQL; this is the version the in-memory demo uses, and the contract suite
/// holds the two against each other.
///
/// Rules, shared with the API:
/// - only submitted reports count, a report counts whatever the seat's state is now;
/// - a seat is expected when the seat and its person are both switched on, also
///   for older periods in the trend;
/// - volume is the sum of every count of every month;
/// - counts are grouped by lower case label, per seat first and then across
///   seats; only counts a report has numbers for show up, and the first label
///   seen (live before retired, then the lower series) is the one shown;
/// - a team shows when it has an expected seat or a report in the shown period;
///   a switched off seat shows in the people list only when it has a report;
/// - [retired] holds counts that were taken off a seat but still sit in old reports.
Summary computeSummary({
  required Period period,
  required List<Period> allPeriods,
  required Catalog catalog,
  required Map<String, List<Report>> reports,
  Map<String, List<MetricDef>> retired = const {},
  int trend = 6,
}) {
  final byId = {for (final a in catalog.assignments) a.id: a};
  final teamName = {for (final t in catalog.teams) t.id: t.name};
  final expectedSeats = [
    for (final a in catalog.assignments)
      if (catalog.isExpected(a)) a,
  ];

  List<(MetricDef, bool)> defsOf(Assignment a) => [
    for (final m in a.metrics) (m, false),
    for (final m in retired[a.id] ?? const <MetricDef>[]) (m, true),
  ];

  List<Report> submittedOf(String periodId) => [
    for (final r in reports[periodId] ?? const <Report>[])
      if (r.isSubmitted && byId.containsKey(r.assignmentId)) r,
  ];

  /// Per month sums of the known counts of one report.
  List<int> monthsOf(Report r) {
    final out = [0, 0, 0];
    for (final (m, _) in defsOf(byId[r.assignmentId]!)) {
      for (var i = 0; i < 3; i++) {
        out[i] += r.valueOf(m.id, i);
      }
    }
    return out;
  }

  int volumeOf(Report r) => monthsOf(r).fold(0, (a, b) => a + b);

  // ---- the shown period ----
  final shown = submittedOf(period.id);
  final shownBySeat = {for (final r in shown) r.assignmentId: r};

  final teams = <TeamSummary>[];
  for (final t in catalog.teams) {
    final seats = expectedSeats.where((a) => a.teamId == t.id).length;
    final rs = shown
        .where((r) => byId[r.assignmentId]!.teamId == t.id)
        .toList();
    if (seats == 0 && rs.isEmpty) continue;
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

  // Counts grouped by lower case label. Seats come in deck order. Inside a seat
  // the groups come by their lowest series, then by label.
  final order = <String>[];
  final display = <String, String>{};
  final monthsByLabel = <String, List<int>>{};
  final teamsByLabel = <String, Map<String, int>>{};
  final teamOrderByLabel = <String, List<String>>{};
  for (final a in catalog.assignments) {
    final r = shownBySeat[a.id];
    if (r == null) continue;
    final seatGroups = <String, _SeatGroup>{};
    for (final (m, isRetired) in defsOf(a)) {
      // A count a report holds no numbers for (added after it was sent) is out.
      if (!r.values.containsKey(m.id)) continue;
      seatGroups
          .putIfAbsent(m.label.toLowerCase(), _SeatGroup.new)
          .add(m, isRetired, r);
    }
    final keys = seatGroups.keys.toList()
      ..sort((x, y) {
        final c = seatGroups[x]!.minSeries.compareTo(seatGroups[y]!.minSeries);
        return c != 0 ? c : x.compareTo(y);
      });
    final team = teamName[a.teamId] ?? '';
    for (final k in keys) {
      final g = seatGroups[k]!;
      if (!display.containsKey(k)) {
        order.add(k);
        display[k] = g.label;
        monthsByLabel[k] = [0, 0, 0];
        teamsByLabel[k] = {};
        teamOrderByLabel[k] = [];
      }
      var sum = 0;
      for (var i = 0; i < 3; i++) {
        monthsByLabel[k]![i] += g.months[i];
        sum += g.months[i];
      }
      final byTeam = teamsByLabel[k]!;
      if (!byTeam.containsKey(team)) teamOrderByLabel[k]!.add(team);
      byTeam[team] = (byTeam[team] ?? 0) + sum;
    }
  }
  final metrics = [
    for (final k in order)
      MetricSummary(
        label: display[k]!,
        total: monthsByLabel[k]!.fold(0, (a, b) => a + b),
        byMonth: monthsByLabel[k]!,
        byTeam: _byTotalDesc([
          for (final team in teamOrderByLabel[k]!)
            (team: team, total: teamsByLabel[k]![team]!),
        ]),
      ),
  ];
  // Biggest first; equal totals keep the order they were first seen in.
  final rank = {for (var i = 0; i < metrics.length; i++) metrics[i].label: i};
  metrics.sort((a, b) {
    final c = b.total.compareTo(a.total);
    return c != 0 ? c : rank[a.label]!.compareTo(rank[b.label]!);
  });

  final people = <PersonSummary>[];
  for (final a in catalog.assignments) {
    final r = shownBySeat[a.id];
    if (!catalog.isExpected(a) && r == null) continue;
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
          expected: expectedSeats.length,
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
    expected: expectedSeats.length,
    submitted: shown.length,
    teams: teams,
    metrics: metrics,
    trend: trendPoints,
    people: people,
  );
}

/// Counts of one label inside one seat: a live name wins over a retired one,
/// then the lower series, then the id.
class _SeatGroup {
  String label = '';
  bool _labelRetired = true;
  int _labelSeries = 1 << 30;
  String _labelId = '';
  int minSeries = 1 << 30;
  final months = [0, 0, 0];

  void add(MetricDef m, bool isRetired, Report r) {
    for (var i = 0; i < 3; i++) {
      months[i] += r.valueOf(m.id, i);
    }
    if (m.series < minSeries) minSeries = m.series;
    final better =
        label.isEmpty ||
        (isRetired ? 1 : 0) < (_labelRetired ? 1 : 0) ||
        ((isRetired ? 1 : 0) == (_labelRetired ? 1 : 0) &&
            (m.series < _labelSeries ||
                (m.series == _labelSeries && m.id.compareTo(_labelId) < 0)));
    if (better) {
      label = m.label;
      _labelRetired = isRetired;
      _labelSeries = m.series;
      _labelId = m.id;
    }
  }
}

/// Stable: equal totals keep their order.
List<({String team, int total})> _byTotalDesc(
  List<({String team, int total})> rows,
) {
  final rank = {for (var i = 0; i < rows.length; i++) rows[i].team: i};
  return [...rows]..sort((a, b) {
    final c = b.total.compareTo(a.total);
    return c != 0 ? c : rank[a.team]!.compareTo(rank[b.team]!);
  });
}
