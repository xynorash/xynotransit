import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xynotransit_app/domain/enums.dart';
import 'package:xynotransit_app/domain/report.dart';

import 'app_test.dart' show Harness, pumpApp;
import 'generate_partial_test.dart' show sendRova;
import 'helpers.dart';
import 'roles_test.dart' show go;

/// Rova sent a report, then was switched off. Reports page, 14 seats before.
Future<Harness> rovaSwitchedOff(
  WidgetTester tester, {
  String location = '/manager/reports',
  Size size = const Size(1500, 5200),
}) async {
  final h = await pumpApp(tester, size: size, location: location);
  await sendRova(tester, h);
  await h.repo.savePerson(
    id: 'p-rova',
    fullName: 'Rova',
    email: '',
    role: AppRole.contributor,
    active: false,
  );
  await tester.pumpAndSettle();
  return h;
}

void main() {
  setUpAll(loadAppFonts);

  testWidgets('a switched-off person keeps their row but is not counted', (
    tester,
  ) async {
    await rovaSwitchedOff(tester);
    // 13 seats are expected, none of them has sent. N is never above M.
    expect(find.textContaining('0 of 13 · '), findsOneWidget);
    expect(find.textContaining('1 of 13'), findsNothing);
    expect(find.textContaining('of 1 '), findsNothing);
    expect(find.byKey(const ValueKey('switched-off-note')), findsOneWidget);
    expect(
      find.textContaining('1 report from a switched-off person'),
      findsOneWidget,
    );
    // The row is still in the table, tagged, with no Edit button.
    expect(find.byKey(const ValueKey('inactive-tag-rova')), findsOneWidget);
    expect(find.bySemanticsLabel('Edit report of Rova, Import'), findsNothing);
    // Nobody waits for Rova.
    expect(find.text('Rova · Import'), findsNothing);
    // The deck header counts what the deck will hold.
    expect(find.textContaining('0 of 13 reports in for'), findsOneWidget);
    expect(
      find.textContaining(', plus 1 from a switched-off person'),
      findsOneWidget,
    );
  });

  testWidgets('the deck still includes the switched-off person\'s report', (
    tester,
  ) async {
    await rovaSwitchedOff(tester);
    await tester.tap(find.text('Generate slides'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining(
        '0 of 13 reports are in, plus 1 from a switched-off person.',
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('Generate anyway'));
    await tester.pumpAndSettle();
    // Cover, one divider, Rova's two slides, suggestions.
    expect(find.text('Slide 1 of 5 · Cover'), findsOneWidget);
    expect(find.text('Slide 5 of 5 · Suggestions'), findsOneWidget);
    expect(find.byKey(const ValueKey('new-reports-notice')), findsNothing);
  });

  testWidgets('a person with two seats shows the seat in the table', (
    tester,
  ) async {
    await pumpApp(tester, demo: true, location: '/manager/reports');
    final tahina = catalog.assignments.where((a) => a.personId == 'p-tahina');
    expect(tahina.length, 2);
    for (final a in tahina) {
      expect(
        find.text('Tahina · ${a.roleTitle}'),
        findsWidgets,
        reason: a.code,
      );
    }
    // One-seat people stay with their name alone.
    expect(find.text('Rova'), findsWidgets);
    expect(find.text('Rova · Import'), findsNothing);
  });

  testWidgets('typed country and role show when they differ from the profile', (
    tester,
  ) async {
    final h = await pumpApp(tester, demo: true, location: '/manager/reports');
    // The demo reports say what the profile says: no extra line.
    expect(find.textContaining('On the slides:'), findsNothing);
    final p = await h.repo.ensurePeriod(DateTime(2026, 2));
    final src = (await h.repo.getReport(p.id, 'rova'))!;
    await h.repo.sendReport(
      Report(
        periodId: p.id,
        assignmentId: 'rova',
        values: src.values,
        kpis: src.kpis,
        notes: {
          NoteKind.well: ['A very good first note', 'Second'],
          NoteKind.wrong: [],
          NoteKind.next: [],
        },
        reporter: const Reporter(
          name: 'Rova R.',
          country: 'Kenya',
          role: 'Lead importer',
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.text('On the slides: Rova R. · Kenya · Lead importer'),
      findsOneWidget,
    );
    expect(find.text('2 points'), findsOneWidget);
    expect(find.text('A very good first note'), findsOneWidget);
    // The first note also reads as a tooltip.
    expect(
      find.byWidgetPredicate(
        (w) => w is Tooltip && w.message == 'A very good first note',
      ),
      findsOneWidget,
    );
  });

  testWidgets('narrow screen: tag and typed words fit, no overflow', (
    tester,
  ) async {
    await rovaSwitchedOff(tester, size: const Size(390, 2400));
    expect(find.byKey(const ValueKey('inactive-tag-rova')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Go: the page keeps working after the switch-off', (
    tester,
  ) async {
    final h = await rovaSwitchedOff(tester);
    await go(tester, h, '/manager');
    // Let the summary reload that follows the change settle.
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
