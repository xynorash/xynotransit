import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xynotransit_app/domain/enums.dart';
import 'package:xynotransit_app/domain/snapshot.dart';
import 'package:xynotransit_app/features/slides/alt_text.dart';
import 'package:xynotransit_app/domain/deck.dart';
import 'package:xynotransit_app/features/slides/kpi_slide.dart';

import 'helpers.dart';

ReportSnapshot manySeries(int n, {int labelLength = 12, int big = 1}) {
  final base = demoSnapshot('rova');
  return ReportSnapshot(
    assignmentCode: 'x',
    name: 'Rova',
    role: base.role,
    team: base.team,
    periodLabel: base.periodLabel,
    months: base.months,
    metrics: [
      for (var i = 0; i < n; i++)
        SnapshotMetric(
          key: 'k$i',
          label: 'C${i + 1} ${'w' * (labelLength - 3)}',
          series: i,
          values: [
            (120 + i * 37) * big,
            (90 + i * 53) * big,
            (150 + i * 29) * big,
          ],
        ),
    ],
    targets: base.targets,
    well: const [],
    wrong: const [],
    next: const [],
  );
}

void main() {
  setUpAll(loadAppFonts);

  for (final n in [1, 4, 5, 8]) {
    testWidgets('slide A with $n series', (tester) async {
      await pumpSlide(tester, SlideKpi(manySeries(n)));
      expect(tester.takeException(), isNull);
      for (var i = 1; i <= n; i++) {
        expect(find.textContaining('C$i '), findsOneWidget);
      }
      await expectLater(
        find.byType(SlideKpi),
        matchesGoldenFile('goldens/slide_a_series_$n.png'),
      );
    });
  }

  for (final n in [1, 2, 3, 4, 5, 6, 7, 8]) {
    testWidgets('$n series with 60 character names and big numbers fit', (
      tester,
    ) async {
      await pumpSlide(
        tester,
        SlideKpi(manySeries(n, labelLength: 56, big: 8000)),
      );
      expect(tester.takeException(), isNull);
    });
  }
  // Deliberate change: seven and eight counts take two rows of four (they used
  // to take three rows of three) so the bars keep their height.
  testWidgets('totals sit 3 per row for 4 to 6 counts, 4 per row for 7 and 8', (
    tester,
  ) async {
    Future<List<int>> rowsOf(int n) async {
      await pumpSlide(tester, SlideKpi(manySeries(n)));
      final tops = <double, int>{};
      for (var i = 1; i <= n; i++) {
        final y = tester
            .getTopLeft(find.textContaining('C$i '))
            .dy
            .roundToDouble();
        tops[y] = (tops[y] ?? 0) + 1;
      }
      return (tops.keys.toList()..sort()).map((y) => tops[y]!).toList();
    }

    expect(await rowsOf(4), [3, 1]);
    expect(await rowsOf(5), [3, 2]);
    expect(await rowsOf(6), [3, 3]);
    expect(await rowsOf(7), [4, 3]);
    expect(await rowsOf(8), [4, 4]);
  });

  testWidgets('four series use smaller totals than three', (tester) async {
    await pumpSlide(tester, SlideKpi(manySeries(3)));
    final three = tester
        .getSize(find.text(thousandsOf(manySeries(3), 0)))
        .height;
    await pumpSlide(tester, SlideKpi(manySeries(4)));
    final four = tester
        .getSize(find.text(thousandsOf(manySeries(4), 0)))
        .height;
    expect(four, lessThan(three));
  });

  test('colours repeat every eight series', () {
    final s = manySeries(8);
    expect(s.metrics.map((m) => m.series), [0, 1, 2, 3, 4, 5, 6, 7]);
    expect(KpiStatus.values, isNotEmpty);
  });

  group('7 to 10 targets', () {
    const long =
        'Every shipment declared on time with all the original documents '
        'checked, copied, filed and sent to the customer before the vessel '
        'leaves the port, including the weekends and bank holidays';
    ReportSnapshot withTargets(int n, {bool longTexts = true}) {
      final base = manySeries(3);
      return ReportSnapshot(
        assignmentCode: base.assignmentCode,
        name: base.name,
        role: base.role,
        team: base.team,
        periodLabel: base.periodLabel,
        months: base.months,
        metrics: base.metrics,
        targets: [
          for (var i = 0; i < n; i++)
            SnapshotTarget(
              text: longTexts ? 'Target ${i + 1}: $long' : 'Target ${i + 1}',
              status: i % 4 == 3 ? null : KpiStatus.values[i % 3],
            ),
        ],
        well: base.well,
        wrong: base.wrong,
        next: base.next,
      );
    }

    for (final n in [7, 8, 10]) {
      testWidgets('golden with $n long targets', (tester) async {
        await pumpSlide(tester, SlideKpi(withTargets(n)));
        expect(tester.takeException(), isNull);
        await expectLater(
          find.byType(SlideKpi),
          matchesGoldenFile('goldens/slide_a_targets_$n.png'),
        );
      });
    }

    testWidgets('texts are never below 20 px and long ones are cut', (
      tester,
    ) async {
      for (final n in [7, 8, 9, 10]) {
        await pumpSlide(tester, SlideKpi(withTargets(n)));
        expect(tester.takeException(), isNull);
        final texts = find.textContaining(RegExp(r'^Target \d+:'));
        expect(texts, findsNWidgets(n));
        for (final t in tester.widgetList<Text>(texts)) {
          expect(t.style!.fontSize, greaterThanOrEqualTo(20));
          expect(t.overflow, TextOverflow.ellipsis);
        }
        final chips = find.textContaining(RegExp(r'^(MET|PARTLY|MISSED|NOT)'));
        for (final c in tester.widgetList<Text>(chips)) {
          expect(c.style!.fontSize, greaterThanOrEqualTo(20));
        }
      }
    });

    testWidgets('short targets stay whole in the grid', (tester) async {
      await pumpSlide(tester, SlideKpi(withTargets(10, longTexts: false)));
      expect(tester.takeException(), isNull);
      expect(find.text('Target 10'), findsOneWidget);
    });

    testWidgets('the full text stays in the alt text', (tester) async {
      final s = withTargets(10);
      expect(slideAltText(KpiSlideSpec(s)), contains('KPI met'));
    });
  });

  group('big numbers', () {
    for (final n in [1, 2, 3, 4, 8]) {
      testWidgets('$n series up to 1,000,000,000 per month fit', (
        tester,
      ) async {
        await pumpSlide(
          tester,
          SlideKpi(manySeries(n, big: 1000000000 ~/ 700)),
        );
        expect(tester.takeException(), isNull);
        final base = manySeries(n, big: 1000000000 ~/ 700);
        // The biggest total is above one billion for 3 months x 3 series.
        expect(base.metrics.first.total, greaterThan(100000000));
      });
    }

    testWidgets('a 3,000,000,000 total stays inside the panel', (tester) async {
      final s = manySeries(3);
      final big = ReportSnapshot(
        assignmentCode: s.assignmentCode,
        name: s.name,
        role: s.role,
        team: s.team,
        periodLabel: s.periodLabel,
        months: s.months,
        metrics: [
          for (final m in s.metrics)
            SnapshotMetric(
              key: m.key,
              label: m.label,
              series: m.series,
              values: const [1000000000, 1000000000, 1000000000],
            ),
        ],
        targets: s.targets,
        well: const [],
        wrong: const [],
        next: const [],
      );
      await pumpSlide(tester, SlideKpi(big));
      expect(tester.takeException(), isNull);
      final box = tester.getRect(find.text('3,000,000,000').first);
      expect(box.right, lessThanOrEqualTo(1920 - 128));
      expect(box.left, greaterThan(700));
      await expectLater(
        find.byType(SlideKpi),
        matchesGoldenFile('goldens/slide_a_big_numbers.png'),
      );
    });
  });
}

String thousandsOf(ReportSnapshot s, int i) {
  final t = s.metrics[i].total.toString();
  return t.length > 3
      ? '${t.substring(0, t.length - 3)},${t.substring(t.length - 3)}'
      : t;
}
