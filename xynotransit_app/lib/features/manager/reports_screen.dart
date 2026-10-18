import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/theme/tokens.dart';
import '../../core/widgets.dart';
import '../../domain/period.dart';
import '../form/form_screen.dart';
import '../preview/preview_pane.dart';
import '../shell/top_bar.dart';
import '../table/received_card.dart';

const _wideBreakpoint = 1100.0;
const _maxPageWidth = 1760.0;
const _sideWidth = 640.0 + 16;

/// What a manager sees: who has sent their report, the meeting slides, and the
/// controls to generate and export them. Slides on the left, follow-up on the right.
class ReportsScreen extends ConsumerWidget {
  const ReportsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final catalog = ref.watch(catalogProvider);
    return Scaffold(
      appBar: const TopBar(screen: Screen.reports),
      body: catalog.when(
        data: (_) => LayoutBuilder(
          builder: (context, c) => Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: _maxPageWidth),
              child: c.maxWidth >= _wideBreakpoint
                  ? const _TwoColumns()
                  : const _OneColumn(),
            ),
          ),
        ),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              'Could not load the page. Check your connection and reload.',
              style: bodyStyle(context),
            ),
          ),
        ),
      ),
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
            'Report dashboard',
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
          'See who has sent their report, then build the meeting slides.',
          style: bodyStyle(context, color: t.muted),
        ),
      ],
    );
  }
}

/// Picks the three-month period for the whole dashboard.
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

const _side = Column(
  crossAxisAlignment: CrossAxisAlignment.stretch,
  children: [
    _Heading(),
    SizedBox(height: 20),
    _PeriodCard(),
    SizedBox(height: 20),
    ReceivedCard(),
  ],
);

/// Phone and tablet: heading, period and table first, then the slide stream.
class _OneColumn extends ConsumerWidget {
  const _OneColumn();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final nav = ref.watch(slideNavProvider);
    final bottom = 64 + MediaQuery.paddingOf(context).bottom;
    return LayoutBuilder(
      builder: (context, c) => CustomScrollView(
        controller: nav.controller,
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 28, 16, 0),
            sliver: SliverList.list(
              children: const [_side, SizedBox(height: 28), PreviewHeader()],
            ),
          ),
          SliverPadding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, bottom),
            sliver: SlideListSliver(width: c.maxWidth - 32),
          ),
        ],
      ),
    );
  }
}

/// Slides on the left (the preview card stays pinned while they scroll under it),
/// the period and the table on the right.
class _TwoColumns extends ConsumerWidget {
  const _TwoColumns();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final nav = ref.watch(slideNavProvider);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 0, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const PreviewHeader(),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, c) => CustomScrollView(
                      controller: nav.controller,
                      slivers: [
                        SliverPadding(
                          padding: const EdgeInsets.only(bottom: 64),
                          sliver: SlideListSliver(width: c.maxWidth),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 28),
        const SizedBox(
          width: _sideWidth,
          height: double.infinity,
          child: SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(0, 28, 16, 64),
            child: _side,
          ),
        ),
      ],
    );
  }
}
