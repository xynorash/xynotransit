import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../core/format.dart';
import '../../core/theme/tokens.dart';
import '../../core/widgets.dart';
import '../../domain/catalog.dart';
import '../../domain/deck.dart';
import '../../domain/enums.dart';
import '../../domain/report.dart';
import '../form/form_controller.dart';
import 'csv_button.dart';
import 'report_counts.dart';

/// "Reports received": progress bar, live table and who is still missing.
class ReceivedCard extends ConsumerStatefulWidget {
  const ReceivedCard({super.key});

  @override
  ConsumerState<ReceivedCard> createState() => _ReceivedCardState();
}

class _ReceivedCardState extends ConsumerState<ReceivedCard> {
  /// assignmentId -> submittedAt of the rows already on screen.
  final Map<String, DateTime?> _seen = {};
  final Set<String> _fresh = {};
  bool _first = true;
  String _query = '';

  void _onReports(List<Report> reports) {
    final rows = reports.where((r) => r.isSubmitted);
    for (final r in rows) {
      final known = _seen.containsKey(r.assignmentId);
      if (!_first && (!known || _seen[r.assignmentId] != r.submittedAt)) {
        _fresh.add(
          '${r.assignmentId}@${r.submittedAt?.microsecondsSinceEpoch}',
        );
      }
      _seen[r.assignmentId] = r.submittedAt;
    }
    _first = false;
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    ref.listen(periodProvider, (prev, next) {
      if (prev?.value?.id != next.value?.id) {
        _seen.clear();
        _fresh.clear();
        _first = true;
      }
    });
    ref.listen(reportsProvider, (prev, next) {
      final data = next.value;
      if (data != null) setState(() => _onReports(data));
    });
    // The first value can arrive before the listener is attached.
    final reportsAsync = ref.watch(reportsProvider);
    if (_first && reportsAsync.hasValue) _onReports(reportsAsync.requireValue);

    // The table lists every sent report, also those of people switched off
    // since, so the catalog here includes the inactive.
    final catalog = ref.watch(catalogWithInactiveProvider).value;
    final period = ref.watch(periodProvider).value;
    final reports = (reportsAsync.value ?? const <Report>[])
        .where((r) => r.isSubmitted)
        .toList();
    if (catalog == null || period == null) {
      return const XCard(child: SizedBox(height: 60));
    }

    final byAssignment = {for (final r in reports) r.assignmentId: r};
    // A seat counts only when the seat and its person are both active, the
    // same way the server and the tiles count. Reports of switched-off seats
    // stay in the table and the CSV, but are never part of "N of M".
    final counts = ReportCounts.of(catalog, reports);
    final progress = PeriodProgress(
      expected: counts.expected,
      submitted: counts.submitted,
    );
    final rows = [
      for (final a in catalog.assignments)
        if (byAssignment[a.id] != null) (a, byAssignment[a.id]!),
    ];
    final q = _query.trim().toLowerCase();
    final shown = q.isEmpty
        ? rows
        : [
            for (final (a, r) in rows)
              if (catalog.labelOf(a).toLowerCase().contains(q) ||
                  catalog.teamOf(a).name.toLowerCase().contains(q) ||
                  (r.reporter?.name ?? '').toLowerCase().contains(q) ||
                  (r.reporter?.country ?? '').toLowerCase().contains(q) ||
                  (r.reporter?.role ?? '').toLowerCase().contains(q))
                (a, r),
          ];
    final missing = [
      for (final a in catalog.assignments)
        if (byAssignment[a.id] == null && catalog.isExpected(a)) a,
    ];

    return XCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Expanded(
                child: Semantics(
                  header: true,
                  child: Text(
                    'Reports received',
                    style: bodyStyle(
                      context,
                      size: 20,
                      weight: FontWeight.w700,
                      height: 1.25,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Flexible(
                child: Semantics(
                  liveRegion: true,
                  child: Text(
                    '${progress.submitted} of ${progress.expected} · ${period.label}',
                    textAlign: TextAlign.right,
                    style: monoStyle(context, size: 15),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _ProgressBar(fraction: progress.fraction),
          if (counts.switchedOff > 0) ...[
            const SizedBox(height: 8),
            Text(
              'Not counted above: ${counts.switchedOff} '
              '${counts.switchedOff == 1 ? 'report' : 'reports'} from '
              '${counts.switchedOff == 1 ? 'a switched-off person' : 'switched-off people'}. '
              'They stay in the table, the CSV and the slides.',
              key: const ValueKey('switched-off-note'),
              style: bodyStyle(context, size: 14, color: t.muted, height: 1.4),
            ),
          ],
          const SizedBox(height: 12),
          if (missing.isEmpty)
            Semantics(
              liveRegion: true,
              child: Text(
                'Everyone has sent their report.',
                style: bodyStyle(context, weight: FontWeight.w700, color: t.ok),
              ),
            )
          else
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Still waiting for',
                  style: bodyStyle(
                    context,
                    size: 15,
                    color: t.muted,
                    weight: FontWeight.w500,
                    height: 1.3,
                  ),
                ),
                const SizedBox(height: 8),
                if (ref.watch(isControllerProvider)) ...[
                  Text(
                    'Generate with what is in: the slides do not need everyone.',
                    key: const ValueKey('generate-partial-hint'),
                    style: bodyStyle(context, size: 14, color: t.muted),
                  ),
                  const SizedBox(height: 8),
                ],
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final a in missing)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 5,
                        ),
                        decoration: BoxDecoration(
                          color: t.soft,
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          catalog.labelOf(a),
                          style: bodyStyle(context, size: 14, height: 1.3),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          const SizedBox(height: 16),
          Align(
            alignment: Alignment.centerRight,
            child: CsvExportButton(
              period: period,
              catalog: catalog,
              reports: reports,
            ),
          ),
          const SizedBox(height: 12),
          if (rows.isEmpty)
            DashedBox(
              child: Text(
                'The table appears here as soon as the first report for this period is sent.',
                textAlign: TextAlign.center,
                style: bodyStyle(
                  context,
                  size: 15,
                  color: t.muted,
                  height: 1.4,
                ),
              ),
            )
          else ...[
            if (rows.length > 6) ...[
              Semantics(
                label: 'Search the reports',
                container: true,
                child: TextField(
                  key: const ValueKey('reports-search'),
                  style: bodyStyle(context),
                  decoration: xInput(
                    context,
                    hint: 'Search by name, role or team',
                  ).copyWith(prefixIcon: const Icon(Icons.search)),
                  onChanged: (v) => setState(() => _query = v),
                ),
              ),
              const SizedBox(height: 12),
            ],
            if (shown.isEmpty)
              Text(
                'No report matches "${_query.trim()}".',
                style: bodyStyle(context, color: t.muted),
              )
            else
              _ReportTable(rows: shown, catalog: catalog, fresh: _fresh),
          ],
        ],
      ),
    );
  }
}

class _ProgressBar extends StatelessWidget {
  const _ProgressBar({required this.fraction});

  final double fraction;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final duration = reducedMotion(context)
        ? Duration.zero
        : const Duration(milliseconds: 300);
    return Semantics(
      label: 'Progress',
      value: '${(fraction * 100).round()} percent',
      child: ExcludeSemantics(
        child: ClipRRect(
          borderRadius: BorderRadius.circular(999),
          child: Container(
            height: 10,
            color: t.soft,
            alignment: Alignment.centerLeft,
            child: LayoutBuilder(
              builder: (context, c) => AnimatedContainer(
                duration: duration,
                width: c.maxWidth * fraction,
                color: t.ok,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ReportTable extends ConsumerWidget {
  const _ReportTable({
    required this.rows,
    required this.catalog,
    required this.fresh,
  });

  final List<(Assignment, Report)> rows;
  final Catalog catalog;
  final Set<String> fresh;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.tokens;
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: t.line),
        borderRadius: BorderRadius.circular(12),
      ),
      clipBehavior: Clip.antiAlias,
      child: LayoutBuilder(
        builder: (context, c) {
          if (c.maxWidth < 500) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final (a, r) in rows)
                  _FlashRow(
                    key: ValueKey(
                      '${a.id}@${r.submittedAt?.microsecondsSinceEpoch}',
                    ),
                    flash: fresh.contains(
                      '${a.id}@${r.submittedAt?.microsecondsSinceEpoch}',
                    ),
                    child: _DataRow(
                      assignment: a,
                      report: r,
                      catalog: catalog,
                      compact: true,
                    ),
                  ),
              ],
            );
          }
          final width = c.maxWidth;
          return SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SizedBox(
              width: width,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const _HeaderRow(),
                  for (final (a, r) in rows)
                    _FlashRow(
                      key: ValueKey(
                        '${a.id}@${r.submittedAt?.microsecondsSinceEpoch}',
                      ),
                      flash: fresh.contains(
                        '${a.id}@${r.submittedAt?.microsecondsSinceEpoch}',
                      ),
                      child: _DataRow(
                        assignment: a,
                        report: r,
                        catalog: catalog,
                      ),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

const _colPerson = 5;
const _colNumbers = 8;
const _colKpi = 4;
const _colNotes = 3;

class _HeaderRow extends StatelessWidget {
  const _HeaderRow();

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final style = monoStyle(context, size: 12).copyWith(letterSpacing: 0.72);
    Widget cell(int flex, String s) => Expanded(
      flex: flex,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Text(s.toUpperCase(), style: style),
      ),
    );
    return Container(
      color: t.soft,
      child: Row(
        children: [
          cell(_colPerson, 'Person'),
          cell(_colNumbers, 'Numbers by month'),
          cell(_colKpi, 'KPI'),
          cell(_colNotes, 'Notes'),
        ],
      ),
    );
  }
}

/// Fades a highlight out when a row has just arrived.
class _FlashRow extends StatelessWidget {
  const _FlashRow({super.key, required this.flash, required this.child});

  final bool flash;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final decorated = DecoratedBox(
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: t.line)),
      ),
      child: child,
    );
    if (!flash || reducedMotion(context)) return decorated;
    return TweenAnimationBuilder<Color?>(
      tween: ColorTween(begin: t.flash, end: t.flash.withValues(alpha: 0)),
      duration: const Duration(milliseconds: 2400),
      builder: (context, color, child) =>
          ColoredBox(color: color ?? Colors.transparent, child: child),
      child: decorated,
    );
  }
}

class _DataRow extends ConsumerWidget {
  const _DataRow({
    required this.assignment,
    required this.report,
    required this.catalog,
    this.compact = false,
  });

  final bool compact;
  final Assignment assignment;
  final Report report;
  final Catalog catalog;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.tokens;
    final person = catalog.personOf(assignment);
    final team = catalog.teamOf(assignment);
    const pad = EdgeInsets.symmetric(horizontal: 12, vertical: 12);
    Widget cell(int flex, Widget child) {
      final padded = Padding(
        padding: compact
            ? const EdgeInsets.symmetric(horizontal: 12, vertical: 6)
            : pad,
        child: child,
      );
      return compact ? padded : Expanded(flex: flex, child: padded);
    }

    final inactive = !catalog.isExpected(assignment);
    final typed = report.reporter;
    // What the slides say, when the person wrote something else than the profile.
    final differs =
        typed != null &&
        (typed.name.trim() != person.fullName ||
            typed.country.trim() != team.name ||
            typed.role.trim() != assignment.roleTitle);
    final firstNote = [for (final k in NoteKind.values) ...report.notesOf(k)]
        .firstOrNull;
    final cells = [
      cell(
        _colPerson,
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 2,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  seatName(catalog, assignment),
                  style: bodyStyle(
                    context,
                    weight: FontWeight.w700,
                    height: 1.3,
                  ),
                ),
                if (inactive)
                  Container(
                    key: ValueKey('inactive-tag-${assignment.id}'),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 1,
                    ),
                    decoration: BoxDecoration(
                      color: t.soft,
                      border: Border.all(color: t.line),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      'Inactive',
                      style: bodyStyle(
                        context,
                        size: 12,
                        weight: FontWeight.w700,
                        color: t.muted,
                        height: 1.4,
                      ),
                    ),
                  ),
              ],
            ),
            Text(
              '${team.name} · ${assignment.roleTitle}',
              style: bodyStyle(context, size: 13, color: t.muted, height: 1.3),
            ),
            if (differs)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  'On the slides: ${typed.name.trim()} · '
                  '${typed.country.trim()} · ${typed.role.trim()}',
                  key: ValueKey('typed-${assignment.id}'),
                  style: bodyStyle(
                    context,
                    size: 13,
                    color: t.muted,
                    height: 1.3,
                  ),
                ),
              ),
            // A switched-off seat is not on the form any more.
            if (!inactive) ...[
              const SizedBox(height: 6),
              SmallButton(
                label: 'Edit',
                semanticLabel:
                    'Edit report of ${person.fullName}, ${assignment.roleTitle}',
                onPressed: () => _edit(context, ref),
              ),
            ],
          ],
        ),
      ),
      cell(
        _colNumbers,
        assignment.hasCounts
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final m in assignment.metrics)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 2),
                      child: Text.rich(
                        TextSpan(
                          style: monoStyle(context, size: 13, color: t.ink),
                          children: [
                            TextSpan(
                              text: '${truncate(m.label, 22)} ',
                              style: monoStyle(context, size: 13),
                            ),
                            TextSpan(
                              text: [
                                for (var i = 0; i < 3; i++)
                                  thousands(report.valueOf(m.id, i)),
                              ].join(' · '),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              )
            : Text('No counts', style: monoStyle(context, size: 13)),
      ),
      cell(
        _colKpi,
        Wrap(
          spacing: 4,
          runSpacing: 4,
          children: [
            for (final s in KpiStatus.values)
              if (report.kpiCount(s) > 0)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 1,
                  ),
                  decoration: BoxDecoration(
                    color: t.statusFill(s.name),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    '${report.kpiCount(s)} ${s.name}',
                    style: bodyStyle(
                      context,
                      size: 13,
                      weight: FontWeight.w700,
                      color: t.statusOn(s.name),
                      height: 1.4,
                    ),
                  ),
                ),
          ],
        ),
      ),
      cell(
        _colNotes,
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${report.noteCount} ${report.noteCount == 1 ? 'point' : 'points'}',
              style: bodyStyle(context, size: 15, height: 1.3),
            ),
            if (firstNote != null)
              Tooltip(
                message: firstNote,
                child: Text(
                  firstNote,
                  key: ValueKey('first-note-${assignment.id}'),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: bodyStyle(
                    context,
                    size: 13,
                    color: t.muted,
                    height: 1.3,
                  ),
                ),
              ),
          ],
        ),
      ),
    ];
    if (compact) {
      // Phones: one stacked block per report, nothing hidden to the right.
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: cells,
        ),
      );
    }
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: cells);
  }

  void _edit(BuildContext context, WidgetRef ref) {
    ref.read(formControllerProvider.notifier).edit(report);
    context.go('/report');
  }
}
