import 'catalog.dart';
import 'enums.dart';
import 'period.dart';
import 'report.dart';

class SnapshotMetric {
  const SnapshotMetric({
    required this.key,
    required this.label,
    required this.series,
    required this.values,
  });
  final String key;
  final String label;
  final int series;
  final List<int> values;

  int get total => values.fold(0, (a, b) => a + b);

  Map<String, Object?> toJson() => {
    'key': key,
    'label': label,
    'series': series,
    'values': values,
  };

  factory SnapshotMetric.fromJson(Map<String, Object?> j) => SnapshotMetric(
    key: j['key']! as String,
    label: j['label']! as String,
    series: (j['series']! as num).toInt(),
    values: [
      for (final v in j['values']! as List<Object?>) (v! as num).toInt(),
    ],
  );
}

class SnapshotTarget {
  const SnapshotTarget({required this.text, required this.status});
  final String text;

  /// Null when the person never answered it.
  final KpiStatus? status;

  Map<String, Object?> toJson() => {'text': text, 'status': status?.name};

  factory SnapshotTarget.fromJson(Map<String, Object?> j) => SnapshotTarget(
    text: j['text']! as String,
    status: KpiStatus.tryParse(j['status'] as String?),
  );
}

/// Everything one pair of slides needs. This JSON is the stable contract
/// between the database (deck_run_item.snapshot) and the slide widgets.
class ReportSnapshot {
  const ReportSnapshot({
    required this.assignmentCode,
    required this.name,
    required this.role,
    required this.team,
    required this.periodLabel,
    required this.months,
    required this.metrics,
    required this.targets,
    required this.well,
    required this.wrong,
    required this.next,
  });

  final String assignmentCode;
  final String name;
  final String role;
  final String team;
  final String periodLabel;
  final List<MonthRef> months;
  final List<SnapshotMetric> metrics;
  final List<SnapshotTarget> targets;
  final List<String> well;
  final List<String> wrong;
  final List<String> next;

  bool get hasCounts => metrics.isNotEmpty;

  int count(KpiStatus s) => targets.where((t) => t.status == s).length;

  int get metCount => count(KpiStatus.met);

  List<String> notesOf(NoteKind k) => switch (k) {
    NoteKind.well => well,
    NoteKind.wrong => wrong,
    NoteKind.next => next,
  };

  String get firstMonthName => months.first.short;
  String get lastMonthName => months.last.short;

  static ReportSnapshot build({
    required Report report,
    required Assignment assignment,
    required Catalog catalog,
    required Period period,
  }) {
    final months = period.months;
    // Words typed by the reporter win over the profile.
    final who = report.reporter;
    String pick(String? typed, String profile) =>
        (typed ?? '').trim().isEmpty ? profile : typed!.trim();
    return ReportSnapshot(
      assignmentCode: assignment.code,
      name: pick(who?.name, catalog.personOf(assignment).fullName),
      role: pick(who?.role, assignment.roleTitle),
      team: pick(who?.country, catalog.teamOf(assignment).name),
      periodLabel: period.label,
      months: months,
      metrics: [
        for (final m in assignment.metrics)
          SnapshotMetric(
            key: m.key,
            label: m.label,
            series: m.series,
            values: [for (var i = 0; i < 3; i++) report.valueOf(m.id, i)],
          ),
      ],
      targets: [
        for (final k in assignment.kpis)
          SnapshotTarget(text: k.text, status: report.kpis[k.id]?.status),
      ],
      well: List.of(report.notesOf(NoteKind.well)),
      wrong: List.of(report.notesOf(NoteKind.wrong)),
      next: List.of(report.notesOf(NoteKind.next)),
    );
  }

  Map<String, Object?> toJson() => {
    'assignmentCode': assignmentCode,
    'name': name,
    'role': role,
    'team': team,
    'periodLabel': periodLabel,
    'months': [for (final m in months) m.toJson()],
    'metrics': [for (final m in metrics) m.toJson()],
    'targets': [for (final t in targets) t.toJson()],
    'well': well,
    'wrong': wrong,
    'next': next,
  };

  factory ReportSnapshot.fromJson(Map<String, Object?> j) {
    List<String> strings(String key) => [
      for (final s in (j[key] as List<Object?>? ?? const [])) s! as String,
    ];
    List<Map<String, Object?>> maps(String key) => [
      for (final m in (j[key] as List<Object?>? ?? const []))
        (m! as Map<String, Object?>),
    ];
    return ReportSnapshot(
      assignmentCode: j['assignmentCode']! as String,
      name: j['name']! as String,
      role: j['role']! as String,
      team: j['team']! as String,
      periodLabel: j['periodLabel']! as String,
      months: maps('months').map(MonthRef.fromJson).toList(),
      metrics: maps('metrics').map(SnapshotMetric.fromJson).toList(),
      targets: maps('targets').map(SnapshotTarget.fromJson).toList(),
      well: strings('well'),
      wrong: strings('wrong'),
      next: strings('next'),
    );
  }
}
