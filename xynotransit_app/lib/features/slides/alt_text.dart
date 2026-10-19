import '../../core/format.dart';
import '../../domain/deck.dart';
import '../../domain/enums.dart';
import 'kpi_slide.dart' show targetComment;
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
      for (final m in s.snapshot.metrics) '${m.label}: ${thousands(m.total)}.',
    ].join(' '),
    ResultsSlideSpec s =>
      '${w.resultsTitle(s.snapshot)}. ${s.snapshot.well.length} ${spec.texts['highlightsTitle']}, '
          '${s.snapshot.wrong.length} ${spec.texts['lowlightsTitle']}, '
          '${s.snapshot.next.length} ${spec.texts['nextTitle']}.',
    CoverSpec s => [
      '${w.title(s.periodLabel)}, ${s.periodLabel}.',
      if (spec.texts['dateText'].trim().isNotEmpty)
        '${spec.texts['dateText'].trim()}.',
    ].join(' '),
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

String _statusWord(KpiStatus? s) => switch (s) {
  KpiStatus.met => 'met',
  KpiStatus.partly => 'partly met',
  KpiStatus.missed => 'missed',
  null => 'not answered',
};

/// Speaker notes: the alt text first, then everything the slide shows, one
/// fact per line, so the notes stand in for the slide when it cannot be seen
/// (and nothing the grid layout may shorten with an ellipsis is lost).
String slideNotes(SlideSpec spec) {
  final w = SlideWords(spec.texts);
  final lines = <String>[slideAltText(spec)];
  switch (spec) {
    case KpiSlideSpec s:
      final t = s.snapshot.targets;
      lines.add(t.isEmpty ? 'Targets: none.' : 'Targets:');
      for (var i = 0; i < t.length; i++) {
        final comment = targetComment(t[i]);
        lines.add(
          '${i + 1}. ${t[i].text}: ${_statusWord(t[i].status)}.'
          '${comment == null ? '' : ' Comment: $comment'}',
        );
      }
      if (s.snapshot.metrics.isNotEmpty) {
        lines.add(
          'Volumes per month, ${s.snapshot.firstMonthName} to ${s.snapshot.lastMonthName}:',
        );
        for (final m in s.snapshot.metrics) {
          final months = [
            for (var i = 0; i < m.values.length; i++)
              '${s.snapshot.months[i].short} ${thousands(m.values[i])}',
          ];
          lines.add(
            '${m.label}: ${months.join(', ')} (total ${thousands(m.total)}).',
          );
        }
      }
    case ResultsSlideSpec s:
      final columns = [
        (spec.texts['highlightsTitle'], s.snapshot.well),
        (spec.texts['lowlightsTitle'], s.snapshot.wrong),
        (spec.texts['nextTitle'], s.snapshot.next),
      ];
      for (final (title, notes) in columns) {
        lines.add(
          '$title: ${notes.isEmpty ? spec.texts['emptyNote'] : notes.join('; ')}',
        );
      }
    case CoverSpec s:
      if (s.teamCounts.isNotEmpty) {
        lines.add(
          'Teams: ${[for (final (team, n) in s.teamCounts) w.coverPill(team, n)].join('; ')}.',
        );
      }
    case DividerSpec s:
      if (s.people.isNotEmpty) lines.add('Reports: ${s.people.join('; ')}.');
    case SuggestionsSpec _:
      break;
  }
  return lines.join('\n');
}
