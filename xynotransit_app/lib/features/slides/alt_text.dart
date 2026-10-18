import '../../domain/deck.dart';
import 'slide_words.dart';

/// Plain-words description of a slide, in the words of its deck. Used as the
/// picture's accessible name in the preview and as the speaker notes and alt
/// text in the PPTX export.
String slideAltText(SlideSpec spec) {
  final w = SlideWords(spec.texts);
  return switch (spec) {
    KpiSlideSpec s => [
      '${w.kpiTitle(s.snapshot)}.',
      s.snapshot.targets.isEmpty
          ? 'No KPI targets.'
          : '${s.snapshot.metCount} of ${s.snapshot.targets.length} KPI met.',
      for (final m in s.snapshot.metrics) '${m.label}: ${m.total}.',
    ].join(' '),
    ResultsSlideSpec s =>
      '${w.resultsTitle(s.snapshot)}. ${s.snapshot.well.length} highlights, ${s.snapshot.wrong.length} lowlights, '
          '${s.snapshot.next.length} priorities for the next three months.',
    CoverSpec s => '${w.title(s.periodLabel)}, ${s.periodLabel}.',
    DividerSpec s =>
      '${w.dividerTitle(s.team)}, ${s.people.length} ${s.people.length == 1 ? 'report' : 'reports'}.',
    SuggestionsSpec _ =>
      w.suggestionsBody.trim().isEmpty
          ? '${w.suggestionsTitle}.'
          : '${w.suggestionsTitle}. ${w.suggestionsBody}',
  };
}

/// Short name for lists, in the words of the deck: "Rova: KPI and volumes".
String slideTitle(SlideSpec spec) {
  final w = SlideWords(spec.texts);
  return switch (spec) {
    KpiSlideSpec s => w.kpiTitle(s.snapshot),
    ResultsSlideSpec s => w.resultsTitle(s.snapshot),
    CoverSpec _ => 'Cover',
    DividerSpec s => w.dividerTitle(s.team),
    SuggestionsSpec _ => w.suggestionsTitle,
  };
}
