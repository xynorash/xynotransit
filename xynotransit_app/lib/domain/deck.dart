import 'deck_text.dart';
import 'period.dart';
import 'report.dart';
import 'snapshot.dart';

class DeckItem {
  const DeckItem({
    required this.reportId,
    required this.sort,
    required this.snapshot,
  });
  final String reportId;
  final int sort;
  final ReportSnapshot snapshot;
}

/// One press of "Generate slides". The items freeze what each slide is built from.
class DeckRun {
  DeckRun({
    required this.id,
    required this.periodId,
    required this.generatedAt,
    required this.expectedCount,
    required this.includedCount,
    required List<DeckItem> items,
    this.texts = DeckTexts.empty,
  }) : items = List.unmodifiable(
         <DeckItem>[...items]..sort((a, b) => a.sort.compareTo(b.sort)),
       );

  final String id;
  final String periodId;
  final DateTime generatedAt;
  final int expectedCount;
  final int includedCount;
  final List<DeckItem> items;

  /// The words of the deck, frozen when it was generated.
  final DeckTexts texts;
}

class PeriodProgress {
  const PeriodProgress({required this.expected, required this.submitted});
  final int expected;
  final int submitted;

  double get fraction => expected == 0 ? 0 : (submitted / expected).clamp(0, 1);
  bool get complete => expected > 0 && submitted >= expected;

  static PeriodProgress of(Iterable<Report> reports, int expected) =>
      PeriodProgress(
        expected: expected,
        submitted: reports.where((r) => r.isSubmitted).length,
      );
}

/// Who is on which slide, for the whole deck.
sealed class SlideSpec {
  const SlideSpec({this.texts = DeckTexts.empty});

  /// The words of the deck this slide belongs to.
  final DeckTexts texts;
}

class CoverSpec extends SlideSpec {
  const CoverSpec({
    required this.periodLabel,
    required this.meetingDate,
    required this.teamCounts,
    super.texts,
  });
  final String periodLabel;
  final DateTime? meetingDate;

  /// Team name and number of reports, in deck order.
  final List<(String, int)> teamCounts;
}

class DividerSpec extends SlideSpec {
  const DividerSpec({
    required this.team,
    required this.index,
    required this.total,
    required this.people,
    super.texts,
  });
  final String team;
  final int index;
  final int total;

  /// "Name · Role" per included report.
  final List<String> people;
}

class KpiSlideSpec extends SlideSpec {
  const KpiSlideSpec(this.snapshot, {super.texts});
  final ReportSnapshot snapshot;
}

class ResultsSlideSpec extends SlideSpec {
  const ResultsSlideSpec(this.snapshot, {super.texts});
  final ReportSnapshot snapshot;
}

/// The last page of every deck. Its real content is still to come.
class SuggestionsSpec extends SlideSpec {
  const SuggestionsSpec({required this.periodLabel, super.texts});
  final String periodLabel;
}

/// Deck order: cover, then per team a divider followed by two slides per person,
/// then the suggestions page.
/// Teams without a submitted report are skipped. Items are already in catalog order.
List<SlideSpec> buildDeck(DeckRun run, Period? period) {
  final teams = <String>[];
  final byTeam = <String, List<DeckItem>>{};
  for (final it in run.items) {
    final t = it.snapshot.team;
    if (!byTeam.containsKey(t)) teams.add(t);
    byTeam.putIfAbsent(t, () => []).add(it);
  }
  final label = run.items.isNotEmpty
      ? run.items.first.snapshot.periodLabel
      : (period?.label ?? '');
  final slides = <SlideSpec>[
    CoverSpec(
      periodLabel: label,
      meetingDate: period?.meetingDate,
      teamCounts: [for (final t in teams) (t, byTeam[t]!.length)],
      texts: run.texts,
    ),
  ];
  for (var i = 0; i < teams.length; i++) {
    final items = byTeam[teams[i]]!;
    slides.add(
      DividerSpec(
        team: teams[i],
        index: i + 1,
        total: teams.length,
        people: [
          for (final it in items) '${it.snapshot.name} · ${it.snapshot.role}',
        ],
        texts: run.texts,
      ),
    );
    for (final it in items) {
      slides
        ..add(KpiSlideSpec(it.snapshot, texts: run.texts))
        ..add(ResultsSlideSpec(it.snapshot, texts: run.texts));
    }
  }
  slides.add(SuggestionsSpec(periodLabel: label, texts: run.texts));
  return slides;
}
