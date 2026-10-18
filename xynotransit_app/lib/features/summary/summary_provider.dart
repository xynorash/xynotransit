import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../domain/catalog.dart';
import '../../domain/enums.dart';
import '../../domain/report.dart';
import '../../domain/summary.dart';

/// How long to wait after the last change before asking for a new summary.
const summaryDebounce = Duration(milliseconds: 600);

/// What matters to the numbers: which reports are sent, and when. Drafts
/// being typed do not change it, so they never cause a refetch.
final _sentSignatureProvider = Provider<String>((ref) {
  final reports = ref.watch(reportsProvider).value ?? const <Report>[];
  final parts = [
    for (final r in reports)
      if (r.isSubmitted)
        '${r.assignmentId}@${r.submittedAt?.microsecondsSinceEpoch}',
  ]..sort();
  return parts.join(',');
});

/// Shape of the catalog that changes the summary (teams, seats, people).
final _catalogSignatureProvider = Provider<String>((ref) {
  final c = ref.watch(catalogProvider).value;
  if (c == null) return '';
  return [
    for (final t in c.teams) 't${t.id}:${t.name}',
    for (final a in c.assignments)
      'a${a.id}:${a.teamId}:${a.roleTitle}:${a.active}:'
          '${a.metrics.map((m) => m.label).join('|')}',
    for (final p in c.persons) 'p${p.id}:${p.fullName}',
  ].join(',');
});

/// The summary of the shown period. It reloads when the period changes, and
/// shortly after any report is sent or the catalog changes.
final summaryProvider = FutureProvider<Summary>((ref) async {
  final period = await ref.watch(periodProvider.future);
  final repo = ref.read(repositoryProvider);
  // The first values of the live streams are the starting point. Only changes
  // after them cause a reload. Listening first keeps the streams running.
  String? baseReports;
  String? baseCatalog;
  Timer? timer;
  void later(String? base, String next) {
    if (base == null || base == next) return;
    timer?.cancel();
    timer = Timer(summaryDebounce, ref.invalidateSelf);
  }

  ref.listen(_sentSignatureProvider, (_, next) => later(baseReports, next));
  ref.listen(_catalogSignatureProvider, (_, next) => later(baseCatalog, next));
  ref.onDispose(() => timer?.cancel());
  await ref.read(reportsProvider.future);
  await ref.read(catalogProvider.future);
  baseReports = ref.read(_sentSignatureProvider);
  baseCatalog = ref.read(_catalogSignatureProvider);
  return repo.loadSummary(period.id);
});

/// One piece of free text with who wrote it.
class Written {
  const Written({
    required this.text,
    required this.author,
    required this.team,
    this.target,
    this.status,
  });
  final String text;
  final String author;
  final String team;

  /// For a target comment: the target wording and how it went.
  final String? target;
  final KpiStatus? status;
}

/// The words people wrote in the shown period.
class Writings {
  const Writings({required this.notes, required this.comments});
  final Map<NoteKind, List<Written>> notes;

  /// Comments on targets that were partly met or missed.
  final List<Written> comments;
}

/// Free-text notes and target comments of the submitted reports, in deck order.
/// Rebuilt only when the reports or the catalog change.
final writingsProvider = Provider<Writings>((ref) {
  final reports = ref.watch(reportsProvider).value ?? const <Report>[];
  final catalog = ref.watch(catalogWithInactiveProvider).value;
  final notes = {for (final k in NoteKind.values) k: <Written>[]};
  final comments = <Written>[];
  if (catalog == null) return Writings(notes: notes, comments: comments);
  final byAssignment = {
    for (final r in reports)
      if (r.isSubmitted) r.assignmentId: r,
  };
  final order = [
    for (final a in catalog.assignments)
      if (byAssignment.containsKey(a.id)) a,
  ];
  for (final a in order) {
    final r = byAssignment[a.id]!;
    final author = _nameOf(catalog, a);
    final team = _teamName(catalog, a);
    for (final k in NoteKind.values) {
      for (final text in r.notesOf(k)) {
        notes[k]!.add(Written(text: text, author: author, team: team));
      }
    }
    for (final k in a.kpis) {
      final res = r.kpis[k.id];
      final c = res?.comment?.trim() ?? '';
      if (res == null || res.status == KpiStatus.met || c.isEmpty) continue;
      comments.add(
        Written(
          text: c,
          author: author,
          team: team,
          target: k.text,
          status: res.status,
        ),
      );
    }
  }
  return Writings(notes: notes, comments: comments);
});

String _nameOf(Catalog c, Assignment a) {
  for (final p in c.persons) {
    if (p.id == a.personId) return p.fullName;
  }
  return 'Someone';
}

String _teamName(Catalog c, Assignment a) {
  for (final t in c.teams) {
    if (t.id == a.teamId) return t.name;
  }
  return '';
}
