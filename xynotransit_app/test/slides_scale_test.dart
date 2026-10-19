// Chart scales, zero labels, big note type and aligned KPI labels
// (F1 to F4), and the wording of the cover chips (F5).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xynotransit_app/core/theme/tokens.dart' show seriesColor;
import 'package:xynotransit_app/domain/deck_text.dart';
import 'package:xynotransit_app/domain/deck.dart';
import 'package:xynotransit_app/domain/enums.dart';
import 'package:xynotransit_app/domain/snapshot.dart';
import 'package:xynotransit_app/features/slides/alt_text.dart';
import 'package:xynotransit_app/features/slides/kpi_slide.dart';
import 'package:xynotransit_app/features/slides/palette.dart';
import 'package:xynotransit_app/features/slides/results_slide.dart';
import 'package:xynotransit_app/features/slides/slide_words.dart';
import 'package:xynotransit_app/features/slides/volumes_chart.dart';

import '../tool/slide_matrix.dart';
import 'helpers.dart';

ReportSnapshot withMetrics(List<List<int>> each) =>
    snap(metrics: metricsOf(each.length, each: each));

/// Heights of the bars of count [series], one per month.
List<double> barHeights(WidgetTester tester, int series) {
  final bars = find.byWidgetPredicate(
    (w) =>
        w is Container &&
        w.decoration is BoxDecoration &&
        (w.decoration! as BoxDecoration).color == seriesColor(series) &&
        (w.decoration! as BoxDecoration).borderRadius != null,
  );
  return [for (final e in bars.evaluate()) (e.size!).height];
}

void main() {
  setUpAll(loadAppFonts);
  const note = 'Each count has its own scale';

  group('F1 one scale or one per count', () {
    test('one scale up to 8 times, own scales beyond', () {
      expect(
        volumesOwnScale(
          withMetrics([
            [1000000000, 5, 5],
            [12, 12, 12],
          ]),
        ),
        isTrue,
      );
      expect(
        volumesOwnScale(
          withMetrics([
            [800, 5, 5],
            [100, 1, 1],
          ]),
        ),
        isFalse,
        reason: 'exactly 8 times shares a scale',
      );
      expect(
        volumesOwnScale(
          withMetrics([
            [801, 5, 5],
            [100, 1, 1],
          ]),
        ),
        isTrue,
      );
      expect(
        volumesOwnScale(
          withMetrics([
            [1000000000, 1, 1],
          ]),
        ),
        isFalse,
        reason: 'one count alone',
      );
      expect(
        volumesOwnScale(
          withMetrics([
            [1000000000, 1, 1],
            [0, 0, 0],
          ]),
        ),
        isFalse,
        reason: 'a count that is all zero does not decide',
      );
      expect(
        volumesOwnScale(
          withMetrics([
            [0, 0, 0],
            [0, 0, 0],
          ]),
        ),
        isFalse,
      );
    });

    testWidgets('1,000,000,000 beside 12: both bars are readable', (
      tester,
    ) async {
      await pumpSlide(
        tester,
        SlideKpi(
          withMetrics([
            [1000000000, 1000000000, 1000000000],
            [12, 12, 12],
          ]),
        ),
      );
      expect(find.text(note), findsOneWidget);
      final big = barHeights(tester, 0);
      final small = barHeights(tester, 1);
      expect(big, hasLength(3));
      expect(small, hasLength(3));
      // On one scale the 12 would be a 6 px stub (1 / 83,000,000 of the room).
      expect(small.first, closeTo(big.first, 0.5));
      expect(small.first, greaterThan(100));
    });

    testWidgets('counts of one size share a scale and print no note', (
      tester,
    ) async {
      await pumpSlide(
        tester,
        SlideKpi(
          withMetrics([
            [800, 900, 1000],
            [125, 100, 120],
          ]),
        ),
      );
      expect(find.text(note), findsNothing);
      final a = barHeights(tester, 0);
      final b = barHeights(tester, 1);
      // Common scale: 1000 is the tallest, 100 is a tenth of it.
      expect(b[1] / a[2], closeTo(100 / 1000, 0.02));
    });
  });

  group('F2 zero bars', () {
    test('zero labels only with 3 bars or fewer per month', () {
      expect(showBarLabel(0, 3), isTrue);
      expect(showBarLabel(0, 4), isFalse);
      expect(showBarLabel(7, 8), isTrue);
    });

    testWidgets('twelve zero bars show a tick and no zeros', (tester) async {
      await pumpSlide(
        tester,
        SlideKpi(
          withMetrics([
            [0, 0, 0],
            [0, 0, 0],
            [0, 0, 0],
            [0, 0, 0],
          ]),
        ),
      );
      // Only the four totals say 0.
      expect(find.text('0'), findsNWidgets(4));
      for (var i = 0; i < 4; i++) {
        expect(barHeights(tester, i), [3, 3, 3], reason: 'tick of count $i');
      }
    });

    testWidgets('with 3 counts the zeros stay', (tester) async {
      await pumpSlide(
        tester,
        SlideKpi(
          withMetrics([
            [0, 0, 0],
            [0, 0, 0],
            [0, 0, 0],
          ]),
        ),
      );
      // 3 totals and 9 bar labels.
      expect(find.text('0'), findsNWidgets(12));
    });
  });

  group('F3 results slide with few points', () {
    test('one short line per column gets 44 px, a full slide stays small', () {
      expect(
        pickNoteSize([
          ['Two routes'],
          ['One late'],
          ['Hire two'],
        ], 520),
        44,
      );
      expect(
        pickNoteSize([
          for (var i = 0; i < 3; i++) notesOf(3, 70, wideLetters: false),
        ], 520),
        lessThanOrEqualTo(32),
      );
      // Never below 20 px.
      expect(pickNoteSize([notesOf(3, 70)], 10), 20);
    });

    testWidgets('the text is big and sits in the middle of its card', (
      tester,
    ) async {
      await pumpSlide(
        tester,
        SlideResults(
          snap(well: ['Two routes'], wrong: ['One late'], next: ['Hire two']),
        ),
      );
      final t = find.text('Two routes');
      expect(tester.widget<Text>(t).style!.fontSize, 44);
      final card = find.ancestor(of: t, matching: find.byType(ClipRRect)).first;
      final header = find.text('Highlights');
      final room = tester.getRect(card);
      final above = tester.getRect(t).top - tester.getRect(header).bottom;
      final below = room.bottom - tester.getRect(t).bottom;
      expect(
        (above - below).abs(),
        lessThan(80),
        reason: 'above $above, below $below',
      );
      expect(above, greaterThan(100), reason: 'not stuck to the header');
    });
  });

  group('F4 aligned target labels', () {
    testWidgets('every KPI label is the same distance from its card top', (
      tester,
    ) async {
      for (final n in [3, 4]) {
        await pumpSlide(
          tester,
          SlideKpi(
            snap(
              targets: targetsOf(
                n,
                text: (i) => i.isEven ? 'On time' : words(n == 3 ? 110 : 40),
              ),
            ),
          ),
        );
        final labels = find.byWidgetPredicate(
          (w) => w is Text && RegExp(r'^KPI \d+ · ').hasMatch(w.data ?? ''),
        );
        expect(labels, findsNWidgets(n));
        final dist = <double>[];
        for (final l in labels.evaluate()) {
          final label = find.byWidget(l.widget);
          final card = find
              .ancestor(
                of: label,
                matching: find.byWidgetPredicate(
                  (w) =>
                      w is Container &&
                      w.decoration is BoxDecoration &&
                      (w.decoration! as BoxDecoration).borderRadius ==
                          BorderRadius.circular(20),
                ),
              )
              .first;
          dist.add(tester.getRect(label).top - tester.getRect(card).top);
        }
        for (final d in dist) {
          expect(d, closeTo(dist.first, 0.5), reason: '$n cards: $dist');
        }
      }
    });
  });

  group('F5 cover chips', () {
    test('default chip says the team, the count and the word report(s)', () {
      final w = SlideWords(DeckTexts.defaults);
      expect(w.coverPill('Kenya', 1), 'Kenya · 1 report');
      expect(w.coverPill('Kenya', 12), 'Kenya · 12 reports');
    });

    test('{reports} works in an own wording', () {
      final w = SlideWords(
        DeckTexts.defaults.withValue(
          'coverPill',
          '{count} {reports} from {team}',
        ),
      );
      expect(w.coverPill('Tana', 2), '2 reports from Tana');
    });
  });

  group('F5 target comments', () {
    Finder commentText() => find.byWidgetPredicate(
      (w) =>
          w is Text &&
          w.maxLines == 1 &&
          w.style?.fontSize == 20 &&
          w.style?.color == SlidePalette.mutedOnLight,
    );

    testWidgets(
      'a partly or missed target shows its comment as one muted line',
      (tester) async {
        await pumpSlide(
          tester,
          SlideKpi(snap(targets: commentedTargets(6, len: 30))),
        );
        // Cards 2, 3, 5 and 6 are partly or missed; 1 and 4 are met.
        expect(commentText(), findsNWidgets(4));
        for (final e in commentText().evaluate()) {
          final t = e.widget as Text;
          expect(t.data, endsWith('\u2026'), reason: '200 characters are cut');
          expect(tester.getSize(find.byWidget(t)).height, lessThan(30));
        }
      },
    );

    testWidgets('a short comment is shown whole', (tester) async {
      await pumpSlide(
        tester,
        SlideKpi(
          snap(
            targets: [
              for (var i = 0; i < 6; i++)
                CommentedTarget(
                  '${i + 1} ${words(28)}',
                  i.isEven ? KpiStatus.missed : KpiStatus.met,
                  'Truck lost for a week',
                ),
            ],
          ),
        ),
      );
      expect(find.text('Truck lost for a week'), findsNWidgets(3));
    });

    testWidgets('never in the dense grid, never for met or unanswered', (
      tester,
    ) async {
      await pumpSlide(
        tester,
        SlideKpi(snap(targets: commentedTargets(8, len: 30))),
      );
      expect(commentText(), findsNothing);
      await pumpSlide(
        tester,
        SlideKpi(
          snap(
            targets: [
              const CommentedTarget('A', KpiStatus.met, 'Fine'),
              const CommentedTarget('B', null, 'Not answered'),
            ],
          ),
        ),
      );
      expect(find.text('Fine'), findsNothing);
      expect(find.text('Not answered'), findsNothing);
    });

    testWidgets('no room, no comment', (tester) async {
      // Three cards of two lines of big type leave no space for a line.
      await pumpSlide(
        tester,
        SlideKpi(snap(targets: commentedTargets(3, len: 30))),
      );
      expect(commentText(), findsNothing);
      expect(tester.takeException(), isNull);
    });

    test('the speaker notes keep the whole comment', () {
      final long = words(200);
      final spec = KpiSlideSpec(
        snap(targets: [CommentedTarget('On time', KpiStatus.partly, long)]),
      );
      expect(
        slideNotes(spec),
        contains('1. On time: partly met. Comment: $long'),
      );
    });

    test(
      'commentLine cuts at a word and keeps the ellipsis inside the width',
      () {
        expect(commentLine('Short', 500), 'Short');
        final cut = commentLine(words(200), 500);
        expect(cut, endsWith('\u2026'));
        expect(cut.length, lessThan(100));
        expect(cut, isNot(contains('  ')));
      },
    );
  });

  group('target text width', () {
    testWidgets('a text the fit calls one line is one line on the slide', (
      tester,
    ) async {
      // The 1 px card border takes 2 px of the width. With 6 cards the text
      // of cards 4 to 6 ("4 Pallet transfer between hubs") used to wrap and
      // run out of its card although the fit had measured one line.
      final targets = targetsOf(6, len: 30);
      await pumpSlide(tester, SlideKpi(snap(targets: targets)));
      for (final t in targets) {
        final h = tester.getSize(find.text(t.text)).height;
        expect(h, lessThan(36 * 1.2 * 1.5), reason: '${t.text} wraps');
      }
    });
  });
}
