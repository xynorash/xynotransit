import 'package:flutter/painting.dart';

import '../../core/format.dart';
import '../../domain/deck_text.dart';
import '../../domain/snapshot.dart';
import 'measure.dart';

/// The rendered words of a deck. Widgets, alt text and the jump menu all call
/// these functions, so one rule decides what a slide says.
class SlideWords {
  const SlideWords(this.texts);

  final DeckTexts texts;

  /// The meeting title with {period} filled in.
  String title(String periodLabel) =>
      texts.render('title', {'period': periodLabel});

  String get org => texts['orgName'];

  /// Variables of the person slides.
  Map<String, Object?> person(ReportSnapshot s) => {
    'org': org,
    'title': title(s.periodLabel),
    'period': s.periodLabel,
    'name': s.name,
    'role': s.role,
    'team': s.team,
  };

  String kpiEyebrow(ReportSnapshot s) => texts.render('kpiEyebrow', person(s));
  String kpiTitle(ReportSnapshot s) => texts.render('kpiTitle', person(s));
  String resultsEyebrow(ReportSnapshot s) =>
      texts.render('resultsEyebrow', person(s));
  String resultsTitle(ReportSnapshot s) =>
      texts.render('resultsTitle', person(s));
  String footer(ReportSnapshot s) => texts.render('footer', person(s));

  /// The badge on the KPI slide. A seat without targets says "KPI · no targets".
  String kpiBadge(ReportSnapshot s) => s.targets.isEmpty
      ? 'KPI · no targets'
      : texts.render('kpiBadge', {
          'met': s.metCount,
          'total': s.targets.length,
        });

  String subtitle(String periodLabel) =>
      texts.render('subtitle', {'period': periodLabel});

  /// Own words of the date line, else the meeting date, else nothing.
  /// Shown in capitals by the slide.
  String dateLine(DateTime? meetingDate) {
    final own = texts['dateText'].trim();
    if (own.isNotEmpty) return own.toUpperCase();
    return meetingDate == null ? '' : longDate(meetingDate).toUpperCase();
  }

  String coverPill(String team, int count) => texts.render('coverPill', {
    'team': team,
    'count': count,
    'reports': count == 1 ? 'report' : 'reports',
  });

  Map<String, Object?> divider(
    String team,
    int index,
    int total,
    int k,
    String periodLabel,
  ) => {
    'title': title(periodLabel),
    'period': periodLabel,
    'i': index,
    'n': total,
    'team': team,
    'k': k,
    'reports': k == 1 ? 'report' : 'reports',
  };

  String dividerEyebrow(
    String team,
    int index,
    int total,
    int k,
    String periodLabel,
  ) => texts.render(
    'dividerEyebrow',
    divider(team, index, total, k, periodLabel),
  );
  String dividerTitle(String team) =>
      texts.render('dividerTitle', {'team': team});
  String dividerSubtitle(String team, int k) => texts.render(
    'dividerSubtitle',
    {'team': team, 'k': k, 'reports': k == 1 ? 'report' : 'reports'},
  );

  String get suggestionsTitle => texts['suggestionsTitle'];
  String get suggestionsBody => texts['suggestionsBody'];
}

/// One way to set a text: font size and the most lines it may use.
typedef FitStep = (double size, int lines);

/// The first step in [steps] in which [text] fits [width] pixels in at most
/// that many lines. When none fits, the last step is returned: it ends the
/// text with an ellipsis so nothing runs out of the slide. Slides have a fixed
/// size, so this is a pure function of the words.
FitStep pickFit(
  String text,
  double width,
  List<FitStep> steps,
  TextStyle Function(double size) style,
) {
  for (final step in steps) {
    final m = measureText(text, style(step.$1), width, maxLines: step.$2);
    // A word longer than the line must not run out of it either.
    if (!m.exceeded && m.width <= width + 0.5) return step;
  }
  return steps.last;
}
