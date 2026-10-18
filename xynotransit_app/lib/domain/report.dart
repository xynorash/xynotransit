import 'catalog.dart';
import 'enums.dart';
import 'period.dart';

/// Rules for the short notes under each box.
abstract final class NoteRules {
  static const maxCount = 3;
  static const maxLength = 70;

  /// Trimmed text, or null when empty or too long.
  static String? clean(String raw) {
    final t = raw.trim();
    if (t.isEmpty || t.length > maxLength) return null;
    return t;
  }

  /// Returns [list] with [raw] added, or the same list when it is
  /// invalid, a duplicate, or the box is full.
  static List<String> add(List<String> list, String raw) {
    final t = clean(raw);
    if (t == null || list.length >= maxCount || list.contains(t)) return list;
    return [...list, t];
  }

  static List<String> remove(List<String> list, String text) => [
    for (final s in list)
      if (s != text) s,
  ];
}

class KpiResult {
  const KpiResult(this.status, {this.comment});
  final KpiStatus status;
  final String? comment;
}

/// One assignment's answers for one period. Values are keyed by metric id
/// and hold three slots (month offset 0..2), null while not typed yet.
class Report {
  Report({
    this.id,
    required this.periodId,
    required this.assignmentId,
    this.status = ReportStatus.draft,
    this.submittedAt,
    Map<String, List<int?>>? values,
    Map<String, KpiResult>? kpis,
    Map<NoteKind, List<String>>? notes,
  }) : values = values ?? {},
       kpis = kpis ?? {},
       notes = notes ?? {for (final k in NoteKind.values) k: <String>[]};

  final String? id;
  final String periodId;
  final String assignmentId;
  final ReportStatus status;
  final DateTime? submittedAt;
  final Map<String, List<int?>> values;
  final Map<String, KpiResult> kpis;
  final Map<NoteKind, List<String>> notes;

  bool get isSubmitted => status == ReportStatus.submitted;

  List<String> notesOf(NoteKind k) => notes[k] ?? const [];

  int get noteCount => NoteKind.values.fold(0, (n, k) => n + notesOf(k).length);

  int kpiCount(KpiStatus s) => kpis.values.where((r) => r.status == s).length;

  /// Value for one month, 0 when missing.
  int valueOf(String metricId, int offset) {
    final v = values[metricId];
    return (v != null && offset < v.length ? v[offset] : null) ?? 0;
  }

  int totalOf(String metricId) =>
      List.generate(3, (i) => valueOf(metricId, i)).fold(0, (a, b) => a + b);

  Report copyWith({
    String? id,
    ReportStatus? status,
    DateTime? submittedAt,
    Map<String, List<int?>>? values,
    Map<String, KpiResult>? kpis,
    Map<NoteKind, List<String>>? notes,
  }) => Report(
    id: id ?? this.id,
    periodId: periodId,
    assignmentId: assignmentId,
    status: status ?? this.status,
    submittedAt: submittedAt ?? this.submittedAt,
    values: values ?? this.values,
    kpis: kpis ?? this.kpis,
    notes: notes ?? this.notes,
  );

  /// Plain-language problems that block sending. Empty means ready.
  List<String> validate(Assignment a, Period p) {
    final problems = <String>[];
    final months = p.months;
    for (final m in a.metrics) {
      final v = values[m.id];
      for (var i = 0; i < 3; i++) {
        final x = v != null && i < v.length ? v[i] : null;
        if (x == null || x < 0) {
          problems.add('Enter a number for "${m.label}" in ${months[i].long}.');
          break;
        }
      }
    }
    final left = a.kpis.where((k) => kpis[k.id] == null).length;
    if (left > 0) problems.add('Answer all targets in step 3 ($left left).');
    return problems;
  }

  /// Local draft storage.
  Map<String, Object?> toDraftJson() => {
    'values': {for (final e in values.entries) e.key: e.value},
    'kpis': {
      for (final e in kpis.entries)
        e.key: {'status': e.value.status.name, 'comment': e.value.comment},
    },
    'notes': {for (final e in notes.entries) e.key.name: e.value},
  };

  static Report fromDraftJson(
    String periodId,
    String assignmentId,
    Map<String, Object?> j,
  ) {
    final values = <String, List<int?>>{};
    final rawValues = (j['values'] as Map<String, Object?>?) ?? const {};
    for (final e in rawValues.entries) {
      values[e.key] = [
        for (final x in e.value! as List<Object?>) (x as num?)?.toInt(),
      ];
    }
    final kpis = <String, KpiResult>{};
    final rawKpis = (j['kpis'] as Map<String, Object?>?) ?? const {};
    for (final e in rawKpis.entries) {
      final m = e.value! as Map<String, Object?>;
      final s = KpiStatus.tryParse(m['status'] as String?);
      if (s != null) {
        kpis[e.key] = KpiResult(s, comment: m['comment'] as String?);
      }
    }
    final notes = {for (final k in NoteKind.values) k: <String>[]};
    final rawNotes = (j['notes'] as Map<String, Object?>?) ?? const {};
    for (final k in NoteKind.values) {
      final l = rawNotes[k.name] as List<Object?>?;
      if (l != null) notes[k] = [for (final s in l) s! as String];
    }
    return Report(
      periodId: periodId,
      assignmentId: assignmentId,
      values: values,
      kpis: kpis,
      notes: notes,
    );
  }
}
