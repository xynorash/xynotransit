import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/format.dart';
import '../../core/theme/tokens.dart';
import '../../core/widgets.dart';
import '../../data/repository.dart';
import '../../domain/catalog.dart';
import '../../domain/enums.dart';
import '../../domain/period.dart';
import '../../domain/report.dart';
import 'form_controller.dart';

/// Anchor the table's Edit button scrolls to.
final formAnchorKey = GlobalKey(debugLabel: 'form-anchor');

class FormHeader extends StatelessWidget {
  const FormHeader({super.key});

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'XNT-LOG-02 · Xynotransit regional logistics'.toUpperCase(),
          style: monoStyle(
            context,
            size: 13,
            color: t.muted,
          ).copyWith(letterSpacing: 13 * 0.08),
        ),
        const SizedBox(height: 8),
        Semantics(
          header: true,
          child: Text(
            'Logistics Report Builder',
            style: bodyStyle(
              context,
              size: (MediaQuery.sizeOf(context).width * 0.05)
                  .clamp(28, 38)
                  .toDouble(),
              weight: FontWeight.w700,
              height: 1.1,
            ),
          ),
        ),
        const SizedBox(height: 10),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 58 * 10.5),
          child: Text(
            'Fill in this form once for the three months. The controller builds the '
            'meeting slides when everyone has sent theirs.',
            style: bodyStyle(context, color: t.muted),
          ),
        ),
      ],
    );
  }
}

/// Assignments the signed-in person may report for. Controllers can pick anyone.
List<Assignment> allowedAssignments(Catalog catalog, AppUser? user) {
  if (user == null) return const [];
  if (user.isController) return catalog.assignments;
  final id = user.personId;
  return id == null ? const [] : catalog.assignmentsOfPerson(id);
}

/// Keeps the form's person in line with who is signed in: anyone with exactly one
/// seat gets it pre-selected, and nobody keeps a seat they may not report for.
class _AutoSelect extends ConsumerWidget {
  const _AutoSelect();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final catalog = ref.watch(catalogProvider).value;
    final user = ref.watch(userProvider).value;
    final form = ref.watch(formControllerProvider);
    if (catalog != null && user != null) {
      final allowed = allowedAssignments(catalog, user);
      final current = form.assignmentId;
      final stale = current != null && !allowed.any((a) => a.id == current);
      final auto = current == null && allowed.length == 1;
      if (stale || auto) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          unawaited(
            ref
                .read(formControllerProvider.notifier)
                .selectAssignment(auto ? allowed.first.id : null),
          );
        });
      }
    }
    return const SizedBox.shrink();
  }
}

class FormCards extends ConsumerWidget {
  const FormCards({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final form = ref.watch(formControllerProvider);
    final catalog = ref.watch(catalogProvider).value;
    final a = form.hasPerson && catalog != null
        ? catalog.assignmentById(form.assignmentId)
        : null;
    return Column(
      key: formAnchorKey,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _AutoSelect(),
        const PeriodPersonCard(),
        if (a != null) ...[
          if (a.hasCounts) ...[
            const SizedBox(height: 20),
            NumbersCard(assignment: a),
          ],
          const SizedBox(height: 20),
          KpiCard(assignment: a),
          const SizedBox(height: 20),
          const NotesCard(),
          const SizedBox(height: 20),
          const SubmitRow(),
        ],
      ],
    );
  }
}

/// First month and year of the three-month period. Shared by the employee form
/// and the manager dashboard, so both always look at the same period.
class PeriodFields extends ConsumerStatefulWidget {
  const PeriodFields({super.key});

  @override
  ConsumerState<PeriodFields> createState() => _PeriodFieldsState();
}

class _PeriodFieldsState extends ConsumerState<PeriodFields> {
  late final TextEditingController _year = TextEditingController(
    text: ref.read(periodSelectionProvider).year.toString(),
  );

  @override
  void dispose() {
    _year.dispose();
    super.dispose();
  }

  void _setStart(int year, int month) {
    ref
        .read(periodSelectionProvider.notifier)
        .select(Period.start(year, month));
  }

  @override
  Widget build(BuildContext context) {
    final start = ref.watch(periodSelectionProvider);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Labeled(
            label: 'First month of the three',
            child: DropdownButtonFormField<int>(
              initialValue: start.month,
              isExpanded: true,
              decoration: xInput(context),
              items: [
                for (var m = 1; m <= 12; m++)
                  DropdownMenuItem(value: m, child: Text(monthLong[m - 1])),
              ],
              onChanged: (m) {
                if (m != null) _setStart(start.year, m);
              },
            ),
          ),
        ),
        const SizedBox(width: 14),
        SizedBox(
          width: 110,
          child: Labeled(
            label: 'Year',
            child: TextField(
              controller: _year,
              keyboardType: TextInputType.number,
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(4),
              ],
              decoration: xInput(context),
              style: bodyStyle(context),
              onChanged: (s) {
                final y = int.tryParse(s);
                if (y != null && y >= 2024 && y <= 2100) {
                  _setStart(y, start.month);
                }
              },
            ),
          ),
        ),
      ],
    );
  }
}

class PeriodPersonCard extends ConsumerWidget {
  const PeriodPersonCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.tokens;
    final start = ref.watch(periodSelectionProvider);
    final form = ref.watch(formControllerProvider);
    final catalog = ref.watch(catalogProvider).value;
    final user = ref.watch(userProvider).value;
    final allowed = catalog == null
        ? const <Assignment>[]
        : allowedAssignments(catalog, user);
    final isManager = user?.isController ?? false;
    final selected = allowed.any((a) => a.id == form.assignmentId)
        ? form.assignmentId
        : null;
    final period = ref.watch(periodProvider);
    // Only someone who can report for several seats chooses between them.
    final showChooser = allowed.length > 1;

    return StepCard(
      step: 1,
      title: 'Who you are',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (showChooser && catalog != null) ...[
            Labeled(
              label: 'Reporting for',
              child: _SeatChooser(
                catalog: catalog,
                allowed: allowed,
                selected: selected,
                epoch: form.epoch,
                withNames: isManager,
              ),
            ),
            const SizedBox(height: 14),
          ],
          if (form.hasPerson) ...[
            const IdentityFields(),
            const SizedBox(height: 14),
          ],
          const PeriodFields(),
          const SizedBox(height: 12),
          Text(
            period.hasValue
                ? 'This report covers ${period.requireValue.label}.'
                : 'This report covers ${Period.labelFor(start)}.',
            style: monoStyle(context),
          ),
          if (user != null && allowed.isEmpty) ...[
            const SizedBox(height: 12),
            SoftBanner(
              child: Text(
                'Your account is not linked to a person yet. Ask the controller to add your email.',
                style: bodyStyle(context, size: 15, height: 1.4),
              ),
            ),
          ],
          if (form.sentAt != null) ...[
            const SizedBox(height: 12),
            SoftBanner(
              child: Text(
                'You already sent this report on ${shortDate(form.sentAt!)}. Sending again replaces it.',
                style: bodyStyle(context, size: 15, height: 1.4),
              ),
            ),
          ],
          if (!form.hasPerson && showChooser) ...[
            const SizedBox(height: 12),
            Text(
              'Choose who you are reporting for to see the fields for the role.',
              style: bodyStyle(context, size: 15, color: t.muted, height: 1.4),
            ),
          ],
        ],
      ),
    );
  }
}

/// Picks the seat to report for. Controllers see everyone, grouped by team;
/// an employee with several seats sees the role titles of their seats.
class _SeatChooser extends ConsumerWidget {
  const _SeatChooser({
    required this.catalog,
    required this.allowed,
    required this.selected,
    required this.epoch,
    required this.withNames,
  });

  final Catalog catalog;
  final List<Assignment> allowed;
  final String? selected;
  final int epoch;
  final bool withNames;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.tokens;
    final items = <DropdownMenuItem<String?>>[
      const DropdownMenuItem<String?>(
        value: null,
        child: Text('Choose your name'),
      ),
    ];
    if (withNames) {
      for (final team in catalog.teams) {
        final inTeam = allowed.where((a) => a.teamId == team.id).toList();
        if (inTeam.isEmpty) continue;
        items.add(
          DropdownMenuItem<String?>(
            value: 'team:${team.id}',
            enabled: false,
            child: Text(
              team.name.toUpperCase(),
              style: monoStyle(
                context,
                size: 12,
                color: t.muted,
              ).copyWith(letterSpacing: 0.9),
            ),
          ),
        );
        for (final a in inTeam) {
          items.add(
            DropdownMenuItem<String?>(
              value: a.id,
              child: Text(catalog.labelOf(a)),
            ),
          );
        }
      }
    } else {
      for (final a in allowed) {
        items.add(
          DropdownMenuItem<String?>(value: a.id, child: Text(a.roleTitle)),
        );
      }
    }
    return DropdownButtonFormField<String?>(
      initialValue: selected,
      key: ValueKey('person-${selected ?? 'none'}-${allowed.length}-$epoch'),
      isExpanded: true,
      decoration: xInput(context),
      items: items,
      onChanged: (id) => unawaited(
        ref.read(formControllerProvider.notifier).selectAssignment(id),
      ),
    );
  }
}

/// Characters that cannot be seen or that act as controls.
final _invisible = RegExp(r'[\u0000-\u001F\u007F-\u009F​-‏ - ⁠-⁯﻿]');

/// Name, country and role, typed by the reporter. They start from the profile
/// and are what the slides show.
class IdentityFields extends ConsumerWidget {
  const IdentityFields({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final epoch = ref.watch(formControllerProvider.select((f) => f.epoch));
    final problems = ref.watch(
      formControllerProvider.select((f) => f.problems),
    );
    final r =
        ref.read(formControllerProvider).report?.reporter ?? const Reporter();
    final ctl = ref.read(formControllerProvider.notifier);
    String? errorFor(String field) {
      for (final p in problems) {
        if (p.toLowerCase().contains('your $field')) return p;
      }
      return null;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _IdentityField(
          key: ValueKey('$epoch-name'),
          label: 'Name',
          fieldKey: const ValueKey('reporter-name'),
          initial: r.name,
          error: errorFor('name'),
          onChanged: (v) => ctl.setReporter(name: v),
        ),
        const SizedBox(height: 12),
        _IdentityField(
          key: ValueKey('$epoch-country'),
          label: 'Country',
          fieldKey: const ValueKey('reporter-country'),
          initial: r.country,
          error: errorFor('country'),
          onChanged: (v) => ctl.setReporter(country: v),
        ),
        const SizedBox(height: 12),
        _IdentityField(
          key: ValueKey('$epoch-role'),
          label: 'Role',
          fieldKey: const ValueKey('reporter-role'),
          initial: r.role,
          error: errorFor('role'),
          onChanged: (v) => ctl.setReporter(role: v),
        ),
      ],
    );
  }
}

class _IdentityField extends StatefulWidget {
  const _IdentityField({
    super.key,
    required this.label,
    required this.fieldKey,
    required this.initial,
    required this.onChanged,
    this.error,
  });

  final String label;
  final Key fieldKey;
  final String initial;
  final String? error;
  final ValueChanged<String> onChanged;

  @override
  State<_IdentityField> createState() => _IdentityFieldState();
}

class _IdentityFieldState extends State<_IdentityField> {
  late final TextEditingController _c = TextEditingController(
    text: widget.initial,
  );

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final deco = xInput(context).copyWith(
      errorText: widget.error,
      errorStyle: bodyStyle(context, size: 14, color: t.bad, height: 1.3),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: t.bad),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: t.bad, width: 2),
      ),
    );
    return Labeled(
      label: widget.label,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: TextField(
              key: widget.fieldKey,
              controller: _c,
              maxLength: Reporter.maxLength,
              maxLengthEnforcement: MaxLengthEnforcement.enforced,
              inputFormatters: [FilteringTextInputFormatter.deny(_invisible)],
              keyboardType: TextInputType.text,
              style: bodyStyle(context),
              decoration: deco,
              onChanged: (v) {
                setState(() {});
                widget.onChanged(v);
              },
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 52,
            height: 46,
            child: Align(
              alignment: Alignment.centerRight,
              child: Semantics(
                label: '${_c.text.length} of ${Reporter.maxLength} characters',
                excludeSemantics: true,
                child: Text(
                  '${_c.text.length}/${Reporter.maxLength}',
                  style: monoStyle(context, size: 12, color: t.muted),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class NumbersCard extends ConsumerWidget {
  const NumbersCard({super.key, required this.assignment});

  final Assignment assignment;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final form = ref.watch(formControllerProvider);
    final period = ref.watch(periodProvider).value;
    final start = ref.watch(periodSelectionProvider);
    final months = (period ?? Period(id: '', startMonth: start)).months;
    final report = form.report!;
    final t = context.tokens;
    return StepCard(
      step: 2,
      title: 'Your numbers, month by month',
      hint: 'Type 0 when there were none. Totals update as you type.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < assignment.metrics.length; i++) ...[
            if (i > 0) const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                border: Border.all(color: t.line),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      ExcludeSemantics(
                        child: Container(
                          width: 12,
                          height: 12,
                          decoration: BoxDecoration(
                            color: seriesColor(assignment.metrics[i].series),
                            borderRadius: BorderRadius.circular(3),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          assignment.metrics[i].label,
                          style: bodyStyle(
                            context,
                            weight: FontWeight.w700,
                            height: 1.3,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Semantics(
                        liveRegion: true,
                        child: Text(
                          'Total ${thousands(report.totalOf(assignment.metrics[i].id))}',
                          style: monoStyle(context),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      for (var m = 0; m < 3; m++) ...[
                        if (m > 0) const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              ExcludeSemantics(
                                child: Text(
                                  months[m].short,
                                  style: monoStyle(context, size: 13),
                                ),
                              ),
                              const SizedBox(height: 4),
                              Semantics(
                                label:
                                    '${assignment.metrics[i].label}, ${months[m].long}',
                                textField: true,
                                child: NumberField(
                                  key: ValueKey(
                                    '${form.epoch}-${assignment.metrics[i].id}-$m',
                                  ),
                                  value:
                                      (report.values[assignment
                                          .metrics[i]
                                          .id] ??
                                      const [null, null, null])[m],
                                  onChanged: (v) => ref
                                      .read(formControllerProvider.notifier)
                                      .setValue(assignment.metrics[i].id, m, v),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class KpiCard extends ConsumerWidget {
  const KpiCard({super.key, required this.assignment});

  final Assignment assignment;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final form = ref.watch(formControllerProvider);
    final report = form.report!;
    final t = context.tokens;
    return StepCard(
      step: 3,
      title: 'KPI: did you reach your targets?',
      hint: 'Over the three months. Partly means reached for some shipments, not all.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (assignment.kpis.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                'No targets for this role. Nothing to answer here.',
                style: bodyStyle(context),
              ),
            ),
          for (var i = 0; i < assignment.kpis.length; i++)
            Container(
              padding: const EdgeInsets.symmetric(vertical: 14),
              decoration: BoxDecoration(
                border: i == 0 ? null : Border(top: BorderSide(color: t.line)),
              ),
              child: Semantics(
                label: assignment.kpis[i].text,
                container: true,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    ExcludeSemantics(
                      child: Text(
                        assignment.kpis[i].text,
                        style: bodyStyle(context, weight: FontWeight.w500),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        for (final (j, s) in KpiStatus.values.indexed) ...[
                          if (j > 0) const SizedBox(width: 6),
                          Expanded(
                            child: _Segment(
                              status: s,
                              selected:
                                  report.kpis[assignment.kpis[i].id]?.status ==
                                  s,
                              onTap: () => ref
                                  .read(formControllerProvider.notifier)
                                  .setKpi(assignment.kpis[i].id, s),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 10),
                    _CountedField(
                      key: ValueKey(
                        '${form.epoch}-comment-${assignment.kpis[i].id}',
                      ),
                      initial: ref
                          .read(formControllerProvider.notifier)
                          .kpiComment(assignment.kpis[i].id),
                      maxLength: kpiCommentMax,
                      hint: 'Comment (optional)',
                      semanticLabel:
                          'Comment (optional) for target ${i + 1}: ${assignment.kpis[i].text}',
                      multiline: true,
                      onChanged: (v) => ref
                          .read(formControllerProvider.notifier)
                          .setKpiComment(assignment.kpis[i].id, v),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// A text box with a live "12 of 70" counter, for the person's own words.
class _CountedField extends StatefulWidget {
  const _CountedField({
    super.key,
    required this.initial,
    required this.maxLength,
    required this.hint,
    required this.semanticLabel,
    required this.onChanged,
    this.multiline = false,
  });

  final String initial;
  final int maxLength;
  final String hint;
  final String semanticLabel;
  final bool multiline;
  final ValueChanged<String> onChanged;

  @override
  State<_CountedField> createState() => _CountedFieldState();
}

class _CountedFieldState extends State<_CountedField> {
  late final TextEditingController _c = TextEditingController(
    text: widget.initial,
  );

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final field = Semantics(
      label: widget.semanticLabel,
      textField: true,
      child: TextField(
        controller: _c,
        maxLength: widget.maxLength,
        maxLengthEnforcement: MaxLengthEnforcement.enforced,
        minLines: widget.multiline ? 2 : 1,
        maxLines: widget.multiline ? 4 : 1,
        keyboardType: widget.multiline
            ? TextInputType.multiline
            : TextInputType.text,
        style: bodyStyle(context),
        decoration: xInput(context, hint: widget.hint),
        onChanged: (v) {
          setState(() {});
          widget.onChanged(v);
        },
      ),
    );
    final counter = Semantics(
      liveRegion: false,
      label: '${_c.text.length} of ${widget.maxLength} characters',
      excludeSemantics: true,
      child: Text(
        '${_c.text.length}/${widget.maxLength}',
        style: monoStyle(context, size: 12, color: t.muted),
      ),
    );
    if (widget.multiline) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          field,
          const SizedBox(height: 4),
          Align(alignment: Alignment.centerRight, child: counter),
        ],
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(child: field),
        const SizedBox(width: 8),
        SizedBox(
          width: 52,
          child: Align(alignment: Alignment.centerRight, child: counter),
        ),
      ],
    );
  }
}

class _Segment extends StatelessWidget {
  const _Segment({
    required this.status,
    required this.selected,
    required this.onTap,
  });

  final KpiStatus status;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final label = switch (status) {
      KpiStatus.met => 'Met',
      KpiStatus.partly => 'Partly',
      KpiStatus.missed => 'Missed',
    };
    return Semantics(
      button: true,
      inMutuallyExclusiveGroup: true,
      checked: selected,
      label: label,
      excludeSemantics: true,
      onTap: onTap,
      child: Material(
        color: selected ? t.statusFill(status.name) : t.bg,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: selected ? BorderSide.none : BorderSide(color: t.line),
        ),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          focusColor: t.accent.withValues(alpha: 0.25),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 46),
            child: Center(
              child: Text(
                label,
                style: bodyStyle(
                  context,
                  size: 16,
                  weight: selected ? FontWeight.w700 : FontWeight.w500,
                  color: selected ? t.statusOn(status.name) : t.ink,
                  height: 1.2,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class NotesCard extends ConsumerWidget {
  const NotesCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final form = ref.watch(formControllerProvider);
    return StepCard(
      step: 4,
      title: 'What to tell the meeting',
      hint:
          'Up to three short points in each box, in your own words (${NoteRules.maxLength} characters each). Leave a line empty to skip it.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (i, kind) in NoteKind.values.indexed) ...[
            if (i > 0) const SizedBox(height: 22),
            NoteBox(
              key: ValueKey('${form.epoch}-${kind.name}'),
              kind: kind,
              count: form.report!.notesOf(kind).length,
            ),
          ],
        ],
      ),
    );
  }
}

class NoteBox extends ConsumerWidget {
  const NoteBox({super.key, required this.kind, required this.count});

  final NoteKind kind;
  final int count;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ctl = ref.read(formControllerProvider.notifier);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                kind.formTitle,
                style: bodyStyle(
                  context,
                  size: 17,
                  weight: FontWeight.w700,
                  height: 1.3,
                ),
              ),
            ),
            Semantics(
              liveRegion: true,
              child: Text(
                '$count of ${NoteRules.maxCount}',
                style: monoStyle(context, size: 13),
              ),
            ),
          ],
        ),
        for (var i = 0; i < NoteRules.maxCount; i++) ...[
          const SizedBox(height: 8),
          _CountedField(
            key: ValueKey('${kind.name}-point-$i'),
            initial: ctl.noteLine(kind, i),
            maxLength: NoteRules.maxLength,
            hint: 'Point ${i + 1}',
            semanticLabel: '${kind.formTitle}, point ${i + 1}',
            onChanged: (v) => ctl.setNote(kind, i, v),
          ),
        ],
      ],
    );
  }
}

class SubmitRow extends ConsumerStatefulWidget {
  const SubmitRow({super.key});

  @override
  ConsumerState<SubmitRow> createState() => _SubmitRowState();
}

class _SubmitRowState extends ConsumerState<SubmitRow> {
  final _errorKey = GlobalKey();

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final form = ref.watch(formControllerProvider);
    ref.listen(formControllerProvider.select((f) => f.problems), (prev, next) {
      if (next.isNotEmpty) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          final c = _errorKey.currentContext;
          if (c != null) {
            unawaited(
              Scrollable.ensureVisible(
                c,
                duration: reducedMotion(context)
                    ? Duration.zero
                    : const Duration(milliseconds: 250),
              ),
            );
          }
        });
      }
    });
    final sending = form.phase == SendPhase.sending;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (form.problems.isNotEmpty)
          Semantics(
            liveRegion: true,
            child: Container(
              key: _errorKey,
              margin: const EdgeInsets.only(bottom: 16),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: t.surface,
                border: Border.all(color: t.bad),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Almost there.',
                    style: bodyStyle(
                      context,
                      weight: FontWeight.w700,
                      color: t.bad,
                    ),
                  ),
                  const SizedBox(height: 4),
                  for (final p in form.problems)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('•  ', style: bodyStyle(context, color: t.bad)),
                          Expanded(
                            child: Text(
                              p,
                              style: bodyStyle(
                                context,
                                size: 16,
                                color: t.bad,
                                height: 1.4,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 16,
          runSpacing: 10,
          children: [
            PrimaryButton(
              label: 'Send report',
              large: true,
              onPressed: sending
                  ? null
                  : () => unawaited(
                      ref.read(formControllerProvider.notifier).send(),
                    ),
            ),
            Semantics(liveRegion: true, child: _status(context, form)),
          ],
        ),
      ],
    );
  }

  Widget _status(BuildContext context, FormModel form) {
    final t = context.tokens;
    final base = bodyStyle(context, size: 16, color: t.muted, height: 1.4);
    return switch (form.phase) {
      SendPhase.idle => const SizedBox.shrink(),
      SendPhase.sending => Text('Sending…', style: base),
      SendPhase.sent => Text.rich(
        TextSpan(
          style: base,
          children: [
            TextSpan(
              text: 'Sent.',
              style: base.copyWith(color: t.ok, fontWeight: FontWeight.w700),
            ),
            const TextSpan(
              text: ' Choose the same name and period to change it later.',
            ),
          ],
        ),
      ),
      SendPhase.queued || SendPhase.failed => Text(
        form.message ?? '',
        style: base.copyWith(color: t.bad),
      ),
    };
  }
}
