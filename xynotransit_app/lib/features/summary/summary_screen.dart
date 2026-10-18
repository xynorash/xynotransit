import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../core/theme/tokens.dart';
import '../../core/widgets.dart';
import '../../domain/period.dart';
import '../../domain/summary.dart';
import '../form/form_screen.dart';
import '../shell/top_bar.dart';
import 'people_table.dart';
import 'summary_charts.dart';
import 'summary_provider.dart';
import 'summary_widgets.dart';
import 'writings_card.dart';

const _wideBreakpoint = 1100.0;
const _maxPageWidth = 1760.0;
const _gap = 20.0;

/// The manager's home: how the period went, in numbers and graphs.
class OverviewScreen extends ConsumerWidget {
  const OverviewScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: const TopBar(screen: Screen.overview),
      body: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          16,
          28,
          16,
          64 + MediaQuery.paddingOf(context).bottom,
        ),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: _maxPageWidth),
            child: const _Body(),
          ),
        ),
      ),
    );
  }
}

class _Body extends ConsumerWidget {
  const _Body();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final summary = ref.watch(summaryProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _Heading(),
        const SizedBox(height: 20),
        const _PeriodCard(),
        const SizedBox(height: _gap),
        if (summary.hasValue)
          _Loaded(summary: summary.requireValue)
        else if (summary.hasError)
          NoticeCard(
            title: 'The summary did not load',
            body:
                'Something went wrong while counting the reports. Check your '
                'connection and try again.',
            action: GhostButton(
              label: 'Try again',
              onPressed: () => ref.invalidate(summaryProvider),
            ),
          )
        else
          const Padding(
            padding: EdgeInsets.all(40),
            child: Center(child: CircularProgressIndicator()),
          ),
      ],
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading();

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'XNT-LOG-02 · Manager'.toUpperCase(),
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
            'Overview',
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
        Text(
          'How the period went: who has reported, how targets were met and '
          'what the numbers add up to.',
          style: bodyStyle(context, color: t.muted),
        ),
      ],
    );
  }
}

class _PeriodCard extends ConsumerWidget {
  const _PeriodCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final start = ref.watch(periodSelectionProvider);
    final period = ref.watch(periodProvider);
    return XCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            header: true,
            child: Text(
              'Period',
              style: bodyStyle(
                context,
                size: 20,
                weight: FontWeight.w700,
                height: 1.25,
              ),
            ),
          ),
          const SizedBox(height: 14),
          const PeriodFields(),
          const SizedBox(height: 12),
          Text(
            period.hasValue
                ? 'Showing ${period.requireValue.label}.'
                : 'Showing ${Period.labelFor(start)}.',
            style: monoStyle(context),
          ),
        ],
      ),
    );
  }
}

class _Loaded extends StatelessWidget {
  const _Loaded({required this.summary});

  final Summary summary;

  @override
  Widget build(BuildContext context) {
    final s = summary;
    if (s.teams.isEmpty && s.people.isEmpty) {
      return NoticeCard(
        title: 'No one is expected to report yet',
        body:
            'Add teams, people and their counts in the People section. The '
            'graphs appear here once reports come in.',
        action: GhostButton(
          label: 'Open People',
          onPressed: () => context.go('/manager/people'),
        ),
      );
    }
    final sent = s.submitted > 0;
    final trendHasData = s.trend.any((p) => p.submitted > 0);
    final reported = ReportedCard(summary: s);
    final targets = TargetsCard(summary: s);
    final volume = VolumeCard(summary: s);
    final biggest = BiggestCard(summary: s);
    final trend = TrendCard(summary: s);
    final empty = NoticeCard(
      title: 'No reports yet for ${s.periodLabel}',
      body:
          'The graphs fill in when the first report is sent. Until then you '
          'can see below who is expected.',
    );
    return LayoutBuilder(
      builder: (context, c) {
        final wide = c.maxWidth >= _wideBreakpoint;
        Widget stack(List<Widget> cards) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < cards.length; i++) ...[
              if (i > 0) const SizedBox(height: _gap),
              cards[i],
            ],
          ],
        );
        final left = [reported, if (sent) volume, if (trendHasData) trend];
        final right = [if (sent) targets, if (sent) biggest];
        if (!sent) right.insert(0, empty);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Tiles(summary: s),
            const SizedBox(height: _gap),
            if (wide)
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: stack(left)),
                  const SizedBox(width: _gap),
                  Expanded(child: stack(right)),
                ],
              )
            else
              stack(
                sent
                    ? [
                        reported,
                        targets,
                        volume,
                        biggest,
                        if (trendHasData) trend,
                      ]
                    : [empty, reported, if (trendHasData) trend],
              ),
            const SizedBox(height: _gap),
            PeopleTableCard(people: s.people),
            if (sent) ...[const SizedBox(height: _gap), const WritingsCard()],
          ],
        );
      },
    );
  }
}

class _Tiles extends StatelessWidget {
  const _Tiles({required this.summary});

  final Summary summary;

  @override
  Widget build(BuildContext context) {
    final s = summary;
    final missing = s.people.where((p) => !p.submitted).length;
    final volume = s.teams.fold<int>(
      0,
      (a, t) => a + t.volumeByMonth.fold<int>(0, (x, y) => x + y),
    );
    final tiles = [
      _Tile(
        id: 'reports',
        label: 'Reports in',
        value: '${s.submitted} of ${s.expected}',
        note: 'sent so far',
      ),
      _Tile(
        id: 'met',
        label: 'Targets met',
        value: s.answered == 0 ? '–' : fmtPct(s.metRate),
        note: s.answered == 0
            ? 'no targets answered yet'
            : '${s.met} of ${s.answered} answered targets',
      ),
      _Tile(
        id: 'volume',
        label: 'Volume',
        value: fmtInt(volume),
        note: 'all counts added together',
      ),
      _Tile(
        id: 'missing',
        label: 'People missing',
        value: '$missing',
        note: missing == 0 ? 'everyone has sent' : 'still to send',
      ),
    ];
    return LayoutBuilder(
      builder: (context, c) {
        const gap = 12.0;
        final cols = c.maxWidth >= 900 ? 4 : 2;
        final w = (c.maxWidth - gap * (cols - 1)) / cols;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [for (final t in tiles) SizedBox(width: w, child: t)],
        );
      },
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({
    required this.id,
    required this.label,
    required this.value,
    required this.note,
  });

  final String id;
  final String label;
  final String value;
  final String note;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return MergeSemantics(
      child: Semantics(
        label: '$label: $value, $note',
        container: true,
        child: ExcludeSemantics(
          child: XCard(
            key: ValueKey('tile-$id'),
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: bodyStyle(
                    context,
                    size: 14,
                    color: t.muted,
                    weight: FontWeight.w500,
                    height: 1.3,
                  ),
                ),
                const SizedBox(height: 4),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    value,
                    style: bodyStyle(
                      context,
                      size: 32,
                      weight: FontWeight.w700,
                      height: 1.15,
                    ),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  note,
                  style: bodyStyle(
                    context,
                    size: 13,
                    color: t.muted,
                    height: 1.3,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
