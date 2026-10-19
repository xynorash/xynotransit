import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xynotransit_app/app/app.dart';
import 'package:xynotransit_app/app/providers.dart';
import 'package:xynotransit_app/core/widgets.dart';
import 'package:xynotransit_app/data/memory_repository.dart';
import 'package:xynotransit_app/data/repository.dart';
import 'package:xynotransit_app/data/seed_data.dart';
import 'package:xynotransit_app/domain/enums.dart';
import 'package:xynotransit_app/features/preview/preview_pane.dart';
import 'package:xynotransit_app/domain/report.dart';

import 'helpers.dart';

class Harness {
  Harness(this.repo, this.auth, this.container);
  final MemoryRepository repo;
  final DemoAuth auth;
  final ProviderContainer container;
}

Future<Harness> pumpApp(
  WidgetTester tester, {
  bool demo = false,
  AppUser? user,
  Size size = const Size(1500, 5200),
  String location = '/report',
}) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final catalog = buildSeedCatalog();
  final auth = DemoAuth(catalog);
  if (user != null) auth.actAs(user);
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
  return Harness(repo, auth, container);
}

Future<void> goTo(WidgetTester tester, Harness h, String path) async {
  h.container.read(routerProvider).go(path);
  await tester.pumpAndSettle();
}

SlideNav pumpedNav(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(XynotransitApp)))
        .read(slideNavProvider);

Future<void> choosePerson(WidgetTester tester, String label) async {
  await tester.tap(find.text('Choose your name'));
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

Future<void> fillRova(WidgetTester tester) async {
  final fields = find.byType(NumberField);
  expect(fields, findsNWidgets(6));
  for (var i = 0; i < 6; i++) {
    await tester.enterText(
      find.descendant(of: fields.at(i), matching: find.byType(TextField)),
      '${10 + i}',
    );
  }
  for (var i = 0; i < 3; i++) {
    await tester.tap(find.text('Met').at(i));
  }
  await tester.pump();
}

void main() {
  setUpAll(loadAppFonts);

  testWidgets('cards 2 to 4 stay hidden until a person is chosen', (
    tester,
  ) async {
    await pumpApp(tester);
    expect(find.text('Who you are'), findsOneWidget);
    expect(
      find.text(
        'Choose who you are reporting for to see the fields for the role.',
      ),
      findsOneWidget,
    );
    expect(find.text('Your numbers, month by month'), findsNothing);
    expect(find.text('Send report'), findsNothing);

    await choosePerson(tester, 'Rova · Import');
    expect(find.text('Your numbers, month by month'), findsOneWidget);
    expect(find.text('Did you reach your targets?'), findsOneWidget);
    expect(find.text('What to tell the meeting'), findsOneWidget);
    expect(find.text('Send report'), findsOneWidget);
  });

  testWidgets('roles without counts skip the numbers card', (tester) async {
    await pumpApp(tester);
    await choosePerson(tester, 'Shalini · Shipping clerk');
    expect(find.text('Your numbers, month by month'), findsNothing);
    expect(find.text('Did you reach your targets?'), findsOneWidget);
  });

  testWidgets('the form header reads as specified', (tester) async {
    await pumpApp(tester);
    expect(find.text('Logistics Report Builder'), findsOneWidget);
    expect(find.text('This report covers Feb to Apr 2026.'), findsOneWidget);
  });

  testWidgets('sending is blocked until every number and target is answered', (
    tester,
  ) async {
    final h = await pumpApp(tester);
    await choosePerson(tester, 'Rova · Import');
    await tester.tap(find.text('Send report'));
    await tester.pumpAndSettle();
    expect(find.text('Almost there.'), findsOneWidget);
    expect(
      find.text('Enter a number for "Air imports (IM5)" in February.'),
      findsOneWidget,
    );
    expect(
      find.text('Enter a number for "Sea imports (IM5)" in February.'),
      findsOneWidget,
    );
    expect(find.text('Answer all targets in step 3 (3 left).'), findsOneWidget);
    final reports = await h.repo
        .watchReports(
          (await h.repo.ensurePeriod(MemoryRepository.demoStart)).id,
        )
        .first;
    expect(reports, isEmpty);
  });

  testWidgets('totals update as numbers are typed', (tester) async {
    await pumpApp(tester);
    await choosePerson(tester, 'Rova · Import');
    final fields = find.byType(NumberField);
    for (var i = 0; i < 3; i++) {
      await tester.enterText(
        find.descendant(of: fields.at(i), matching: find.byType(TextField)),
        '${(i + 1) * 500}',
      );
    }
    await tester.pump();
    expect(find.text('Total 3,000'), findsOneWidget);
  });

  testWidgets(
    'a full report is sent, shows in the table and can be sent again',
    (tester) async {
      final h = await pumpApp(tester);
      await choosePerson(tester, 'Rova · Import');
      await fillRova(tester);
      await tester.enterText(
        find.widgetWithText(TextField, 'Point 1').first,
        'Declarations on time',
      );
      await tester.pump();
      await tester.tap(find.text('Send report'));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('Sent. The summary is at the top'),
        findsOneWidget,
      );
      expect(
        find.textContaining('You already sent this report on'),
        findsOneWidget,
      );
      // The form screen has no table; the dashboard does.
      expect(find.text('1 of 14 · Feb to Apr 2026'), findsNothing);
      await goTo(tester, h, '/manager/reports');
      expect(find.text('1 of 14 · Feb to Apr 2026'), findsOneWidget);
      expect(find.text('3 met'), findsOneWidget);
      expect(find.text('1 point'), findsOneWidget);

      // Sending again replaces it.
      await goTo(tester, h, '/report');
      await tester.tap(find.text('Send report'));
      await tester.pumpAndSettle();
      await goTo(tester, h, '/manager/reports');
      expect(find.text('1 of 14 · Feb to Apr 2026'), findsOneWidget);
      final p = await h.repo.ensurePeriod(MemoryRepository.demoStart);
      expect((await h.repo.watchReports(p.id).first), hasLength(1));
    },
  );

  testWidgets('the table starts empty and lists who is missing', (
    tester,
  ) async {
    await pumpApp(tester, location: '/manager/reports');
    expect(
      find.text(
        'The table appears here as soon as the first report for this period is sent.',
      ),
      findsOneWidget,
    );
    expect(find.text('Still waiting for'), findsOneWidget);
    expect(find.text('Rova · Import'), findsOneWidget);
  });

  testWidgets('with every report in, the table says so', (tester) async {
    await pumpApp(tester, demo: true, location: '/manager/reports');
    expect(find.text('14 of 14 · Feb to Apr 2026'), findsOneWidget);
    expect(find.text('Everyone has sent their report.'), findsOneWidget);
    expect(find.text('Still waiting for'), findsNothing);
    expect(find.text('No counts'), findsNWidgets(2));
  });

  testWidgets('a report from elsewhere shows up live', (tester) async {
    final h = await pumpApp(tester, location: '/manager/reports');
    final p = await h.repo.ensurePeriod(MemoryRepository.demoStart);
    final tmp = MemoryRepository(
      catalog: buildSeedCatalog(),
      currentUser: () => DemoAuth.controller,
      withDemoReports: true,
    );
    final demoPeriod = await tmp.ensurePeriod(MemoryRepository.demoStart);
    final demo = (await tmp.getReport(demoPeriod.id, 'rado'))!;
    final fresh = Report(
      periodId: p.id,
      assignmentId: demo.assignmentId,
      values: demo.values,
      kpis: demo.kpis,
      notes: demo.notes,
      reporter: const Reporter(
        name: 'Rado',
        country: 'Madagascar',
        role: 'Declarant',
      ),
    );
    await h.repo.sendReport(fresh);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('1 of 14 · Feb to Apr 2026'), findsOneWidget);
    expect(find.text('Rado'), findsWidgets);
    await tester.pumpAndSettle();
  });

  testWidgets('a contributor sees only their own seat and no generate button', (
    tester,
  ) async {
    await pumpApp(
      tester,
      demo: true,
      user: const AppUser(
        personId: 'p-tahina',
        role: AppRole.contributor,
        label: 'Tahina',
      ),
    );
    await tester.tap(find.text('Choose your name'));
    await tester.pumpAndSettle();
    // Two seats: a chooser by role title, no names of other people.
    expect(find.text('Reporting for'), findsOneWidget);
    expect(find.text('Declarant export').last, findsOneWidget);
    expect(find.text('BSC creation').last, findsOneWidget);
    expect(find.text('Rova · Import'), findsNothing);
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    expect(find.text('Generate slides'), findsNothing);
    expect(find.text('Reports received'), findsNothing);
  });

  testWidgets('a contributor with one seat gets it preselected', (
    tester,
  ) async {
    await pumpApp(
      tester,
      demo: true,
      user: const AppUser(
        personId: 'p-rova',
        role: AppRole.contributor,
        label: 'Rova',
      ),
    );
    expect(find.text('Your numbers, month by month'), findsOneWidget);
    // One seat: no chooser, the three identity fields start from the profile.
    expect(find.text('Reporting for'), findsNothing);
    String typed(String key) =>
        tester.widget<TextField>(find.byKey(ValueKey(key))).controller!.text;
    expect(typed('reporter-name'), 'Rova');
    expect(typed('reporter-country'), 'Tana');
    expect(typed('reporter-role'), 'Import');
    // Rova already sent: banner and prefilled numbers.
    expect(
      find.textContaining('You already sent this report on'),
      findsOneWidget,
    );
  });

  testWidgets('Edit loads a sent report into the form', (tester) async {
    await pumpApp(tester, demo: true, location: '/manager/reports');
    expect(find.text('Your numbers, month by month'), findsNothing);
    await tester.tap(find.bySemanticsLabel('Edit report of Rova, Import'));
    await tester.pumpAndSettle();
    expect(find.text('Your numbers, month by month'), findsOneWidget);
    expect(
      find.textContaining('You already sent this report on'),
      findsOneWidget,
    );
    final fields = find.byType(NumberField);
    final first = tester.widget<TextField>(
      find.descendant(of: fields.first, matching: find.byType(TextField)),
    );
    expect(first.controller!.text, isNotEmpty);
  });

  testWidgets('controller: confirm before generating a partial deck', (
    tester,
  ) async {
    final h = await pumpApp(tester, location: '/manager/reports');
    // One report in.
    final tmp = MemoryRepository(
      catalog: buildSeedCatalog(),
      currentUser: () => DemoAuth.controller,
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
        reporter: const Reporter(name: 'Rova', country: 'Tana', role: 'Import'),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Not generated yet'), findsOneWidget);
    await tester.tap(find.text('Generate slides'));
    await tester.pumpAndSettle();
    expect(
      find.text(
        '1 of 14 reports are in. Generate the slides with what you have?',
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('Wait'));
    await tester.pumpAndSettle();
    expect(find.textContaining('1 of 14 reports are in'), findsNothing);

    await tester.tap(find.text('Generate slides'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Generate anyway'));
    await tester.pumpAndSettle();
    expect(find.text('Regenerate slides'), findsOneWidget);
    expect(find.text('Slide 1 of 5 · Cover'), findsOneWidget);
    expect(
      find.textContaining(RegExp(r'^Slide 2 of 5 · .* team$')),
      findsOneWidget,
    );
    expect(find.text('Slide 3 of 5 · Rova: KPI and volumes'), findsOneWidget);
    expect(
      find.text('Slide 4 of 5 · Rova: results and next priorities'),
      findsOneWidget,
    );
    expect(find.text('Slide 5 of 5 · Suggestions'), findsOneWidget);
  });

  testWidgets(
    'controller: full deck generates without confirmation and navigates',
    (tester) async {
      await pumpApp(tester, demo: true, location: '/manager/reports');
      await tester.tap(find.text('Generate slides'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Only '), findsNothing);
      expect(find.text('Regenerate slides'), findsOneWidget);
      expect(find.text('Slide 1 of 34 · Cover'), findsOneWidget);
      expect(find.text('1 · Cover'), findsWidgets);
      await tester.tap(find.bySemanticsLabel('Next slide'));
      await tester.pumpAndSettle();
      expect(find.text('2 · Cover'), findsNothing);
      expect(find.textContaining(RegExp(r'^2 · .* team$')), findsWidgets);
      await tester.tap(find.bySemanticsLabel('Previous slide'));
      await tester.pumpAndSettle();
      expect(find.text('1 · Cover'), findsWidgets);
      await tester.tap(find.bySemanticsLabel('Previous slide'));
      await tester.pumpAndSettle();
      // Wraps to the end of the deck (the dropdown shows the slide at the
      // top of the view, so it may read a few slides before the last).
      expect(find.text('1 · Cover'), findsNothing);
      expect(pumpedNav(tester).current.value, greaterThan(15));
    },
  );

  testWidgets('offline sends are saved on the device and sent later', (
    tester,
  ) async {
    final h = await pumpApp(tester);
    await choosePerson(tester, 'Rova · Import');
    await fillRova(tester);
    h.repo.offline = true;
    await tester.tap(find.text('Send report'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(
      find.text(
        'Saved on this device. It will be sent when you are back online.',
      ),
      findsOneWidget,
    );

    h.repo.offline = false;
    await tester.pump(const Duration(seconds: 16));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Sent. The summary is at the top'),
      findsOneWidget,
    );
    await goTo(tester, h, '/manager/reports');
    expect(find.text('1 of 14 · Feb to Apr 2026'), findsOneWidget);
  });

  testWidgets('the draft survives a reload', (tester) async {
    final h = await pumpApp(tester);
    await choosePerson(tester, 'Rova · Import');
    final fields = find.byType(NumberField);
    await tester.enterText(
      find.descendant(of: fields.first, matching: find.byType(TextField)),
      '42',
    );
    await tester.pump();
    final prefs = h.container.read(prefsProvider);
    expect(prefs.getKeys().where((k) => k.startsWith('draft/')), isNotEmpty);

    // Switch person and back: the typed number is restored from the draft.
    await tester.tap(find.text('Rova · Import').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rado · Declarant Ivato (Tana and Abe)').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rado · Declarant Ivato (Tana and Abe)').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rova · Import').last);
    await tester.pumpAndSettle();
    final again = tester.widget<TextField>(
      find.descendant(
        of: find.byType(NumberField).first,
        matching: find.byType(TextField),
      ),
    );
    expect(again.controller!.text, '42');
  });

  testWidgets(
    'name, country and role are text fields prefilled from the seat',
    (tester) async {
      await pumpApp(tester);
      await choosePerson(tester, 'Rova · Import');
      expect(find.text('Reporting for'), findsOneWidget);
      for (final k in ['reporter-name', 'reporter-country', 'reporter-role']) {
        expect(find.byKey(ValueKey(k)), findsOneWidget);
      }
      expect(find.text('0/80'), findsNothing);
      expect(find.text('4/80'), findsNWidgets(2));
      expect(find.text('6/80'), findsOneWidget);
    },
  );

  testWidgets('typed identity is sent and comes back', (tester) async {
    final h = await pumpApp(tester);
    await choosePerson(tester, 'Rova · Import');
    await fillRova(tester);
    await tester.enterText(
      find.byKey(const ValueKey('reporter-name')),
      ' R. B ',
    );
    await tester.enterText(
      find.byKey(const ValueKey('reporter-country')),
      'Madagascar',
    );
    await tester.enterText(
      find.byKey(const ValueKey('reporter-role')),
      'Import lead',
    );
    await tester.pump();
    await tester.tap(find.text('Send report'));
    await tester.pumpAndSettle();
    final p = await h.repo.ensurePeriod(MemoryRepository.demoStart);
    final saved = (await h.repo.getReport(p.id, 'rova'))!;
    expect(
      saved.reporter,
      const Reporter(name: 'R. B', country: 'Madagascar', role: 'Import lead'),
    );
  });

  testWidgets('an empty name, country or role blocks sending in plain words', (
    tester,
  ) async {
    await pumpApp(tester);
    await choosePerson(tester, 'Rova · Import');
    await fillRova(tester);
    await tester.enterText(find.byKey(const ValueKey('reporter-name')), '');
    await tester.enterText(
      find.byKey(const ValueKey('reporter-country')),
      '  ',
    );
    await tester.pump();
    await tester.tap(find.text('Send report'));
    await tester.pumpAndSettle();
    expect(find.text('Enter your name.'), findsWidgets);
    expect(find.text('Enter your country.'), findsWidgets);
    expect(find.text('Enter your role.'), findsNothing);
  });

  testWidgets('the identity is kept in the draft', (tester) async {
    final h = await pumpApp(tester);
    await choosePerson(tester, 'Rova · Import');
    await tester.enterText(
      find.byKey(const ValueKey('reporter-country')),
      'Kenya',
    );
    await tester.pump();
    final prefs = h.container.read(prefsProvider);
    final raw = prefs.getKeys().where((k) => k.startsWith('draft/')).first;
    expect(prefs.getString(raw), contains('Kenya'));
  });
}
