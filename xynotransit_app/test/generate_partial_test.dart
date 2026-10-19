import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xynotransit_app/data/repository.dart';
import 'package:xynotransit_app/domain/enums.dart';
import 'package:xynotransit_app/domain/report.dart';
import 'package:xynotransit_app/data/memory_repository.dart';

import 'app_test.dart' show Harness, pumpApp;
import 'helpers.dart';

const rovaUser = AppUser(
  personId: 'p-rova',
  role: AppRole.contributor,
  label: 'Rova',
);
const _rova = Reporter(name: 'Rova', country: 'Madagascar', role: 'Import');

Future<void> sendRova(WidgetTester tester, Harness h) async {
  final tmp = MemoryRepository(
    catalog: catalog,
    currentUser: () => h.auth.currentUser!,
    withDemoReports: true,
  );
  final dp = await tmp.ensurePeriod(MemoryRepository.demoStart);
  final p = await h.repo.ensurePeriod(MemoryRepository.demoStart);
  final src = (await tmp.getReport(dp.id, 'rova'))!;
  await h.repo.sendReport(
    Report(
      periodId: p.id,
      assignmentId: 'rova',
      values: src.values,
      kpis: src.kpis,
      notes: src.notes,
      reporter: _rova,
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(loadAppFonts);

  testWidgets('zero reports: confirm, then a deck of 2 slides', (tester) async {
    await pumpApp(tester, location: '/manager/reports');
    final button = find.text('Generate slides');
    expect(button, findsOneWidget);
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(
      find.text(
        'No reports are in yet. The deck will only have the cover and the suggestions page.',
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('Generate anyway'));
    await tester.pumpAndSettle();
    expect(find.text('Regenerate slides'), findsOneWidget);
    expect(find.text('Slide 1 of 2 · Cover'), findsOneWidget);
    expect(find.text('Slide 2 of 2 · Suggestions'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('1 of 14: names the missing, Wait cancels, deck has 5', (
    tester,
  ) async {
    final h = await pumpApp(tester, location: '/manager/reports');
    await sendRova(tester, h);
    await tester.tap(find.text('Generate slides'));
    await tester.pumpAndSettle();
    expect(
      find.text(
        '1 of 14 reports are in. Generate the slides with what you have?',
      ),
      findsOneWidget,
    );
    expect(find.text('Tahina · BSC creation'), findsWidgets);
    expect(find.text('Rova · Import'), findsNothing);
    expect(find.textContaining('+ 1 more'), findsOneWidget);
    await tester.tap(find.text('Wait'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('confirm-text')), findsNothing);
    expect(find.text('Not generated yet'), findsOneWidget);

    await tester.tap(find.text('Generate slides'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Generate anyway'));
    await tester.pumpAndSettle();
    expect(find.text('Slide 1 of 5 · Cover'), findsOneWidget);
    expect(find.text('Slide 5 of 5 · Suggestions'), findsOneWidget);
  });

  testWidgets(
    'a report sent after the deck shows the banner until regenerate',
    (tester) async {
      final h = await pumpApp(tester, location: '/manager/reports');
      await tester.tap(find.text('Generate slides'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Generate anyway'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('new-reports-notice')), findsNothing);
      await sendRova(tester, h);
      expect(
        find.text(
          '1 report was sent after this deck was generated. Regenerate to include it.',
        ),
        findsOneWidget,
      );
      await tester.tap(find.text('Regenerate slides'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Generate anyway'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('new-reports-notice')), findsNothing);
      expect(find.text('Slide 1 of 5 · Cover'), findsOneWidget);
    },
  );

  testWidgets('contributor has no generate button', (tester) async {
    await pumpApp(tester, demo: true, user: rovaUser, location: '/report');
    expect(find.text('Generate slides'), findsNothing);
  });

  for (final size in const [Size(360, 800), Size(800, 1100), Size(1500, 900)]) {
    testWidgets('no overflow at $size, text scale 2', (tester) async {
      tester.platformDispatcher.textScaleFactorTestValue = 2.0;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final h = await pumpApp(tester, size: size, location: '/manager/reports');
      await sendRova(tester, h);
      final gen = find.text('Generate slides');
      // Scroll in steps until the button is really on screen: it is built
      // a little before it is visible, and the page above it can be tall.
      await tester.scrollUntilVisible(
        gen,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(gen);
      await tester.pumpAndSettle();
      await tester.tap(gen);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final any = find.text('Generate anyway');
      await tester.ensureVisible(any);
      await tester.tap(any);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }
}
