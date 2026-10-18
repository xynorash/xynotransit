import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xynotransit_app/app/app.dart';
import 'package:xynotransit_app/app/providers.dart';
import 'package:xynotransit_app/data/memory_repository.dart';
import 'package:xynotransit_app/data/seed_data.dart';
import 'package:xynotransit_app/features/preview/preview_pane.dart';
import 'package:xynotransit_app/features/slides/slide_view.dart';

import 'helpers.dart';

Future<ProviderContainer> pumpAt(
  WidgetTester tester,
  Size size, {
  bool demo = true,
  String location = '/manager/reports',
}) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final catalog = buildSeedCatalog();
  final auth = DemoAuth(catalog);
  final repo = MemoryRepository(
    catalog: catalog,
    currentUser: () => auth.currentUser ?? DemoAuth.controller,
    withDemoReports: demo,
  );
  tester.view.physicalSize = size;
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
  if (location != '/') {
    container.read(routerProvider).go(location);
    await tester.pumpAndSettle();
  }
  return container;
}

Future<void> generate(WidgetTester tester) async {
  await tester.tap(find.text('Generate slides'));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(loadAppFonts);

  const emptyText =
      'No slides yet. When the controller generates them, every slide of the '
      'deck appears here in order, exactly as it will be presented.';

  testWidgets('empty state explains what will appear', (tester) async {
    await pumpAt(tester, const Size(1500, 900), demo: false);
    expect(find.text(emptyText), findsOneWidget);
    expect(find.byType(SlideStage), findsNothing);
  });

  testWidgets('wide: slides on the left, dashboard on the right', (
    tester,
  ) async {
    await pumpAt(tester, const Size(1500, 900));
    final preview = tester.getTopLeft(find.text('Slide preview')).dx;
    for (final t in ['Report dashboard', 'Period', 'Reports received']) {
      expect(preview, lessThan(tester.getTopLeft(find.text(t)).dx), reason: t);
    }
    expect(find.text('Period and person'), findsNothing);
    expect(find.text('Your numbers, month by month'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('wide: heading, period and table stack on the right', (
    tester,
  ) async {
    await pumpAt(tester, const Size(1500, 900));
    final h = tester.getTopLeft(find.text('Report dashboard')).dy;
    final p = tester.getTopLeft(find.text('Period')).dy;
    final r = tester.getTopLeft(find.text('Reports received')).dy;
    expect(h, lessThan(p));
    expect(p, lessThan(r));
  });

  testWidgets('narrow: dashboard is above the slides', (tester) async {
    await pumpAt(tester, const Size(800, 6000));
    final preview = tester.getTopLeft(find.text('Slide preview'));
    for (final t in ['Report dashboard', 'Period', 'Reports received']) {
      expect(
        tester.getTopLeft(find.text(t)).dy,
        lessThan(preview.dy),
        reason: t,
      );
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('generate shows numbered captions and builds slides lazily', (
    tester,
  ) async {
    await pumpAt(tester, const Size(1500, 900));
    await generate(tester);
    expect(find.text('Slide 1 of 34 · Cover'), findsOneWidget);
    final built = find.byType(SlideStage).evaluate().length;
    expect(built, greaterThan(0));
    expect(built, lessThan(34));
    expect(tester.takeException(), isNull);
  });

  testWidgets('SlideNav.jumpTo scrolls and updates current', (tester) async {
    final c = await pumpAt(tester, const Size(1500, 900));
    await generate(tester);
    final nav = c.read(slideNavProvider);
    expect(nav.current.value, 0);
    final before = nav.controller.offset;
    nav.jumpTo(10);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(nav.controller.offset, greaterThan(before));
    expect(nav.current.value, 10);
    expect(find.text('Slide 11 of 34', skipOffstage: true), findsNothing);
    expect(find.textContaining('Slide 11 of 34 · '), findsOneWidget);
    expect(find.text('11 · ', findRichText: false), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('dropdown jumps to the chosen slide', (tester) async {
    final c = await pumpAt(tester, const Size(1500, 900));
    await generate(tester);
    await tester.tap(find.text('1 · Cover').first);
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining(RegExp(r'^5 · ')).last);
    await tester.pumpAndSettle();
    final nav = c.read(slideNavProvider);
    expect(nav.current.value, 4);
    expect(find.textContaining('Slide 5 of 34 · '), findsOneWidget);
  });

  testWidgets('scrolling moves the dropdown selection', (tester) async {
    final c = await pumpAt(tester, const Size(1500, 900));
    await generate(tester);
    final nav = c.read(slideNavProvider);
    nav.controller.jumpTo(nav.controller.offset + nav.extent * 7);
    await tester.pumpAndSettle();
    expect(nav.current.value, 7);
    expect(find.textContaining(RegExp(r'^8 · ')), findsWidgets);
  });

  testWidgets('Next slide button moves the selection', (tester) async {
    final c = await pumpAt(tester, const Size(1500, 900));
    await generate(tester);
    await tester.tap(find.bySemanticsLabel('Next slide'));
    await tester.pumpAndSettle();
    expect(c.read(slideNavProvider).current.value, 1);
  });
}
