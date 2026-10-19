import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xynotransit_app/app/app.dart';
import 'package:xynotransit_app/core/widgets.dart';
import 'package:xynotransit_app/data/memory_repository.dart';
import 'package:xynotransit_app/data/repository.dart';
import 'package:xynotransit_app/domain/enums.dart';

import 'app_test.dart' show Harness, pumpApp;
import 'helpers.dart';

const rova = AppUser(
  personId: 'p-rova',
  role: AppRole.contributor,
  label: 'Rova',
);
const tahina = AppUser(
  personId: 'p-tahina',
  role: AppRole.contributor,
  label: 'Tahina',
);

String where(Harness h) => h.container
    .read(routerProvider)
    .routerDelegate
    .currentConfiguration
    .last
    .matchedLocation;

Future<void> go(WidgetTester tester, Harness h, String path) async {
  h.container.read(routerProvider).go(path);
  await tester.pumpAndSettle();
}

Future<void> tapEditRova(WidgetTester tester) async {
  await tester.tap(find.bySemanticsLabel('Edit report of Rova, Import'));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(loadAppFonts);

  group('redirects', () {
    testWidgets('/ sends a controller to the overview', (tester) async {
      final h = await pumpApp(tester, demo: true, location: '/');
      expect(where(h), '/manager');
      expect(find.text('Overview'), findsWidgets);
      expect(find.text('Report dashboard'), findsNothing);
    });

    testWidgets('/ sends a contributor to the form', (tester) async {
      final h = await pumpApp(tester, demo: true, user: rova, location: '/');
      expect(where(h), '/report');
      expect(find.text('Logistics Report Builder'), findsOneWidget);
    });

    testWidgets('/signin goes home too', (tester) async {
      final h = await pumpApp(tester, demo: true, location: '/signin');
      expect(where(h), '/manager');
    });

    testWidgets('a contributor opening any manager page lands on /report', (
      tester,
    ) async {
      final h = await pumpApp(tester, demo: true, user: rova, location: '/');
      for (final path in [
        '/manager',
        '/manager/reports',
        '/manager/people',
        '/manager/deck',
        '/manager/nothing',
      ]) {
        await go(tester, h, path);
        expect(where(h), '/report', reason: path);
      }
      expect(find.text('Report dashboard'), findsNothing);
      expect(find.text('Reports received'), findsNothing);
      expect(find.text('Overview'), findsNothing);
    });

    testWidgets('a controller may open /report', (tester) async {
      final h = await pumpApp(tester, demo: true, location: '/report');
      expect(where(h), '/report');
    });

    testWidgets('switching the demo user to a contributor leaves /manager', (
      tester,
    ) async {
      final h = await pumpApp(tester, demo: true, location: '/manager');
      expect(where(h), '/manager');
      h.auth.actAs(rova);
      await tester.pumpAndSettle();
      expect(where(h), '/report');
      expect(find.text('Reports received'), findsNothing);
    });

    testWidgets('switching the demo user back to the controller stays put', (
      tester,
    ) async {
      final h = await pumpApp(tester, demo: true, user: rova, location: '/');
      h.auth.actAs(DemoAuth.controller);
      await tester.pumpAndSettle();
      // Nothing forces a controller away from the form.
      expect(where(h), '/report');
      await go(tester, h, '/manager');
      expect(where(h), '/manager');
    });
  });

  group('employee screen', () {
    testWidgets('has the form and nothing of the dashboard', (tester) async {
      await pumpApp(tester, demo: true, user: rova, location: '/');
      expect(find.text('Logistics Report Builder'), findsOneWidget);
      expect(find.text('Period and person'), findsOneWidget);
      expect(find.text('Your numbers, month by month'), findsOneWidget);
      expect(find.text('Send report'), findsOneWidget);
      for (final t in [
        'Reports received',
        'Slide preview',
        'Generate slides',
        'Regenerate slides',
        'Export',
        'Report dashboard',
      ]) {
        expect(find.text(t), findsNothing, reason: t);
      }
      expect(find.textContaining('Export'), findsNothing);
      expect(find.textContaining('Generate'), findsNothing);
    });

    testWidgets('shows no back link or top bar link to a contributor', (
      tester,
    ) async {
      await pumpApp(tester, demo: true, user: rova, location: '/');
      expect(find.text('‹ Back to the dashboard'), findsNothing);
      expect(find.text('Overview'), findsNothing);
      expect(find.text('Reports'), findsNothing);
      expect(find.text('People'), findsNothing);
      expect(find.text('Fill in a report'), findsNothing);
    });
  });

  group('manager screen', () {
    testWidgets('has period, table and slides but not the form', (
      tester,
    ) async {
      await pumpApp(tester, demo: true, location: '/manager/reports');
      expect(find.text('Report dashboard'), findsOneWidget);
      expect(find.text('Period'), findsOneWidget);
      expect(find.text('First month of the three'), findsOneWidget);
      expect(find.text('Reports received'), findsOneWidget);
      expect(find.text('14 of 14 · Feb to Apr 2026'), findsOneWidget);
      expect(find.text('Slide preview'), findsOneWidget);
      expect(find.text('Generate slides'), findsOneWidget);
      await tester.tap(find.text('Generate slides'));
      await tester.pumpAndSettle();
      expect(find.text('Export'), findsOneWidget);
      for (final t in [
        'Your numbers, month by month',
        'Period and person',
        'Choose your name',
        'Send report',
        'Logistics Report Builder',
      ]) {
        expect(find.text(t), findsNothing, reason: t);
      }
      expect(find.byType(NumberField), findsNothing);
    });

    testWidgets('changing the period updates the table', (tester) async {
      await pumpApp(tester, demo: true, location: '/manager/reports');
      expect(find.text('14 of 14 · Feb to Apr 2026'), findsOneWidget);
      expect(find.text('Showing Feb to Apr 2026.'), findsOneWidget);
      await tester.tap(find.text('February'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('March').last);
      await tester.pumpAndSettle();
      expect(find.text('14 of 14 · Feb to Apr 2026'), findsNothing);
      expect(find.text('Showing Mar to May 2026.'), findsOneWidget);
      expect(find.text('0 of 14 · Mar to May 2026'), findsOneWidget);
      expect(find.text('Still waiting for'), findsOneWidget);
    });

    testWidgets('changing the year updates the table', (tester) async {
      await pumpApp(tester, demo: true, location: '/manager/reports');
      await tester.enterText(find.widgetWithText(TextField, '2026'), '2027');
      await tester.pumpAndSettle();
      expect(find.text('14 of 14 · Feb to Apr 2026'), findsNothing);
      expect(find.text('Showing Feb to Apr 2027.'), findsOneWidget);
    });
  });

  group('edit and back', () {
    testWidgets('Edit opens /report with the person and values filled', (
      tester,
    ) async {
      final h = await pumpApp(tester, demo: true, location: '/manager/reports');
      await tapEditRova(tester);
      expect(where(h), '/report');
      expect(find.text('‹ Back to the dashboard'), findsOneWidget);
      expect(find.text('Your numbers, month by month'), findsOneWidget);
      expect(find.text('Rova · Import'), findsWidgets);
      expect(find.text('Choose your name'), findsNothing);
      expect(
        find.textContaining('You already sent this report on'),
        findsOneWidget,
      );
      final fields = find.byType(NumberField);
      expect(fields, findsNWidgets(6));
      for (var i = 0; i < 6; i++) {
        final tf = tester.widget<TextField>(
          find.descendant(of: fields.at(i), matching: find.byType(TextField)),
        );
        expect(tf.controller!.text, isNotEmpty, reason: 'field $i');
      }
      // Still no dashboard pieces on the form.
      expect(find.text('Reports received'), findsNothing);
      expect(find.text('Slide preview'), findsNothing);
    });

    testWidgets('the Back link returns to the dashboard', (tester) async {
      final h = await pumpApp(tester, demo: true, location: '/manager/reports');
      await tapEditRova(tester);
      await tester.tap(find.text('‹ Back to the dashboard'));
      await tester.pumpAndSettle();
      expect(where(h), '/manager/reports');
      expect(find.text('Reports received'), findsOneWidget);
      expect(find.text('‹ Back to the dashboard'), findsNothing);
      expect(find.text('Your numbers, month by month'), findsNothing);
    });

    testWidgets('a contributor never sees the Back link', (tester) async {
      await pumpApp(tester, demo: true, user: rova, location: '/');
      expect(find.text('‹ Back to the dashboard'), findsNothing);
    });
  });

  group('top bar links', () {
    testWidgets('a manager moves between the five sections', (tester) async {
      final h = await pumpApp(tester, demo: true, location: '/');
      expect(where(h), '/manager');
      for (final (label, path) in [
        ('Reports', '/manager/reports'),
        ('Deck text', '/manager/deck'),
        ('People', '/manager/people'),
        ('Fill in a report', '/report'),
        ('Overview', '/manager'),
      ]) {
        await tester.tap(find.text(label));
        await tester.pumpAndSettle();
        expect(where(h), path, reason: label);
      }
    });

    testWidgets('the current section is marked', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpApp(tester, demo: true, location: '/manager/reports');
      expect(find.bySemanticsLabel('Reports, current section'), findsOneWidget);
      expect(find.bySemanticsLabel('Overview'), findsOneWidget);
      expect(find.bySemanticsLabel('Overview, current section'), findsNothing);
      handle.dispose();
    });

    testWidgets('a narrow screen folds the sections into the menu', (
      tester,
    ) async {
      final h = await pumpApp(
        tester,
        demo: true,
        size: const Size(400, 900),
        location: '/manager',
      );
      expect(find.text('Reports'), findsNothing);
      await tester.tap(find.byTooltip('Menu'));
      await tester.pumpAndSettle();
      for (final t in [
        'Overview',
        'Reports',
        'Deck text',
        'People',
        'Fill in a report',
      ]) {
        expect(find.text(t), findsWidgets, reason: t);
      }
      await tester.tap(find.text('Reports').last);
      await tester.pumpAndSettle();
      expect(where(h), '/manager/reports');
    });

    testWidgets('a contributor has no section links', (tester) async {
      await pumpApp(tester, demo: true, user: tahina, location: '/');
      for (final t in [
        'Overview',
        'Reports',
        'Deck text',
        'People',
        'Fill in a report',
      ]) {
        expect(find.text(t), findsNothing, reason: t);
      }
    });
  });
}
