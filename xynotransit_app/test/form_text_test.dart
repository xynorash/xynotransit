import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xynotransit_app/app/app.dart';
import 'package:xynotransit_app/app/providers.dart';
import 'package:xynotransit_app/core/theme/tokens.dart';
import 'package:xynotransit_app/core/widgets.dart';
import 'package:xynotransit_app/data/memory_repository.dart';
import 'package:xynotransit_app/domain/catalog.dart';
import 'package:xynotransit_app/domain/enums.dart';
import 'package:xynotransit_app/features/form/form_controller.dart';

import 'helpers.dart';

Catalog customCatalog(int counts, {String labelPrefix = 'Count'}) => Catalog(
  teams: const [Team(id: 't', code: 't', name: 'Team', sort: 1)],
  persons: const [
    Person(id: 'p', fullName: 'Ana', appRole: AppRole.controller),
  ],
  assignments: [
    Assignment(
      id: 'a',
      code: 'a',
      personId: 'p',
      teamId: 't',
      roleTitle: 'Clerk',
      sort: 1,
      metrics: [
        for (var i = 0; i < counts; i++)
          MetricDef(id: 'm$i', key: 'k$i', label: '$labelPrefix $i', series: i),
      ],
      kpis: const [
        KpiDef(id: 'k1', sort: 1, text: 'First target'),
        KpiDef(id: 'k2', sort: 2, text: 'Second target'),
      ],
    ),
  ],
);

Future<ProviderContainer> pumpCustom(
  WidgetTester tester,
  Catalog catalog,
) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final auth = DemoAuth(catalog);
  final repo = MemoryRepository(
    catalog: catalog,
    currentUser: () => auth.currentUser ?? DemoAuth.controller,
  );
  tester.view.physicalSize = const Size(1500, 7000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final container = ProviderContainer(
    overrides: [
      prefsProvider.overrideWithValue(prefs),
      repositoryProvider.overrideWithValue(repo),
      authServiceProvider.overrideWithValue(auth),
      initialStartProvider.overrideWithValue(MemoryRepository.demoStart),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const XynotransitApp(),
    ),
  );
  await tester.pumpAndSettle();
  container.read(routerProvider).go('/report');
  await tester.pumpAndSettle();
  // One seat: it is selected by itself and no chooser is shown.
  expect(find.text('Reporting for'), findsNothing);
  return container;
}

Finder point(String n, {int box = 0}) =>
    find.widgetWithText(TextField, 'Point $n').at(box);

void main() {
  setUpAll(loadAppFonts);

  group('notes in own words', () {
    testWidgets('three always-visible fields per box, no chips', (
      tester,
    ) async {
      final c = await pumpCustom(tester, customCatalog(1));
      expect(find.widgetWithText(TextField, 'Point 1'), findsNWidgets(3));
      expect(find.widgetWithText(TextField, 'Point 2'), findsNWidgets(3));
      expect(find.widgetWithText(TextField, 'Point 3'), findsNWidgets(3));
      expect(find.text('Add'), findsNothing);
      expect(find.text('Write your own'), findsNothing);
      expect(c.read(formControllerProvider).report!.noteCount, 0);
    });

    testWidgets('typing fills the box, counter and 70 character cap', (
      tester,
    ) async {
      final c = await pumpCustom(tester, customCatalog(1));
      await tester.enterText(point('1'), 'x' * 90);
      await tester.pump();
      expect(tester.widget<TextField>(point('1')).controller!.text.length, 70);
      expect(find.text('70/70'), findsOneWidget);
      await tester.enterText(point('2'), 'Faster customs desk');
      await tester.pump();
      expect(find.text('19/70'), findsOneWidget);
      expect(find.text('2 of 3'), findsOneWidget);
      expect(c.read(formControllerProvider).report!.notesOf(NoteKind.well), [
        'x' * 70,
        'Faster customs desk',
      ]);
    });

    testWidgets('blank lines are ignored, order is kept, text is trimmed', (
      tester,
    ) async {
      final c = await pumpCustom(tester, customCatalog(1));
      await tester.enterText(point('3'), '  third  ');
      await tester.pump();
      await tester.enterText(point('1'), 'first');
      await tester.pump();
      await tester.enterText(point('2'), '   ');
      await tester.pump();
      expect(c.read(formControllerProvider).report!.notesOf(NoteKind.well), [
        'first',
        'third',
      ]);
      await tester.enterText(point('1'), '');
      await tester.pump();
      expect(c.read(formControllerProvider).report!.notesOf(NoteKind.well), [
        'third',
      ]);
      // Other boxes are untouched.
      expect(
        c.read(formControllerProvider).report!.notesOf(NoteKind.wrong),
        isEmpty,
      );
    });

    testWidgets('the draft is restored with the same words', (tester) async {
      final c = await pumpCustom(tester, customCatalog(1));
      await tester.enterText(point('1', box: 1), 'Late vessel');
      await tester.pump();
      await c.read(formControllerProvider.notifier).selectAssignment(null);
      await c.read(formControllerProvider.notifier).selectAssignment('a');
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(point('1', box: 1)).controller!.text,
        'Late vessel',
      );
    });

    testWidgets('every point field has a screen reader label', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpCustom(tester, customCatalog(1));
      expect(
        find.bySemanticsLabel(RegExp(r', point [123]$')),
        findsNWidgets(9),
      );
      handle.dispose();
    });
  });

  group('target comments', () {
    testWidgets('optional comment is kept with the status, 200 chars max', (
      tester,
    ) async {
      final c = await pumpCustom(tester, customCatalog(1));
      final box = find.widgetWithText(TextField, 'Comment (optional)');
      expect(box, findsNWidgets(2));
      await tester.enterText(box.first, 'y' * 260);
      await tester.pump();
      expect(tester.widget<TextField>(box.first).controller!.text.length, 200);
      expect(find.text('200/200'), findsOneWidget);
      // Typed before the status: kept, and joined when the status is chosen.
      await tester.tap(find.text('Partly').first);
      await tester.pump();
      final r = c.read(formControllerProvider).report!;
      expect(r.kpis['k1']!.status, KpiStatus.partly);
      expect(r.kpis['k1']!.comment, 'y' * 200);
      // Changing the status keeps the comment.
      await tester.tap(find.text('Met').first);
      await tester.pump();
      expect(
        c.read(formControllerProvider).report!.kpis['k1']!.comment,
        'y' * 200,
      );
      // Clearing removes it.
      await tester.enterText(box.first, '  ');
      await tester.pump();
      expect(
        c.read(formControllerProvider).report!.kpis['k1']!.comment,
        isNull,
      );
    });

    testWidgets('comments are sent and come back on a second visit', (
      tester,
    ) async {
      final c = await pumpCustom(tester, customCatalog(1));
      final box = find.widgetWithText(TextField, 'Comment (optional)');
      await tester.tap(find.text('Missed').at(1));
      await tester.pump();
      await tester.enterText(box.at(1), 'Customs strike in March');
      await tester.pump();
      await tester.tap(find.text('Met').first);
      await tester.pump();
      final fields = find.byType(NumberField);
      for (var i = 0; i < 3; i++) {
        await tester.enterText(
          find.descendant(of: fields.at(i), matching: find.byType(TextField)),
          '5',
        );
      }
      await tester.tap(find.text('Send report'));
      await tester.pumpAndSettle();
      final repo = c.read(repositoryProvider);
      final p = await repo.ensurePeriod(MemoryRepository.demoStart);
      final saved = (await repo.getReport(p.id, 'a'))!;
      expect(saved.kpis['k2']!.comment, 'Customs strike in March');
      expect(saved.kpis['k1']!.comment, isNull);

      await c.read(formControllerProvider.notifier).selectAssignment(null);
      await c.read(formControllerProvider.notifier).selectAssignment('a');
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(
              find.widgetWithText(TextField, 'Comment (optional)').at(1),
            )
            .controller!
            .text,
        'Customs strike in March',
      );
    });
  });

  group('number of counts', () {
    for (final n in [1, 8]) {
      testWidgets('the form works with $n count(s)', (tester) async {
        await pumpCustom(tester, customCatalog(n));
        expect(tester.takeException(), isNull);
        expect(find.byType(NumberField), findsNWidgets(n * 3));
        for (var i = 0; i < n * 3; i++) {
          await tester.enterText(
            find
                .descendant(
                  of: find.byType(NumberField).at(i),
                  matching: find.byType(TextField),
                )
                .first,
            '${i + 1}',
          );
        }
        await tester.pump();
        expect(find.text('Total 6'), findsOneWidget);
        // Colour dots come from the shared palette.
        final dots = find.byWidgetPredicate(
          (w) =>
              w is Container &&
              w.decoration is BoxDecoration &&
              XynoTokens.series.contains(
                (w.decoration! as BoxDecoration).color,
              ) &&
              w.constraints?.maxWidth == 12,
        );
        expect(dots, findsNWidgets(n));
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('long count names wrap without overflow', (tester) async {
      await pumpCustom(
        tester,
        customCatalog(8, labelPrefix: 'Very long count name ' * 3),
      );
      expect(tester.takeException(), isNull);
    });

    test('series colours repeat after eight', () {
      expect(XynoTokens.series, hasLength(8));
      expect(seriesColor(0), XynoTokens.series[0]);
      expect(seriesColor(8), XynoTokens.series[0]);
      expect(seriesColor(11), XynoTokens.series[3]);
      expect(XynoTokens.series.toSet(), hasLength(8));
    });
  });
}
