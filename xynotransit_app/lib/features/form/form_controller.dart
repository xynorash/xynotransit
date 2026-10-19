import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart' show Curves, FocusNode, Scrollable;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/repository.dart';
import '../../domain/catalog.dart';
import '../../domain/enums.dart';
import '../../domain/period.dart';
import '../../domain/report.dart';
import '../../domain/text_rules.dart';
import '../../data/api/api_client.dart' show UnauthorizedException;

enum SendPhase { idle, sending, sent, queued, failed }

class FormModel {
  const FormModel({
    this.assignmentId,
    this.report,
    this.sentAt,
    this.problems = const [],
    this.phase = SendPhase.idle,
    this.message,
    this.epoch = 0,
    this.attempted = false,
    this.draftSavedAt,
    this.notice,
  });

  final String? assignmentId;

  /// The working copy the person is typing into.
  final Report? report;

  /// When this person already sent a report for the period.
  final DateTime? sentAt;
  final List<String> problems;
  final SendPhase phase;
  final String? message;

  /// Bumped when a different report is loaded, so inputs reset their text.
  final int epoch;

  /// True after a Send that found gaps, until the report is sent or another
  /// one is loaded. The fields then show what is still missing.
  final bool attempted;

  /// When the draft was last kept on this device.
  final DateTime? draftSavedAt;

  /// Plain words about what changed under the person, for example counts that
  /// the manager removed since the draft was saved.
  final String? notice;

  bool get hasPerson => assignmentId != null && report != null;

  FormModel copyWith({
    String? assignmentId,
    Report? report,
    DateTime? sentAt,
    bool clearSentAt = false,
    List<String>? problems,
    SendPhase? phase,
    String? message,
    bool clearMessage = false,
    int? epoch,
    bool? attempted,
    DateTime? draftSavedAt,
    bool clearDraftSavedAt = false,
    String? notice,
    bool clearNotice = false,
  }) => FormModel(
    assignmentId: assignmentId ?? this.assignmentId,
    report: report ?? this.report,
    sentAt: clearSentAt ? null : (sentAt ?? this.sentAt),
    problems: problems ?? this.problems,
    phase: phase ?? this.phase,
    message: clearMessage ? null : (message ?? this.message),
    epoch: epoch ?? this.epoch,
    attempted: attempted ?? this.attempted,
    draftSavedAt: clearDraftSavedAt
        ? null
        : (draftSavedAt ?? this.draftSavedAt),
    notice: clearNotice ? null : (notice ?? this.notice),
  );
}

/// Longest comment under a target.
const kpiCommentMax = 200;

const retryDelay = Duration(seconds: 15);

class FormController extends Notifier<FormModel> {
  Timer? _retry;

  @override
  FormModel build() {
    ref.listen(periodProvider, (prev, next) {
      if (next.hasValue &&
          prev?.value?.id != next.value!.id &&
          state.assignmentId != null) {
        unawaited(_load(state.assignmentId!));
      }
    });
    // Reports that waited for a sign in go out after the next one.
    ref.listen(userProvider, (prev, next) {
      if (next.value != null && prev?.value == null) {
        unawaited(retryPending());
      }
    });
    ref.onDispose(() => _retry?.cancel());
    return const FormModel();
  }

  Catalog get _catalog => ref.read(catalogProvider).requireValue;
  Period? get _period => ref.read(periodProvider).value;

  String _draftKey(Period p, String assignmentId) =>
      'draft/${Period.dateOnly(p.startMonth)}/$assignmentId';
  String _pendingKey(Period p, String assignmentId) =>
      'pending/${Period.dateOnly(p.startMonth)}/$assignmentId';
  String _draftAtKey(Period p, String assignmentId) =>
      'draftat/${Period.dateOnly(p.startMonth)}/$assignmentId';

  /// Set when the person chose "Choose a seat" themselves: the remembered seat
  /// is then not put back under them until they pick one again.
  bool _clearedByPerson = false;

  /// The key under which the last chosen seat of [personId] is kept on this device.
  static String lastSeatKey(String? personId) => 'last_seat/${personId ?? '-'}';

  /// The seat this person chose last on this device, if it is still one of
  /// [allowed] and they did not just clear the choice.
  String? rememberedSeat(String? personId, Iterable<String> allowed) {
    if (_clearedByPerson) return null;
    final id = ref.read(prefsProvider).getString(lastSeatKey(personId));
    return id != null && allowed.contains(id) ? id : null;
  }

  /// The person picked a seat in the chooser (or "Choose a seat" for none).
  /// A seat is remembered on this device, so after a reload they do not pick again.
  Future<void> chooseSeat(String? id, {String? personId}) async {
    _clearedByPerson = id == null;
    if (id != null) {
      unawaited(ref.read(prefsProvider).setString(lastSeatKey(personId), id));
    }
    await selectAssignment(id);
  }

  /// Pick a person, or null to clear the choice.
  Future<void> selectAssignment(String? id) async {
    if (id == null) {
      _syncLines(null);
      _comments.clear();
      state = FormModel(epoch: state.epoch + 1);
      return;
    }
    await _load(id);
  }

  Future<void> _load(String assignmentId) async {
    final period = await ref.read(periodProvider.future);
    final prefs = ref.read(prefsProvider);
    Report? existing;
    try {
      existing = await ref
          .read(repositoryProvider)
          .getReport(period.id, assignmentId);
    } on Object {
      existing = null;
    }
    Report? draft;
    final raw = prefs.getString(_draftKey(period, assignmentId));
    if (raw != null) {
      try {
        draft = Report.fromDraftJson(
          period.id,
          assignmentId,
          jsonDecode(raw) as Map<String, Object?>,
        );
      } on FormatException {
        draft = null;
      }
    }
    final queued = prefs.containsKey(_pendingKey(period, assignmentId));
    final savedAt = draft == null
        ? null
        : DateTime.tryParse(
            prefs.getString(_draftAtKey(period, assignmentId)) ?? '',
          );
    // The manager may have changed counts or targets since the draft was typed.
    String? notice;
    final seat = _catalog.assignmentById(assignmentId);
    if (draft != null && seat != null) {
      final rec = draft.reconciliation(seat);
      draft = rec.report;
      notice = reconcileNotice(rec);
    }
    final stored = prefs.getString(
      'reconcilenote/${Period.dateOnly(period.startMonth)}/$assignmentId',
    );
    notice ??= stored;
    var working = draft ?? _workingCopy(existing, period.id, assignmentId);
    if (draft == null && seat != null) working = working.reconcile(seat);
    working = working.copyWith(
      reporter:
          working.reporter ??
          existing?.reporter ??
          profileReporter(assignmentId),
    );
    _syncLines(working);
    _comments.clear();
    state = FormModel(
      assignmentId: assignmentId,
      report: working,
      sentAt: existing?.submittedAt,
      draftSavedAt: savedAt,
      notice: notice,
      phase: queued ? SendPhase.queued : SendPhase.idle,
      message: queued
          ? 'Saved on this device. It will be sent when you are back online.'
          : null,
      epoch: state.epoch + 1,
    );
  }

  Report _workingCopy(Report? r, String periodId, String assignmentId) {
    if (r == null) {
      return Report(periodId: periodId, assignmentId: assignmentId);
    }
    return Report(
      id: r.id,
      periodId: periodId,
      assignmentId: assignmentId,
      values: {for (final e in r.values.entries) e.key: List<int?>.of(e.value)},
      kpis: Map.of(r.kpis),
      notes: {for (final e in r.notes.entries) e.key: List<String>.of(e.value)},
      reporter: r.reporter,
    );
  }

  /// Name, country and role of the seat's profile: person full name, team
  /// name and role title. What the form starts from.
  Reporter profileReporter(String assignmentId) {
    final a = _catalog.assignmentById(assignmentId);
    if (a == null) return const Reporter();
    return Reporter(
      name: _catalog.personOf(a).fullName,
      country: _catalog.teamOf(a).name,
      role: a.roleTitle,
    );
  }

  /// Own words for who the report is from. Empty and long values are kept as
  /// typed: sending checks them.
  void setReporter({String? name, String? country, String? role}) {
    final r = state.report;
    if (r == null) return;
    final cur = r.reporter ?? const Reporter();
    _change(
      r.copyWith(
        reporter: cur.copyWith(name: name, country: country, role: role),
      ),
    );
  }

  /// Load a report that was already sent, from the table's Edit button.
  void edit(Report r) {
    final period = _period;
    if (period == null) return;
    ref.read(prefsProvider).remove(_draftKey(period, r.assignmentId));
    ref.read(prefsProvider).remove(_draftAtKey(period, r.assignmentId));
    final working = _workingCopy(
      r,
      period.id,
      r.assignmentId,
    ).copyWith(reporter: r.reporter ?? profileReporter(r.assignmentId));
    _syncLines(working);
    _comments.clear();
    state = FormModel(
      assignmentId: r.assignmentId,
      report: working,
      sentAt: r.submittedAt,
      epoch: state.epoch + 1,
    );
  }

  void _change(Report next) {
    state = state.copyWith(
      report: next,
      problems: const [],
      phase: SendPhase.idle,
      clearMessage: true,
      draftSavedAt: ref.read(clockProvider)(),
    );
    _saveDraft();
  }

  /// Back to editing after "Sent": the report stays as it was sent.
  void editAgain() {
    if (state.phase != SendPhase.sent) return;
    state = state.copyWith(phase: SendPhase.idle, clearMessage: true);
  }

  void _saveDraft() {
    final period = _period;
    final r = state.report;
    final id = state.assignmentId;
    if (period == null || r == null || id == null) return;
    final prefs = ref.read(prefsProvider);
    unawaited(
      prefs.setString(_draftKey(period, id), jsonEncode(r.toDraftJson())),
    );
    final at = state.draftSavedAt;
    if (at != null) {
      unawaited(prefs.setString(_draftAtKey(period, id), at.toIso8601String()));
    }
  }

  void setValue(String metricId, int month, int? value) {
    final r = state.report;
    if (r == null) return;
    final list = List<int?>.of(
      r.values[metricId] ?? List<int?>.filled(3, null),
    );
    list[month] = value;
    _change(r.copyWith(values: {...r.values, metricId: list}));
  }

  void setKpi(String kpiId, KpiStatus status) {
    final r = state.report;
    if (r == null) return;
    _change(
      r.copyWith(
        kpis: {
          ...r.kpis,
          kpiId: KpiResult(status, comment: _commentFor(r, kpiId)),
        },
      ),
    );
  }

  String? _commentFor(Report r, String kpiId) {
    final t = trimText(r.kpis[kpiId]?.comment ?? _comments.remove(kpiId) ?? '');
    if (t.isEmpty) return null;
    return cutChars(t, kpiCommentMax);
  }

  void _setNotes(NoteKind kind, List<String> list) {
    final r = state.report;
    if (r == null) return;
    _change(r.copyWith(notes: {...r.notes, kind: list}));
  }

  /// What is typed in the point boxes, line by line, blanks included.
  final Map<NoteKind, List<String>> _lines = {};

  void _syncLines(Report? r) {
    _lines
      ..clear()
      ..addAll({
        for (final k in NoteKind.values)
          k: [
            for (var i = 0; i < NoteRules.maxCount; i++)
              (r != null && i < r.notesOf(k).length) ? r.notesOf(k)[i] : '',
          ],
      });
  }

  /// The text of one point box, for the field to start from.
  String noteLine(NoteKind kind, int index) {
    final l = _lines[kind];
    return (l != null && index < l.length) ? l[index] : '';
  }

  /// Own words in point [index] (0 to 2) of a box. Empty lines are ignored
  /// and the rest keep their order.
  void setNote(NoteKind kind, int index, String text) {
    if (index < 0 || index >= NoteRules.maxCount) return;
    final lines = _lines.putIfAbsent(
      kind,
      () => List<String>.filled(NoteRules.maxCount, ''),
    );
    lines[index] = text;
    _setNotes(kind, [for (final l in lines) ?NoteRules.clean(l)]);
  }

  /// Comments typed before the status of the target was picked.
  final Map<String, String> _comments = {};

  /// The comment of a target, for the field to start from.
  String kpiComment(String kpiId) =>
      state.report?.kpis[kpiId]?.comment ?? _comments[kpiId] ?? '';

  /// Optional free-text comment under a target (200 characters).
  void setKpiComment(String kpiId, String text) {
    final r = state.report;
    if (r == null) return;
    final t = trimText(text);
    final comment = t.isEmpty ? null : cutChars(t, kpiCommentMax);
    final cur = r.kpis[kpiId];
    if (cur == null) {
      // Kept until a status is picked; a comment alone is not an answer.
      _comments[kpiId] = text;
      return;
    }
    _comments.remove(kpiId);
    _change(
      r.copyWith(
        kpis: {
          ...r.kpis,
          kpiId: KpiResult(cur.status, comment: comment),
        },
      ),
    );
  }

  Future<void> send() async {
    final r = state.report;
    final id = state.assignmentId;
    final period = _period;
    if (r == null || id == null || period == null) return;
    final a = _catalog.assignmentById(id)!;
    final problems = r.validate(a, period);
    if (problems.isNotEmpty) {
      state = state.copyWith(
        problems: problems,
        attempted: true,
        phase: SendPhase.idle,
        clearMessage: true,
      );
      return;
    }
    state = state.copyWith(
      problems: const [],
      phase: SendPhase.sending,
      clearMessage: true,
    );
    await _deliver(period, r);
  }

  Future<void> _deliver(Period period, Report r) async {
    final prefs = ref.read(prefsProvider);
    try {
      final saved = await ref.read(repositoryProvider).sendReport(r);
      await prefs.remove(_draftKey(period, r.assignmentId));
      await prefs.remove(_draftAtKey(period, r.assignmentId));
      await prefs.remove(_pendingKey(period, r.assignmentId));
      await prefs.remove(
        'reconcilenote/${Period.dateOnly(period.startMonth)}/${r.assignmentId}',
      );
      if (state.assignmentId == r.assignmentId) {
        state = state.copyWith(
          attempted: false,
          clearNotice: true,
          clearDraftSavedAt: true,
          phase: SendPhase.sent,
          sentAt: saved.submittedAt,
          clearMessage: true,
        );
      }
    } on RepositoryException catch (e) {
      state = state.copyWith(phase: SendPhase.failed, message: e.message);
    } on NetworkException {
      await prefs.setString(
        _pendingKey(period, r.assignmentId),
        jsonEncode({
          'periodId': period.id,
          'assignmentId': r.assignmentId,
          'draft': r.toDraftJson(),
        }),
      );
      await prefs.setString(
        _draftKey(period, r.assignmentId),
        jsonEncode(r.toDraftJson()),
      );
      state = state.copyWith(
        phase: SendPhase.queued,
        message:
            'Saved on this device. It will be sent when you are back online.',
      );
      _scheduleRetry();
    } on Object {
      state = state.copyWith(
        phase: SendPhase.failed,
        message: 'Could not send. Check your connection and try again.',
      );
    }
  }

  void _scheduleRetry() {
    _retry?.cancel();
    _retry = Timer(retryDelay, () => unawaited(retryPending()));
  }

  String _noteKey(String pendingKey) =>
      pendingKey.replaceFirst('pending/', 'reconcilenote/');

  /// Sends every report that was saved on this device while offline.
  ///
  /// Each one is first matched against the CURRENT counts and targets of its
  /// seat. If the manager changed them while the report waited, it is not
  /// sent: it stays on this device as a draft with a notice, so the person
  /// checks it. A damaged entry is deleted and the others still go out. A
  /// sign in that ran out keeps the entry; it is tried again after the next
  /// sign in.
  Future<void> retryPending() async {
    final prefs = ref.read(prefsProvider);
    final keys = prefs
        .getKeys()
        .where((k) => k.startsWith('pending/'))
        .toList();
    if (keys.isEmpty) return;
    final repo = ref.read(repositoryProvider);
    var stillOffline = false;
    for (final key in keys) {
      final String periodId;
      final String assignmentId;
      final Report report;
      try {
        final j =
            jsonDecode(prefs.getString(key) ?? '') as Map<String, Object?>;
        periodId = j['periodId']! as String;
        assignmentId = j['assignmentId']! as String;
        report = Report.fromDraftJson(
          periodId,
          assignmentId,
          j['draft']! as Map<String, Object?>,
        );
      } on Object {
        // Damaged beyond reading: nothing can be sent from it.
        await prefs.remove(key);
        continue;
      }
      Catalog catalog;
      try {
        catalog = await ref.read(catalogProvider.future);
      } on Object {
        stillOffline = true;
        continue;
      }
      final seat = catalog.assignmentById(assignmentId);
      if (seat == null) {
        // The seat is gone: there is nobody to send it for (the draft stays).
        await prefs.remove(key);
        continue;
      }
      final rec = report.reconciliation(seat);
      if (rec.lostAnswers || rec.openCounts > 0 || rec.openTargets > 0) {
        await _keepAsDraft(key, periodId, assignmentId, rec);
        continue;
      }
      try {
        final saved = await repo.sendReport(rec.report);
        await prefs.remove(key);
        await prefs.remove(_noteKey(key));
        await prefs.remove(key.replaceFirst('pending/', 'draft/'));
        await prefs.remove(key.replaceFirst('pending/', 'draftat/'));
        final period = _period;
        if (period?.id == periodId && state.assignmentId == assignmentId) {
          state = state.copyWith(
            phase: SendPhase.sent,
            sentAt: saved.submittedAt,
            clearMessage: true,
            clearNotice: true,
            clearDraftSavedAt: true,
          );
        }
      } on UnauthorizedException {
        // Keep the entry; the next sign in starts this again.
        return;
      } on RepositoryException catch (e) {
        // The server refused it for good; drop the queue entry and tell the person.
        await prefs.remove(key);
        if (state.assignmentId == assignmentId) {
          state = state.copyWith(phase: SendPhase.failed, message: e.message);
        }
      } on NetworkException {
        stillOffline = true;
      } on Object {
        stillOffline = true;
      }
    }
    if (stillOffline) _scheduleRetry();
  }

  /// A waiting report that no longer fits its seat becomes a draft again.
  Future<void> _keepAsDraft(
    String pendingKey,
    String periodId,
    String assignmentId,
    Reconciliation rec,
  ) async {
    final prefs = ref.read(prefsProvider);
    final notice =
        reconcileNotice(rec) ??
        'Your manager changed this role while your report waited to be sent. '
            'It was not sent. Please fill in the new numbers and targets, '
            'then send it.';
    final draftKey = pendingKey.replaceFirst('pending/', 'draft/');
    await prefs.setString(draftKey, jsonEncode(rec.report.toDraftJson()));
    await prefs.setString(_noteKey(pendingKey), notice);
    await prefs.remove(pendingKey);
    if (_period?.id == periodId && state.assignmentId == assignmentId) {
      await _load(assignmentId);
    }
  }
}

final formControllerProvider = NotifierProvider<FormController, FormModel>(
  FormController.new,
);

/// Where something is still missing in the form, in the order of the page.
enum FormPart { who, numbers, targets }

class FormGap {
  const FormGap(this.fieldId, this.part, this.message);

  /// Id of the control to focus, see [FieldFocus].
  final String fieldId;
  final FormPart part;

  /// Plain words shown under the control.
  final String message;
}

String numberFieldId(String metricId, int month) => 'm:$metricId:$month';
String targetFieldId(String kpiId) => 'k:$kpiId';

/// What a person still has to fill in before Send works, in page order:
/// name, country, role, each missing number, each unanswered target. Pure, so
/// the progress summary, the inline errors and the focus after a failed Send
/// all agree.
List<FormGap> formGaps(Report r, Assignment a) {
  final gaps = <FormGap>[];
  final who = r.reporter ?? const Reporter();
  final seen = <String>{};
  for (final p in who.problems()) {
    final lower = p.toLowerCase();
    for (final f in const ['name', 'country', 'role']) {
      if (lower.contains('your $f') && seen.add(f)) {
        gaps.add(FormGap(f, FormPart.who, p));
      }
    }
  }
  for (final m in a.metrics) {
    final v = r.values[m.id];
    for (var i = 0; i < 3; i++) {
      final x = v != null && i < v.length ? v[i] : null;
      if (x == null || x < 0) {
        gaps.add(
          FormGap(numberFieldId(m.id, i), FormPart.numbers, 'Enter a number'),
        );
      }
    }
  }
  for (final k in a.kpis) {
    if (r.kpis[k.id] == null) {
      gaps.add(
        FormGap(
          targetFieldId(k.id),
          FormPart.targets,
          'Choose Met, Partly or Missed',
        ),
      );
    }
  }
  return gaps;
}

/// Focus nodes of the controls that can be missing, by id, so a failed Send or
/// the progress summary can move focus (and the page) to one of them.
class FieldFocus {
  final _nodes = <String, FocusNode>{};

  FocusNode node(String id) =>
      _nodes.putIfAbsent(id, () => FocusNode(debugLabel: id));

  /// Scrolls to the control and focuses it. False when it is not on screen.
  bool focus(String id, {bool animate = true}) {
    final n = _nodes[id];
    final ctx = n?.context;
    if (n == null || ctx == null) return false;
    unawaited(
      Scrollable.ensureVisible(
        ctx,
        alignment: 0.25,
        duration: animate ? const Duration(milliseconds: 250) : Duration.zero,
        curve: Curves.easeOut,
      ),
    );
    n.requestFocus();
    return true;
  }

  void dispose() {
    for (final n in _nodes.values) {
      n.dispose();
    }
    _nodes.clear();
  }
}

final fieldFocusProvider = Provider<FieldFocus>((ref) {
  final f = FieldFocus();
  ref.onDispose(f.dispose);
  return f;
});

/// Words for the person when a saved draft no longer matches the seat, or null
/// when nothing they typed was lost.
String? reconcileNotice(Reconciliation rec) {
  if (!rec.lostAnswers && rec.openCounts == 0 && rec.openTargets == 0) {
    return null;
  }
  final lost = <String>[
    if (rec.droppedCounts > 0)
      '${rec.droppedCounts} ${rec.droppedCounts == 1 ? 'count' : 'counts'}',
    if (rec.droppedTargets > 0)
      '${rec.droppedTargets} ${rec.droppedTargets == 1 ? 'target' : 'targets'}',
  ];
  if (lost.isEmpty) return null;
  return 'Your manager changed this role since you saved your draft. '
      '${lost.join(' and ')} you answered no longer exist and ${lost.length == 1 && rec.droppedCounts + rec.droppedTargets == 1 ? 'was' : 'were'} removed. '
      'Please check the numbers and targets.';
}
