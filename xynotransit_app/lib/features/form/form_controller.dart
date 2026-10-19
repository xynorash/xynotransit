import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/repository.dart';
import '../../domain/catalog.dart';
import '../../domain/enums.dart';
import '../../domain/period.dart';
import '../../domain/report.dart';

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
  }) => FormModel(
    assignmentId: assignmentId ?? this.assignmentId,
    report: report ?? this.report,
    sentAt: clearSentAt ? null : (sentAt ?? this.sentAt),
    problems: problems ?? this.problems,
    phase: phase ?? this.phase,
    message: clearMessage ? null : (message ?? this.message),
    epoch: epoch ?? this.epoch,
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
    ref.onDispose(() => _retry?.cancel());
    return const FormModel();
  }

  Catalog get _catalog => ref.read(catalogProvider).requireValue;
  Period? get _period => ref.read(periodProvider).value;

  String _draftKey(Period p, String assignmentId) =>
      'draft/${Period.dateOnly(p.startMonth)}/$assignmentId';
  String _pendingKey(Period p, String assignmentId) =>
      'pending/${Period.dateOnly(p.startMonth)}/$assignmentId';

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
    var working = draft ?? _workingCopy(existing, period.id, assignmentId);
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
    );
    _saveDraft();
  }

  void _saveDraft() {
    final period = _period;
    final r = state.report;
    final id = state.assignmentId;
    if (period == null || r == null || id == null) return;
    unawaited(
      ref
          .read(prefsProvider)
          .setString(_draftKey(period, id), jsonEncode(r.toDraftJson())),
    );
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
    final t = (r.kpis[kpiId]?.comment ?? _comments.remove(kpiId) ?? '').trim();
    if (t.isEmpty) return null;
    return t.length > kpiCommentMax ? t.substring(0, kpiCommentMax) : t;
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
    final t = text.trim();
    final comment = t.isEmpty
        ? null
        : (t.length > kpiCommentMax ? t.substring(0, kpiCommentMax) : t);
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
      await prefs.remove(_pendingKey(period, r.assignmentId));
      if (state.assignmentId == r.assignmentId) {
        state = state.copyWith(
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

  /// Sends every report that was saved on this device while offline.
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
      final raw = prefs.getString(key);
      if (raw == null) continue;
      final j = jsonDecode(raw) as Map<String, Object?>;
      final periodId = j['periodId']! as String;
      final assignmentId = j['assignmentId']! as String;
      final report = Report.fromDraftJson(
        periodId,
        assignmentId,
        j['draft']! as Map<String, Object?>,
      );
      try {
        final saved = await repo.sendReport(report);
        await prefs.remove(key);
        await prefs.remove(key.replaceFirst('pending/', 'draft/'));
        final period = _period;
        if (period?.id == periodId && state.assignmentId == assignmentId) {
          state = state.copyWith(
            phase: SendPhase.sent,
            sentAt: saved.submittedAt,
            clearMessage: true,
          );
        }
      } on NetworkException {
        stillOffline = true;
      } on RepositoryException catch (e) {
        // The server refused it for good; drop the queue entry and tell the person.
        await prefs.remove(key);
        if (state.assignmentId == assignmentId) {
          state = state.copyWith(phase: SendPhase.failed, message: e.message);
        }
      }
    }
    if (stillOffline) _scheduleRetry();
  }
}

final formControllerProvider = NotifierProvider<FormController, FormModel>(
  FormController.new,
);
