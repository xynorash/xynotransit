import 'catalog.dart';
import 'enums.dart';
import 'period.dart';
import 'numbers.dart';
import 'text_rules.dart';

/// Rules for the short notes under each box.
abstract final class NoteRules {
  static const maxCount = 3;
  static const maxLength = 70;

  /// Largest number a count can hold, and the smallest.
  static const valueMax = countMax;

  /// Trimmed text, or null when empty or too long. Length is in characters
  /// (an emoji is one), as the server counts.
  static String? clean(String raw) {
    final t = trimText(raw);
    if (t.isEmpty || charCount(t) > maxLength) return null;
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

/// Who the report says it is from, in the reporter's own words. These three
/// free-text answers are what the slides show; they start out as the profile
/// (person name, team name, role title) and the reporter can change them.
class Reporter {
  const Reporter({this.name = '', this.country = '', this.role = ''});

  static const maxLength = 80;

  /// True when [s] has no control or invisible character, as the server
  /// judges it (lib/domain/text_rules.dart). Odd spaces are not a problem:
  /// they are turned into plain spaces when the report is sent.
  static bool isPlain(String s) => !hasHiddenChars(s);

  final String name;
  final String country;
  final String role;

  Reporter copyWith({String? name, String? country, String? role}) => Reporter(
    name: name ?? this.name,
    country: country ?? this.country,
    role: role ?? this.role,
  );

  /// Plain-language problems, in the order of the fields.
  List<String> problems() => [
    ?_problem(name, 'name'),
    ?_problem(country, 'country'),
    ?_problem(role, 'role'),
  ];

  static String? _problem(String value, String what) {
    final t = trimText(plainSpaces(value));
    if (t.isEmpty) return 'Enter your $what.';
    if (charCount(t) > maxLength) {
      return 'Your $what can be at most $maxLength characters.';
    }
    if (!isPlain(t)) return 'Your $what must be plain text on one line.';
    return null;
  }

  Map<String, Object?> toJson() => {
    'name': trimText(plainSpaces(name)),
    'country': trimText(plainSpaces(country)),
    'role': trimText(plainSpaces(role)),
  };

  static Reporter? fromJson(Object? j) {
    if (j is! Map) return null;
    String text(String k) {
      final v = j[k];
      return v is String ? v : '';
    }

    return Reporter(
      name: text('name'),
      country: text('country'),
      role: text('role'),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is Reporter &&
      other.name == name &&
      other.country == country &&
      other.role == role;

  @override
  int get hashCode => Object.hash(name, country, role);
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
    this.reporter,
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

  /// Name, country and role as typed by the reporter. Null on reports sent
  /// before these fields existed: the profile is used then.
  final Reporter? reporter;

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
    Reporter? reporter,
  }) => Report(
    id: id ?? this.id,
    periodId: periodId,
    assignmentId: assignmentId,
    status: status ?? this.status,
    submittedAt: submittedAt ?? this.submittedAt,
    values: values ?? this.values,
    kpis: kpis ?? this.kpis,
    notes: notes ?? this.notes,
    reporter: reporter ?? this.reporter,
  );

  /// Plain-language problems that block sending, in the order the server finds
  /// them and with the same words (the server sends the first one back).
  /// Empty means ready.
  List<String> validate(Assignment a, Period p) {
    final problems = <String>[];
    problems.addAll((reporter ?? const Reporter()).problems());

    // Ids must belong to this seat's live counts and targets.
    final metricIds = {for (final m in a.metrics) m.id};
    final kpiIds = {for (final k in a.kpis) k.id};
    if (values.keys.any((id) => !metricIds.contains(id))) {
      problems.add('One of the numbers does not belong to this report.');
    }
    if (kpis.keys.any((id) => !kpiIds.contains(id))) {
      problems.add('One of the targets does not belong to this report.');
    }

    // Step 2: a number for every month of every count (first gap per count).
    final months = p.months;
    for (final m in a.metrics) {
      final v = values[m.id];
      for (var i = 0; i < 3; i++) {
        final x = v != null && i < v.length ? v[i] : null;
        if (x == null || x < 0 || x > NoteRules.valueMax) {
          problems.add('Enter a number for "${m.label}" in ${months[i].long}.');
          break;
        }
      }
    }
    if (values.values.any(
      (v) => v.any((x) => x != null && x > NoteRules.valueMax),
    )) {
      problems.add('A number can be at most ${NoteRules.valueMax}.');
    }

    // Step 3: every target answered.
    final left = a.kpis.where((k) => kpis[k.id] == null).length;
    if (left > 0) problems.add('Answer all targets in step 3 ($left left).');
    if (kpis.values.any((r) => charCount(trimText(r.comment ?? '')) > 200)) {
      problems.add('A comment can be at most 200 characters.');
    }

    // Text the database cannot store.
    if (notes.values.any((l) => l.any((t) => t.contains('\u0000'))) ||
        kpis.values.any((r) => (r.comment ?? '').contains('\u0000'))) {
      problems.add('Text cannot contain control characters.');
    }

    // Step 4: short notes.
    if (notes.values.any((l) => l.length > NoteRules.maxCount)) {
      problems.add('Write at most ${NoteRules.maxCount} notes per box.');
    }
    if (notes.values.any((l) => l.any((t) => trimText(t).isEmpty))) {
      problems.add('A note cannot be empty.');
    }
    if (notes.values.any(
      (l) => l.any((t) => charCount(trimText(t)) > NoteRules.maxLength),
    )) {
      problems.add('A note can be at most ${NoteRules.maxLength} characters.');
    }
    return problems;
  }

  /// This report cut to what [a] defines now: values and answers for counts and
  /// targets that no longer exist are dropped, everything else is kept. Use it
  /// on a saved draft before it goes back on the form, because a manager may
  /// have retired, added or renamed counts and targets since it was typed.
  ///
  /// A count keeps its numbers when it is renamed (same id). A target whose
  /// words were changed is a new target (new id), so its old answer is dropped:
  /// it answered other words.
  Report reconcile(Assignment a) => reconciliation(a).report;

  /// Same as [reconcile], with what changed, for a notice to the person.
  Reconciliation reconciliation(Assignment a) {
    final metricIds = {for (final m in a.metrics) m.id};
    final kpiIds = {for (final k in a.kpis) k.id};
    final keptValues = <String, List<int?>>{};
    var droppedCounts = 0;
    for (final e in values.entries) {
      if (metricIds.contains(e.key)) {
        keptValues[e.key] = [
          for (var i = 0; i < 3; i++) i < e.value.length ? e.value[i] : null,
        ];
      } else if (e.value.any((x) => x != null)) {
        droppedCounts++;
      }
    }
    final keptKpis = <String, KpiResult>{};
    var droppedTargets = 0;
    for (final e in kpis.entries) {
      if (kpiIds.contains(e.key)) {
        keptKpis[e.key] = e.value;
      } else {
        droppedTargets++;
      }
    }
    final newCounts = a.metrics
        .where((m) => (keptValues[m.id] ?? const []).every((x) => x == null))
        .length;
    final newTargets = a.kpis.where((k) => !keptKpis.containsKey(k.id)).length;
    return Reconciliation(
      Report(
        id: id,
        periodId: periodId,
        assignmentId: assignmentId,
        status: status,
        submittedAt: submittedAt,
        values: keptValues,
        kpis: keptKpis,
        notes: {
          for (final k in NoteKind.values) k: [...notesOf(k)],
        },
        reporter: reporter,
      ),
      droppedCounts: droppedCounts,
      droppedTargets: droppedTargets,
      openCounts: newCounts,
      openTargets: newTargets,
    );
  }

  /// Local draft storage.
  Map<String, Object?> toDraftJson() => {
    'values': {for (final e in values.entries) e.key: e.value},
    'kpis': {
      for (final e in kpis.entries)
        e.key: {'status': e.value.status.name, 'comment': e.value.comment},
    },
    'notes': {for (final e in notes.entries) e.key.name: e.value},
    if (reporter != null) 'reporter': reporter!.toJson(),
  };

  /// Reads a saved draft. A draft is only ever a convenience, so anything in it
  /// that does not look right is skipped instead of failing: a damaged draft
  /// gives a smaller draft, never an exception.
  static Report fromDraftJson(
    String periodId,
    String assignmentId,
    Map<String, Object?> j,
  ) {
    final values = <String, List<int?>>{};
    final rawValues = j['values'];
    if (rawValues is Map) {
      for (final e in rawValues.entries) {
        final v = e.value;
        if (e.key is! String || v is! List) continue;
        values[e.key as String] = [
          for (final x in v) x is num && x.isFinite ? x.toInt() : null,
        ];
      }
    }
    final kpis = <String, KpiResult>{};
    final rawKpis = j['kpis'];
    if (rawKpis is Map) {
      for (final e in rawKpis.entries) {
        final m = e.value;
        if (e.key is! String || m is! Map) continue;
        final st = m['status'];
        final s = KpiStatus.tryParse(st is String ? st : null);
        if (s == null) continue;
        final c = m['comment'];
        kpis[e.key as String] = KpiResult(s, comment: c is String ? c : null);
      }
    }
    final notes = {for (final k in NoteKind.values) k: <String>[]};
    final rawNotes = j['notes'];
    if (rawNotes is Map) {
      for (final k in NoteKind.values) {
        final l = rawNotes[k.name];
        if (l is List) {
          notes[k] = [
            for (final s in l)
              if (s is String) s,
          ];
        }
      }
    }
    return Report(
      periodId: periodId,
      assignmentId: assignmentId,
      values: values,
      kpis: kpis,
      notes: notes,
      reporter: Reporter.fromJson(j['reporter']),
    );
  }
}

/// What [Report.reconcile] did to a draft.
class Reconciliation {
  const Reconciliation(
    this.report, {
    required this.droppedCounts,
    required this.droppedTargets,
    required this.openCounts,
    required this.openTargets,
  });

  final Report report;

  /// Counts that were typed in but no longer exist on the seat.
  final int droppedCounts;

  /// Answered targets that no longer exist on the seat.
  final int droppedTargets;

  /// Counts of the seat that have no number yet.
  final int openCounts;

  /// Targets of the seat that have no answer yet.
  final int openTargets;

  /// True when something the person typed or chose had to be dropped.
  bool get lostAnswers => droppedCounts > 0 || droppedTargets > 0;
}
