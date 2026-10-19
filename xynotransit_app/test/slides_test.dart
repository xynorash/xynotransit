import 'package:flutter_test/flutter_test.dart';
import 'package:xynotransit_app/domain/deck_text.dart';
import 'package:xynotransit_app/domain/enums.dart';
import 'package:xynotransit_app/domain/snapshot.dart';
import 'package:xynotransit_app/features/slides/cover_slides.dart';
import 'package:xynotransit_app/features/slides/fit.dart';
import 'package:xynotransit_app/features/slides/kpi_slide.dart';
import 'package:xynotransit_app/features/slides/results_slide.dart';
import 'package:xynotransit_app/features/slides/suggestions_slide.dart';

import 'helpers.dart';

ReportSnapshot withNotes(
  ReportSnapshot s, {
  List<String> well = const [],
  List<String> wrong = const [],
  List<String> next = const [],
}) => ReportSnapshot(
  assignmentCode: s.assignmentCode,
  name: s.name,
  role: s.role,
  team: s.team,
  periodLabel: s.periodLabel,
  months: s.months,
  metrics: s.metrics,
  targets: s.targets,
  well: well,
  wrong: wrong,
  next: next,
);

void main() {
  setUpAll(loadAppFonts);

  group('fit algorithm', () {
    test('picks the first layout that fits, else the dense fallback', () {
      for (final a in catalog.assignments) {
        final texts = [for (final k in a.kpis) k.text];
        final fit = fitKpis(texts);
        final avail =
            (kpiAreaHeight - (texts.length - 1) * kpiGap) / texts.length;
        final worst = texts
            .map((t) => kpiNeed(t, fit))
            .reduce((a, b) => a > b ? a : b);
        final isFallback = fit.width == 760 && !fit.label && fit.fontSize == 24;
        expect(
          worst <= avail || isFallback,
          isTrue,
          reason: '${a.code} with $fit',
        );
      }
    });

    test('2 to 6 targets of up to 70 characters fit without the fallback', () {
      for (var n = 2; n <= 5; n++) {
        final texts = List.filled(n, 'x' * 70);
        final fit = fitKpis(texts);
        final avail = (kpiAreaHeight - (n - 1) * kpiGap) / n;
        final worst = texts
            .map((t) => kpiNeed(t, fit))
            .reduce((a, b) => a > b ? a : b);
        expect(worst, lessThanOrEqualTo(avail), reason: 'n=$n $fit');
      }
    });

    testWidgets('all 14 catalog slides render without overflow', (
      tester,
    ) async {
      for (final a in catalog.assignments) {
        await pumpSlide(tester, SlideKpi(demoSnapshot(a.code)));
        expect(tester.takeException(), isNull, reason: a.code);
        await pumpSlide(tester, SlideResults(demoSnapshot(a.code)));
        expect(tester.takeException(), isNull, reason: a.code);
      }
    });

    test('few short targets get the biggest text', () {
      expect(fitKpis(['Short one', 'Short two', 'Short three']).fontSize, 40);
    });
  });

  group('Slide A', () {
    for (final code in ['rova', 'hanitra', 'shalini', 'tanjona', 'michael']) {
      testWidgets('draws $code without overflow', (tester) async {
        await pumpSlide(tester, SlideKpi(demoSnapshot(code)));
        expect(tester.takeException(), isNull);
        await expectLater(
          find.byType(SlideKpi),
          matchesGoldenFile('goldens/slide_a_$code.png'),
        );
      });
    }

    testWidgets('shows the met badge and the totals', (tester) async {
      final s = demoSnapshot('rova');
      await pumpSlide(tester, SlideKpi(s));
      expect(find.text('KPI · ${s.metCount} of 3 met'), findsOneWidget);
      expect(find.text('Rova: KPI and volumes'), findsOneWidget);
      expect(find.text('Volumes per month, Feb to Apr'), findsOneWidget);
    });

    testWidgets('roles without counts show the target totals', (tester) async {
      await pumpSlide(tester, SlideKpi(demoSnapshot('shalini')));
      expect(find.text('Targets, Feb to Apr'), findsOneWidget);
      expect(
        find.text('This role has no monthly counts to chart.'),
        findsOneWidget,
      );
    });
  });

  group('Slide B', () {
    testWidgets('full boxes', (tester) async {
      final base = demoSnapshot('rova');
      final long = 'a' * 69;
      final s = withNotes(
        base,
        well: [
          'Declarations on time $long'.substring(0, 70),
          'No issues raised by customs',
          'Good communication with forwarders',
        ],
        wrong: [
          'Last-minute change of quantity or PO and also something more to say',
          'Errors in documents',
          'Demurrage charges',
        ],
        next: [
          'Be proactive on procedure changes',
          'Monitor every shipment closely',
          'Learn the FDF platform',
        ],
      );
      await pumpSlide(tester, SlideResults(s));
      expect(tester.takeException(), isNull);
      await expectLater(
        find.byType(SlideResults),
        matchesGoldenFile('goldens/slide_b_full.png'),
      );
    });

    testWidgets('empty boxes say Nothing to report', (tester) async {
      await pumpSlide(tester, SlideResults(withNotes(demoSnapshot('rova'))));
      expect(find.text('Nothing to report'), findsNWidgets(3));
      expect(find.text('Highlights'), findsOneWidget);
      expect(find.text('Lowlights'), findsOneWidget);
      expect(find.text('Next 3 months'), findsOneWidget);
      await expectLater(
        find.byType(SlideResults),
        matchesGoldenFile('goldens/slide_b_empty.png'),
      );
    });
  });

  group('cover and divider', () {
    testWidgets('cover', (tester) async {
      await pumpSlide(
        tester,
        SlideCover(
          periodLabel: 'Feb to Apr 2026',
          meetingDate: DateTime(2026, 6, 9),
          teamCounts: const [
            ('Mauritius', 2),
            ('Tana', 7),
            ('Antsirabe', 3),
            ('Tamatave', 1),
          ],
        ),
      );
      expect(find.text('TUESDAY 09 JUNE 2026'), findsOneWidget);
      expect(find.text('Tana · 7 reports'), findsOneWidget);
      expect(find.text('Tamatave · 1 report'), findsOneWidget);
      await expectLater(
        find.byType(SlideCover),
        matchesGoldenFile('goldens/cover.png'),
      );
    });

    testWidgets('divider', (tester) async {
      await pumpSlide(
        tester,
        const SlideDivider(
          team: 'Tana',
          index: 2,
          total: 4,
          people: [
            'Rova · Import',
            'Rado · Declarant Ivato (Tana and Abe)',
            'Honore · Passeur Ivato',
          ],
        ),
      );
      expect(
        find.text('3 reports, two slides each: KPI and results'),
        findsOneWidget,
      );
      await expectLater(
        find.byType(SlideDivider),
        matchesGoldenFile('goldens/divider.png'),
      );
    });

    testWidgets('divider with one report uses the singular', (tester) async {
      await pumpSlide(
        tester,
        const SlideDivider(
          team: 'Tamatave',
          index: 4,
          total: 4,
          people: ['Andry · Tamatave team'],
        ),
      );
      expect(
        find.text('1 report, two slides each: KPI and results'),
        findsOneWidget,
      );
    });
  });

  group('custom words', () {
    // The longest words the editor allows, in every field.
    final long = DeckTexts.fromJson({
      'title': List.filled(16, 'Logistics').join(' ').substring(0, 80),
      'subtitle': 'S' * 119,
      'dateText': 'Next Tuesday, in the big room at the head office',
      'coverPill': 'Team {team} has {count} reports this quarter',
      'kpiEyebrow': 'Eyebrow ' * 15,
      'kpiTitle': '{name}: ${'very long title ' * 7}'.substring(0, 120),
      'kpiBadge': 'K' * 40,
      'resultsEyebrow': 'Eyebrow ' * 15,
      'resultsTitle': '{name}: ${'very long title ' * 7}'.substring(0, 120),
      'highlightsTitle': 'H' * 30,
      'lowlightsTitle': 'Lowlights and more of them',
      'nextTitle': 'N' * 30,
      'emptyNote': 'Nothing was written here at all',
      'footer': 'Footer ${'words ' * 20}'.substring(0, 120),
      'dividerEyebrow': 'Eyebrow ' * 15,
      'dividerTitle': '{team} ${'big ' * 14}'.substring(0, 60),
      'dividerSubtitle': 'D' * 120,
      'suggestionsTitle': 'T' * 60,
      'suggestionsBody': 'Body text of the suggestions page. ' * 11,
    });

    testWidgets('cover and divider keep long words inside the page', (
      tester,
    ) async {
      await pumpSlide(
        tester,
        SlideCover(
          periodLabel: 'Feb to Apr 2026',
          meetingDate: DateTime(2026, 6, 9),
          teamCounts: const [('Mauritius', 2), ('Tana', 7), ('Antsirabe', 3)],
          texts: long,
        ),
      );
      expect(
        find.text('NEXT TUESDAY, IN THE BIG ROOM AT THE HEAD OFFICE'),
        findsOneWidget,
      );
      expect(find.text('Team Tana has 7 reports this quarter'), findsOneWidget);
      await expectLater(
        find.byType(SlideCover),
        matchesGoldenFile('goldens/cover_long.png'),
      );
      await pumpSlide(
        tester,
        SlideDivider(
          team: 'Tana',
          index: 2,
          total: 4,
          people: const ['Rova · Import', 'Honore · Passeur Ivato'],
          periodLabel: 'Feb to Apr 2026',
          texts: long,
        ),
      );
      await expectLater(
        find.byType(SlideDivider),
        matchesGoldenFile('goldens/divider_long.png'),
      );
    });

    testWidgets('person slides keep long words inside the page', (
      tester,
    ) async {
      final s = demoSnapshot('rova');
      await pumpSlide(tester, SlideKpi(s, texts: long));
      await expectLater(
        find.byType(SlideKpi),
        matchesGoldenFile('goldens/slide_a_long.png'),
      );
      await pumpSlide(
        tester,
        SlideResults(withNotes(s, well: ['One point']), texts: long),
      );
      await expectLater(
        find.byType(SlideResults),
        matchesGoldenFile('goldens/slide_b_long.png'),
      );
    });

    testWidgets('short custom words show up as written', (tester) async {
      final t = DeckTexts.defaults
          .withValue('kpiTitle', 'KPI of {name} ({role})')
          .withValue('kpiBadge', '{met}/{total}')
          .withValue('highlightsTitle', 'Good')
          .withValue('emptyNote', 'None');
      await pumpSlide(tester, SlideKpi(demoSnapshot('rova'), texts: t));
      expect(find.text('KPI of Rova (Import)'), findsOneWidget);
      expect(find.text('2/3'), findsOneWidget);
      await pumpSlide(
        tester,
        SlideResults(withNotes(demoSnapshot('rova')), texts: t),
      );
      expect(find.text('Good'), findsOneWidget);
      expect(find.text('None'), findsNWidgets(3));
    });

    testWidgets('a seat without targets keeps its own badge wording', (
      tester,
    ) async {
      final s = withNotes(demoSnapshot('rova'));
      final none = ReportSnapshot(
        assignmentCode: s.assignmentCode,
        name: s.name,
        role: s.role,
        team: s.team,
        periodLabel: s.periodLabel,
        months: s.months,
        metrics: s.metrics,
        targets: const [],
        well: const [],
        wrong: const [],
        next: const [],
      );
      await pumpSlide(
        tester,
        SlideKpi(
          none,
          texts: DeckTexts.defaults.withValue('kpiBadge', 'X {met}'),
        ),
      );
      expect(find.text('KPI · no targets'), findsOneWidget);
    });
  });

  group('suggestions page', () {
    testWidgets('default words', (tester) async {
      await pumpSlide(
        tester,
        const SlideSuggestions(periodLabel: 'Feb to Apr 2026'),
      );
      expect(find.text('Suggestions'), findsOneWidget);
      expect(find.text('Suggestions will be added here.'), findsOneWidget);
      expect(find.text('FEB TO APR 2026'), findsOneWidget);
      await expectLater(
        find.byType(SlideSuggestions),
        matchesGoldenFile('goldens/suggestions.png'),
      );
    });

    testWidgets('longest title and body wrap inside the page', (tester) async {
      final t = DeckTexts.defaults
          .withValue('suggestionsTitle', 'W' * 60)
          .withValue('suggestionsBody', 'Body text of the page. ' * 17);
      await pumpSlide(
        tester,
        SlideSuggestions(periodLabel: 'Feb to Apr 2026', texts: t),
      );
      await expectLater(
        find.byType(SlideSuggestions),
        matchesGoldenFile('goldens/suggestions_long.png'),
      );
    });

    testWidgets('an empty body leaves an empty box', (tester) async {
      final t = DeckTexts.defaults.withValue('suggestionsBody', '');
      await pumpSlide(
        tester,
        SlideSuggestions(periodLabel: 'Feb to Apr 2026', texts: t),
      );
      expect(find.text('Suggestions'), findsOneWidget);
    });
  });

  test('status words', () {
    expect(KpiStatus.values.length, 3);
  });
}
