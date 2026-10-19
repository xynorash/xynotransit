import 'period.dart';

/// One team's progress and results in the shown period.
class TeamSummary {
  const TeamSummary({
    required this.teamId,
    required this.name,
    required this.expected,
    required this.submitted,
    this.submittedInactive = 0,
    required this.met,
    required this.partly,
    required this.missed,
    required this.volumeByMonth,
  });

  final String teamId;
  final String name;

  /// Active assignments of the team.
  final int expected;

  /// Submitted reports of the team's expected seats (never more than [expected]).
  final int submitted;

  /// Reports of switched off seats or people of the team: kept, never expected.
  final int submittedInactive;
  final int met;
  final int partly;
  final int missed;

  /// Sum of every count of every report of the team, per month (3 values).
  final List<int> volumeByMonth;

  int get answered => met + partly + missed;

  /// Share of answered targets that were met, 0..1 (0 when nothing is answered).
  double get metRate => answered == 0 ? 0 : met / answered;

  Map<String, Object?> toJson() => {
    'team_id': teamId,
    'name': name,
    'expected': expected,
    'submitted': submitted,
    'submitted_inactive': submittedInactive,
    'met': met,
    'partly': partly,
    'missed': missed,
    'volume_by_month': volumeByMonth,
  };

  factory TeamSummary.fromJson(Map<String, Object?> j) => TeamSummary(
    teamId: '${j['team_id']}',
    name: j['name']! as String,
    expected: (j['expected']! as num).toInt(),
    submitted: (j['submitted']! as num).toInt(),
    submittedInactive: ((j['submitted_inactive'] ?? 0) as num).toInt(),
    met: (j['met']! as num).toInt(),
    partly: (j['partly']! as num).toInt(),
    missed: (j['missed']! as num).toInt(),
    volumeByMonth: [
      for (final v in j['volume_by_month']! as List<Object?>)
        (v! as num).toInt(),
    ],
  );
}

/// One count series, grouped by its label across all assignments (case insensitive).
class MetricSummary {
  const MetricSummary({
    required this.label,
    required this.total,
    required this.byMonth,
    required this.byTeam,
  });

  final String label;
  final int total;

  /// 3 values.
  final List<int> byMonth;

  /// Team name to total, biggest first.
  final List<({String team, int total})> byTeam;

  Map<String, Object?> toJson() => {
    'label': label,
    'total': total,
    'by_month': byMonth,
    'by_team': [
      for (final t in byTeam) {'team': t.team, 'total': t.total},
    ],
  };

  factory MetricSummary.fromJson(Map<String, Object?> j) => MetricSummary(
    label: j['label']! as String,
    total: (j['total']! as num).toInt(),
    byMonth: [
      for (final v in j['by_month']! as List<Object?>) (v! as num).toInt(),
    ],
    byTeam: [
      for (final t in j['by_team']! as List<Object?>)
        (
          team: (t! as Map<String, Object?>)['team']! as String,
          total: ((t as Map<String, Object?>)['total']! as num).toInt(),
        ),
    ],
  );
}

/// One period in the trend: how complete it was and how it went.
class TrendPoint {
  const TrendPoint({
    required this.periodId,
    required this.label,
    required this.startMonth,
    required this.expected,
    required this.submitted,
    this.submittedInactive = 0,
    required this.met,
    required this.partly,
    required this.missed,
    required this.volumeTotal,
  });

  final String periodId;
  final String label;
  final DateTime startMonth;
  final int expected;

  /// Reports of expected seats only (never more than [expected]).
  final int submitted;

  /// Reports of switched off seats or people.
  final int submittedInactive;
  final int met;
  final int partly;
  final int missed;
  final int volumeTotal;

  int get answered => met + partly + missed;
  double get metRate => answered == 0 ? 0 : met / answered;
  double get submissionRate => expected == 0 ? 0 : submitted / expected;

  Map<String, Object?> toJson() => {
    'period_id': periodId,
    'label': label,
    'start_month': Period.dateOnly(startMonth),
    'expected': expected,
    'submitted': submitted,
    'submitted_inactive': submittedInactive,
    'met': met,
    'partly': partly,
    'missed': missed,
    'volume_total': volumeTotal,
  };

  factory TrendPoint.fromJson(Map<String, Object?> j) => TrendPoint(
    periodId: j['period_id']! as String,
    label: j['label']! as String,
    startMonth: DateTime.parse(j['start_month']! as String),
    expected: (j['expected']! as num).toInt(),
    submitted: (j['submitted']! as num).toInt(),
    submittedInactive: ((j['submitted_inactive'] ?? 0) as num).toInt(),
    met: (j['met']! as num).toInt(),
    partly: (j['partly']! as num).toInt(),
    missed: (j['missed']! as num).toInt(),
    volumeTotal: (j['volume_total']! as num).toInt(),
  );
}

/// One seat in the shown period.
class PersonSummary {
  const PersonSummary({
    required this.assignmentId,
    required this.name,
    required this.role,
    required this.team,
    this.active = true,
    required this.submitted,
    required this.met,
    required this.partly,
    required this.missed,
    required this.volumeTotal,
  });

  final String assignmentId;
  final String name;
  final String role;
  final String team;

  /// False for a switched off seat or person that has a report: shown tagged
  /// Inactive, never counted as missing.
  final bool active;
  final bool submitted;
  final int met;
  final int partly;
  final int missed;
  final int volumeTotal;

  Map<String, Object?> toJson() => {
    'assignment_id': assignmentId,
    'name': name,
    'role': role,
    'team': team,
    'active': active,
    'submitted': submitted,
    'met': met,
    'partly': partly,
    'missed': missed,
    'volume_total': volumeTotal,
  };

  factory PersonSummary.fromJson(Map<String, Object?> j) => PersonSummary(
    assignmentId: '${j['assignment_id']}',
    name: j['name']! as String,
    role: j['role']! as String,
    team: j['team']! as String,
    active: (j['active'] as bool?) ?? true,
    submitted: j['submitted']! as bool,
    met: (j['met']! as num).toInt(),
    partly: (j['partly']! as num).toInt(),
    missed: (j['missed']! as num).toInt(),
    volumeTotal: (j['volume_total']! as num).toInt(),
  );
}

/// Everything the manager's summary dashboard draws, for one period plus the trend.
class Summary {
  const Summary({
    required this.periodId,
    required this.periodLabel,
    required this.months,
    required this.expected,
    required this.submitted,
    this.submittedInactive = 0,
    required this.teams,
    required this.metrics,
    required this.trend,
    required this.people,
  });

  final String periodId;
  final String periodLabel;
  final List<MonthRef> months;

  /// Active seats of active people.
  final int expected;

  /// Reports of those seats only, so never more than [expected].
  final int submitted;

  /// Reports of switched off seats or people: kept and listed, never expected.
  final int submittedInactive;
  final List<TeamSummary> teams;

  /// Grouped by label, biggest total first.
  final List<MetricSummary> metrics;

  /// Oldest first, the shown period last.
  final List<TrendPoint> trend;
  final List<PersonSummary> people;

  int get met => teams.fold(0, (a, t) => a + t.met);
  int get partly => teams.fold(0, (a, t) => a + t.partly);
  int get missed => teams.fold(0, (a, t) => a + t.missed);
  int get answered => met + partly + missed;
  double get metRate => answered == 0 ? 0 : met / answered;

  Map<String, Object?> toJson() => {
    'period_id': periodId,
    'period_label': periodLabel,
    'months': [for (final m in months) m.toJson()],
    'expected': expected,
    'submitted': submitted,
    'submitted_inactive': submittedInactive,
    'teams': [for (final t in teams) t.toJson()],
    'metrics': [for (final m in metrics) m.toJson()],
    'trend': [for (final t in trend) t.toJson()],
    'people': [for (final p in people) p.toJson()],
  };

  factory Summary.fromJson(Map<String, Object?> j) {
    List<Map<String, Object?>> rows(String k) => [
      for (final r in (j[k] as List<Object?>? ?? const []))
        r! as Map<String, Object?>,
    ];
    return Summary(
      periodId: j['period_id']! as String,
      periodLabel: j['period_label']! as String,
      months: rows('months').map(MonthRef.fromJson).toList(),
      expected: (j['expected']! as num).toInt(),
      submitted: (j['submitted']! as num).toInt(),
      submittedInactive: ((j['submitted_inactive'] ?? 0) as num).toInt(),
      teams: rows('teams').map(TeamSummary.fromJson).toList(),
      metrics: rows('metrics').map(MetricSummary.fromJson).toList(),
      trend: rows('trend').map(TrendPoint.fromJson).toList(),
      people: rows('people').map(PersonSummary.fromJson).toList(),
    );
  }
}
