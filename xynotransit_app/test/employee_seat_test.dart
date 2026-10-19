import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xynotransit_app/app/app.dart';
import 'package:xynotransit_app/app/providers.dart';
import 'package:xynotransit_app/data/memory_repository.dart';
import 'package:xynotransit_app/data/repository.dart';
import 'package:xynotransit_app/data/seed_data.dart';
import 'package:xynotransit_app/domain/enums.dart';
import 'package:xynotransit_app/features/form/form_controller.dart';

import 'helpers.dart';

/// Tahina has two seats in the demo: Declarant export and BSC creation.
const tahina = AppUser(
  personId: 'p-tahina',
  role: AppRole.contributor,
  label: 'Tahina',
);

/// One "page load": a fresh app on the same device storage.
Future<ProviderContainer> load(
  WidgetTester tester,
  SharedPreferences prefs, {
  AppUser user = tahina,
}) async {
  final catalog = buildSeedCatalog();
  final auth = DemoAuth(catalog)..actAs(user);
  final repo = MemoryRepository(
    catalog: catalog,
    currentUser: () => auth.currentUser ?? DemoAuth.controller,
    withDemoReports: true,
  );
  tester.view.physicalSize = const Size(1500, 5200);
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
  return container;
}

void main() {
  setUpAll(loadAppFonts);

  testWidgets('the picker says "Choose a seat" and lists "Name · Seat title"', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await load(tester, await SharedPreferences.getInstance());
    await tester.tap(find.text('Choose a seat'));
    await tester.pumpAndSettle();
    expect(find.text('Tahina · Declarant export'), findsOneWidget);
    expect(find.text('Tahina · BSC creation'), findsOneWidget);
    // Nobody else is listed.
    expect(find.textContaining('Rova'), findsNothing);
  });

  testWidgets('choosing a seat closes the dropdown at once', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await load(tester, await SharedPreferences.getInstance());
    await tester.tap(find.text('Choose a seat'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Tahina · BSC creation').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    // Only the closed button shows the seat: no popup copy is left over.
    expect(find.text('Tahina · BSC creation'), findsOneWidget);
    expect(find.text('Tahina · Declarant export'), findsNothing);
    expect(find.text('Choose a seat'), findsNothing);
    expect(
      ModalRoute.of(tester.element(find.text('Who you are')))!.isCurrent,
      isTrue,
      reason: 'no popup route is left over the page',
    );
    // The form is there to be filled in.
    expect(find.text('Your numbers, month by month'), findsOneWidget);
  });

  testWidgets('the last chosen seat comes back after a reload', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    var c = await load(tester, prefs);
    expect(c.read(formControllerProvider).assignmentId, isNull);
    await tester.tap(find.text('Choose a seat'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Tahina · BSC creation').last);
    await tester.pumpAndSettle();
    final chosen = c.read(formControllerProvider).assignmentId;
    expect(chosen, isNotNull);

    // A reload: new app, same device.
    await tester.pumpWidget(const SizedBox());
    c = await load(tester, prefs);
    expect(c.read(formControllerProvider).assignmentId, chosen);
    expect(find.text('Tahina · BSC creation'), findsOneWidget);
    expect(find.text('Choose a seat'), findsNothing);
  });

  testWidgets('a person who clears the choice is not given it back', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final c = await load(tester, prefs);
    await tester.tap(find.text('Choose a seat'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Tahina · BSC creation').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Tahina · BSC creation'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Choose a seat').last);
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 1));
    expect(c.read(formControllerProvider).assignmentId, isNull);
    expect(find.text('Choose a seat'), findsOneWidget);
  });

  testWidgets('what one person chose is not used for another', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    var c = await load(tester, prefs);
    await tester.tap(find.text('Choose a seat'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Tahina · BSC creation').last);
    await tester.pumpAndSettle();
    expect(c.read(formControllerProvider).assignmentId, isNotNull);
    expect(prefs.getString(FormController.lastSeatKey('p-tahina')), isNotNull);
    expect(prefs.getString(FormController.lastSeatKey('p-rova')), isNull);
    // A manager on the same device has no memory of it.
    await tester.pumpWidget(const SizedBox());
    c = await load(tester, prefs, user: DemoAuth.controller);
    expect(c.read(formControllerProvider).assignmentId, isNull);
  });

  testWidgets('a remembered seat that is gone is ignored', (tester) async {
    SharedPreferences.setMockInitialValues({
      FormController.lastSeatKey('p-tahina'): 'no-such-seat',
    });
    final c = await load(tester, await SharedPreferences.getInstance());
    expect(c.read(formControllerProvider).assignmentId, isNull);
    expect(find.text('Choose a seat'), findsOneWidget);
  });

  testWidgets(
    'with the narrow employee catalog the form and the preview still work',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final c = await load(tester, await SharedPreferences.getInstance());
      final cat = await c.read(repositoryProvider).loadCatalog();
      expect(cat.persons.map((p) => p.id), ['p-tahina']);
      await tester.tap(find.text('Choose a seat'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Tahina · BSC creation').last);
      await tester.pumpAndSettle();
      String typed(String key) =>
          tester.widget<TextField>(find.byKey(ValueKey(key))).controller!.text;
      expect(typed('reporter-name'), 'Tahina');
      expect(typed('reporter-role'), 'BSC creation');
      expect(typed('reporter-country'), isNotEmpty);
      expect(find.text('Your slides'), findsOneWidget);
      expect(find.textContaining('Unknown person'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
