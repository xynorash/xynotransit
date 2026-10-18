import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/theme/tokens.dart';
import '../../core/widgets.dart';
import '../../data/demo_data.dart';
import '../../data/seed_data.dart';
import '../../domain/deck.dart';
import '../../domain/deck_text.dart';
import '../../domain/period.dart';
import '../../domain/snapshot.dart';
import '../slides/alt_text.dart';
import '../slides/slide_view.dart';

/// A small deck of sample data, built from the demo catalog, for managers who
/// have not generated a deck yet.
DeckRun sampleDeckRun(Period period) {
  final catalog = buildSeedCatalog();
  final reports = buildDemoReports(catalog, period.id);
  ReportSnapshot? pick;
  for (final a in catalog.assignments) {
    final r = reports.where((r) => r.assignmentId == a.id).firstOrNull;
    if (r == null) continue;
    final s = ReportSnapshot.build(
      report: r,
      assignment: a,
      catalog: catalog,
      period: period,
    );
    pick ??= s;
    if (s.hasCounts && s.targets.isNotEmpty) {
      pick = s;
      break;
    }
  }
  return DeckRun(
    id: 'sample',
    periodId: period.id,
    generatedAt: DateTime(2000),
    expectedCount: 1,
    includedCount: 1,
    items: [DeckItem(reportId: 'sample', sort: 0, snapshot: pick!)],
  );
}

/// The five slides that show every editable word, rendered with [draft].
/// They come from the real deck builder, so they look as the next deck will.
List<(String, SlideSpec)> draftSlides({
  required DeckRun source,
  required Period period,
  required DeckTexts draft,
}) {
  final run = DeckRun(
    id: source.id,
    periodId: source.periodId,
    generatedAt: source.generatedAt,
    expectedCount: source.expectedCount,
    includedCount: source.includedCount,
    items: source.items,
    texts: draft,
  );
  final all = buildDeck(run, period);
  return [
    ('Cover slide', all.whereType<CoverSpec>().first),
    ('Team divider', all.whereType<DividerSpec>().first),
    ('KPI slide of one person', all.whereType<KpiSlideSpec>().first),
    ('Results slide of one person', all.whereType<ResultsSlideSpec>().first),
    ('Suggestions page', all.whereType<SuggestionsSpec>().first),
  ];
}

/// "Draft preview": live slides with the words as typed, before saving.
class DraftPreview extends ConsumerWidget {
  const DraftPreview({super.key, required this.draft});

  final DeckTexts draft;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.tokens;
    final period = ref.watch(periodProvider).value;
    final deck = ref.watch(deckProvider).value;
    if (period == null) return const SizedBox.shrink();
    final real = deck != null && deck.items.isNotEmpty;
    final slides = draftSlides(
      source: real ? deck : sampleDeckRun(period),
      period: period,
      draft: draft,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          header: true,
          child: Text(
            'Draft preview',
            style: bodyStyle(
              context,
              size: 20,
              weight: FontWeight.w700,
              height: 1.25,
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          'This is how the next deck will look. The deck you generated before '
          'keeps its old words.',
          style: bodyStyle(context, size: 15, color: t.muted, height: 1.4),
        ),
        if (!real) ...[
          const SizedBox(height: 4),
          Text(
            'Sample data',
            key: const ValueKey('sample-data'),
            style: monoStyle(context, size: 13),
          ),
        ],
        for (final (caption, spec) in slides) ...[
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(
              caption,
              style: monoStyle(context, size: 13),
              textScaler: TextScaler.noScaling,
            ),
          ),
          SlideStage(semanticLabel: slideAltText(spec), child: slideFor(spec)),
        ],
      ],
    );
  }
}
