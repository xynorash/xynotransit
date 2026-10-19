import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/theme/tokens.dart';
import '../../core/widgets.dart';
import '../../domain/deck.dart';
import '../../domain/deck_text.dart';
import '../../domain/snapshot.dart';
import '../form/form_controller.dart';
import '../slides/alt_text.dart';
import '../slides/slide_view.dart';

/// The two slides of the person being reported for, as they stand right now.
/// Pure function of the draft, the deck words and the period, so a test can
/// compare it with the slides of a generated deck.
List<SlideSpec> previewSlides({
  required ReportSnapshot snapshot,
  required DeckTexts texts,
}) => [
  KpiSlideSpec(snapshot, texts: texts),
  ResultsSlideSpec(snapshot, texts: texts),
];

/// The deck words in force for the shown period. Defaults while they load or
/// when they cannot be read.
final previewTextsProvider = Provider<DeckTexts>(
  (ref) => ref.watch(deckTextsProvider).value?.texts ?? DeckTexts.empty,
);

/// What the draft would show on the slides, or null when nothing is selected.
class _PreviewBody extends ConsumerWidget {
  const _PreviewBody();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Only the report and the seat are watched: a keystroke rebuilds this
    // widget and nothing else on the screen.
    final report = ref.watch(formControllerProvider.select((f) => f.report));
    final id = ref.watch(formControllerProvider.select((f) => f.assignmentId));
    final catalog = ref.watch(catalogProvider).value;
    final period = ref.watch(periodProvider).value;
    final texts = ref.watch(previewTextsProvider);
    final t = context.tokens;
    final a = id == null ? null : catalog?.assignmentById(id);
    if (report == null || catalog == null || a == null || period == null) {
      return Text(
        'Choose who you are reporting for to see your slides.',
        style: bodyStyle(context, size: 15, color: t.muted, height: 1.4),
      );
    }
    final snap = buildDraftSnapshot(report, a, catalog, period);
    final slides = previewSlides(snapshot: snap, texts: texts);
    return Column(
      key: const ValueKey('live-preview'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (i, spec) in slides.indexed) ...[
          if (i > 0) const SizedBox(height: 16),
          SlideStage(semanticLabel: slideAltText(spec), child: slideFor(spec)),
        ],
      ],
    );
  }
}

class _PreviewHints extends StatelessWidget {
  const _PreviewHints();

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final style = bodyStyle(context, size: 15, color: t.muted, height: 1.4);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Preview of your two slides. Empty numbers count as 0. It updates as you type.',
          style: style,
        ),
        const SizedBox(height: 4),
        Text(
          'The meeting title, footer and other wording are set by your manager.',
          style: style,
        ),
      ],
    );
  }
}

/// Wide screens: the preview column, with its own scroll.
class PreviewColumn extends StatelessWidget {
  const PreviewColumn({super.key});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
        0,
        28,
        0,
        64 + MediaQuery.paddingOf(context).bottom,
      ),
      child: const YourSlides(),
    );
  }
}

/// "Your slides": heading, hints and the two live slides.
class YourSlides extends StatelessWidget {
  const YourSlides({super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          header: true,
          child: Text(
            'Your slides',
            style: bodyStyle(
              context,
              size: 20,
              weight: FontWeight.w700,
              height: 1.25,
            ),
          ),
        ),
        const SizedBox(height: 6),
        const _PreviewHints(),
        const SizedBox(height: 14),
        const _PreviewBody(),
      ],
    );
  }
}

/// Narrow screens: a bar that opens the same preview in place.
class CollapsiblePreview extends StatefulWidget {
  const CollapsiblePreview({super.key});

  @override
  State<CollapsiblePreview> createState() => _CollapsiblePreviewState();
}

class _CollapsiblePreviewState extends State<CollapsiblePreview> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return XCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            button: true,
            expanded: _open,
            label: 'Preview your slides. Empty numbers count as 0',
            excludeSemantics: true,
            onTap: () => setState(() => _open = !_open),
            child: InkWell(
              key: const ValueKey('preview-toggle'),
              borderRadius: BorderRadius.circular(10),
              onTap: () => setState(() => _open = !_open),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 44),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Preview your slides',
                              style: bodyStyle(
                                context,
                                size: 18,
                                weight: FontWeight.w700,
                                height: 1.25,
                              ),
                            ),
                            Text(
                              _open ? 'Tap to hide' : 'Tap to see how they look. Empty numbers count as 0.',
                              style: bodyStyle(
                                context,
                                size: 14,
                                color: t.muted,
                                height: 1.3,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Icon(
                        _open ? Icons.expand_less : Icons.expand_more,
                        color: t.ink,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          if (_open) ...[const SizedBox(height: 10), const YourSlides()],
        ],
      ),
    );
  }
}
