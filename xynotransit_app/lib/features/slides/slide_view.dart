import 'package:flutter/material.dart';

import '../../core/theme/tokens.dart';
import '../../domain/deck.dart';
import 'canvas.dart';
import 'cover_slides.dart';
import 'kpi_slide.dart';
import 'results_slide.dart';
import 'suggestions_slide.dart';

/// The period label a divider shows for {period}. A DividerSpec does not carry
/// it yet, so it is empty until the spec has a periodLabel.
String dividerPeriodLabel(DividerSpec s) => '';

/// The widget for one entry of the deck.
Widget slideFor(SlideSpec spec, {Key? key}) => switch (spec) {
  CoverSpec s => SlideCover(
    key: key,
    periodLabel: s.periodLabel,
    meetingDate: s.meetingDate,
    teamCounts: s.teamCounts,
    texts: s.texts,
  ),
  DividerSpec s => SlideDivider(
    key: key,
    team: s.team,
    index: s.index,
    total: s.total,
    people: s.people,
    periodLabel: dividerPeriodLabel(s),
    texts: s.texts,
  ),
  KpiSlideSpec s => SlideKpi(s.snapshot, key: key, texts: s.texts),
  ResultsSlideSpec s => SlideResults(s.snapshot, key: key, texts: s.texts),
  SuggestionsSpec s => SlideSuggestions(
    key: key,
    periodLabel: s.periodLabel,
    texts: s.texts,
  ),
};

/// A slide scaled to the available width in a 16:9 stage.
class SlideStage extends StatelessWidget {
  const SlideStage({super.key, required this.child, this.semanticLabel});

  final Widget child;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Semantics(
      label: semanticLabel,
      image: true,
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFF14213D),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: t.line),
          boxShadow: const [
            BoxShadow(
              offset: Offset(0, 6),
              blurRadius: 24,
              color: Color(0x2E0A1428),
            ),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        child: AspectRatio(
          aspectRatio: slideWidth / slideHeight,
          child: ExcludeSemantics(
            child: FittedBox(fit: BoxFit.contain, child: child),
          ),
        ),
      ),
    );
  }
}
