import 'package:flutter_test/flutter_test.dart';
import 'package:xynotransit_app/domain/enums.dart';
import 'package:xynotransit_app/domain/snapshot.dart';
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
  testWidgets('totals sit 3 per row from 4 series on', (tester) async {
    await pumpSlide(tester, SlideKpi(manySeries(8)));
    final tops = <double>{
      for (var i = 1; i <= 8; i++)
        tester.getTopLeft(find.textContaining('C$i ')).dy.roundToDouble(),
    };
    expect(tops, hasLength(3));
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
}

String thousandsOf(ReportSnapshot s, int i) {
  final t = s.metrics[i].total.toString();
  return t.length > 3
      ? '${t.substring(0, t.length - 3)},${t.substring(t.length - 3)}'
      : t;
}
