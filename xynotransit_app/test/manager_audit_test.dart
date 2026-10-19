import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xynotransit_app/domain/catalog.dart';
import 'package:xynotransit_app/core/theme/theme.dart';
import 'package:xynotransit_app/domain/enums.dart';
import 'package:xynotransit_app/domain/summary.dart';
import 'package:xynotransit_app/features/summary/people_table.dart';

import 'admin_test.dart' show emptyCatalog, pumpPeople;
import 'app_test.dart' show pumpApp;
import 'helpers.dart';
import 'summary_test.dart' show pumpOverview, tileValue;

Catalog bigCatalog(int people) {
  final teams = [
    for (var i = 0; i < 6; i++)
      Team(id: 't$i', code: 't$i', name: 'Team $i', sort: i),
  ];
  return Catalog(
    teams: teams,
    persons: [
      const Person(
        id: 'ana',
        fullName: 'Ana',
        email: 'ana@example.com',
        appRole: AppRole.controller,
      ),
      for (var i = 0; i < people; i++)
        Person(
          id: 'p$i',
          fullName: 'Person ${i.toString().padLeft(3, '0')}',
          email: 'p$i@example.com',
          active: i % 10 != 0,
        ),
    ],
    assignments: [
      for (var i = 0; i < people; i++)
        Assignment(
          id: 'a$i',
          code: 'a$i',
          personId: 'p$i',
          teamId: 't${i % 6}',
          roleTitle: 'Clerk $i',
          sort: i,
          metrics: const [],
          kpis: const [],
        ),
    ],
  );
}

void main() {
  setUpAll(loadAppFonts);

  group('a seat is expected only when seat and person are active', () {
    test('Catalog.expectedCount', () {
      final c = bigCatalog(20);
      // Every tenth person is inactive: 0 and 10.
      expect(c.assignments.length, 20);
      expect(c.expectedCount, 18);
      final unknown = Catalog(
        teams: c.teams,
        persons: const [],
        assignments: c.assignments.take(3).toList(),
      );
      expect(unknown.expectedCount, 0);
    });

    testWidgets('the Reports table counts the same way as the tiles', (
      tester,
    ) async {
      final h = await pumpApp(tester, location: '/manager/reports');
      expect(find.textContaining('0 of 14 ·'), findsOneWidget);
      await h.repo.savePerson(
        id: 'p-rova',
        fullName: 'Rova',
        email: 'rova@xynotransit.example',
        role: AppRole.contributor,
        active: false,
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('0 of 13 ·'), findsOneWidget);
    });
  });

  group('chart accuracy: every plotted number is a number of the Summary', () {
    testWidgets('volume bars and trend lines', (tester) async {
      final c = await pumpOverview(tester);
      final s = c.summary;

      final bar = tester.widget<BarChart>(find.byType(BarChart));
      final groups = bar.data.barGroups;
      expect(groups.length, s.months.length);
      for (var m = 0; m < groups.length; m++) {
        final stack = groups[m].barRods.single.rodStackItems;
        final expected = [
          for (final t in s.teams)
            if (t.volumeByMonth[m] > 0) t.volumeByMonth[m],
        ];
        expect([for (final i in stack) (i.toY - i.fromY).round()], expected);
        expect(
          groups[m].barRods.single.toY.round(),
          expected.fold<int>(0, (a, b) => a + b),
        );
      }

      final line = tester.widget<LineChart>(find.byType(LineChart));
      final sent = line.data.lineBarsData[0].spots;
      final met = line.data.lineBarsData[1].spots;
      expect(sent.length, s.trend.length);
      for (var i = 0; i < sent.length; i++) {
        expect(sent[i].y, closeTo(s.trend[i].submissionRate * 100, 1e-9));
      }
      final answered = [
        for (var i = 0; i < s.trend.length; i++)
          if (s.trend[i].answered > 0) i,
      ];
      expect(met.length, answered.length);
      for (var k = 0; k < met.length; k++) {
        expect(met[k].x.round(), answered[k]);
        expect(met[k].y, closeTo(s.trend[answered[k]].metRate * 100, 1e-9));
      }
    });

    testWidgets('the tiles and the biggest counts add up', (tester) async {
      final c = await pumpOverview(tester);
      final s = c.summary;
      expect(tileValue(tester, 'reports'), '${s.submitted} of ${s.expected}');
      final volume = s.teams.fold<int>(
        0,
        (a, t) => a + t.volumeByMonth.fold<int>(0, (x, y) => x + y),
      );
      expect(
        tileValue(tester, 'volume').replaceAll(',', ''),
        volume.toString(),
      );
      // The biggest counts are listed from the largest down.
      final totals = [for (final m in s.metrics.take(8)) m.total];
      expect(totals, [...totals]..sort((a, b) => b.compareTo(a)));
    });
  });

  group('Overview', () {
    testWidgets('who is missing comes right after the tiles', (tester) async {
      final c = await pumpOverview(tester, demo: false);
      final card = find.byKey(const ValueKey('missing-card'));
      expect(card, findsOneWidget);
      expect(
        find.textContaining('${c.summary.expected} reports are still missing'),
        findsOneWidget,
      );
      final tiles = tester.getBottomLeft(
        find.byKey(const ValueKey('tile-missing')),
      );
      final charts = tester.getTopLeft(find.text('Who has reported'));
      expect(tester.getTopLeft(card).dy, greaterThan(tiles.dy));
      expect(tester.getTopLeft(card).dy, lessThan(charts.dy));
    });

    testWidgets('no missing card when everyone has sent', (tester) async {
      await pumpOverview(tester);
      expect(find.byKey(const ValueKey('missing-card')), findsNothing);
    });

    testWidgets('the people table can be searched and filtered', (
      tester,
    ) async {
      await pumpOverview(tester, demo: false);
      expect(find.byKey(const ValueKey('people-table')), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('people-search')),
        'rova',
      );
      await tester.pumpAndSettle();
      expect(
        find.textContaining('person-row-', skipOffstage: false),
        findsNothing,
      );
      expect(
        find.byWidgetPredicate(
          (w) =>
              w.key is ValueKey<String> &&
              (w.key! as ValueKey<String>).value.startsWith('person-row-'),
        ),
        findsOneWidget,
      );
      await tester.enterText(
        find.byKey(const ValueKey('people-search')),
        'zzzz',
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('No one matches'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('people-search')), '');
      await tester.tap(find.byKey(const ValueKey('people-missing-only')));
      await tester.pumpAndSettle();
      final table = find.byKey(const ValueKey('people-table'));
      expect(
        find.descendant(of: table, matching: find.text('Missing')),
        findsWidgets,
      );
      expect(
        find.descendant(of: table, matching: find.text('Sent')),
        findsNothing,
      );
    });
  });

  testWidgets(
    'the Overview people table shows 100 rows, then more on request',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 60000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final people = [
        for (var i = 0; i < 300; i++)
          PersonSummary(
            assignmentId: 'a$i',
            name: 'Person $i',
            role: 'Clerk',
            team: 'Team ${i % 6}',
            submitted: i.isEven,
            met: 1,
            partly: 0,
            missed: 0,
            volumeTotal: i,
          ),
      ];
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(Brightness.light),
          home: Scaffold(
            body: SingleChildScrollView(child: PeopleTableCard(people: people)),
          ),
        ),
      );
      int rows() => find
          .byWidgetPredicate(
            (w) =>
                w.key is ValueKey<String> &&
                (w.key! as ValueKey<String>).value.startsWith('person-row-'),
          )
          .evaluate()
          .length;
      expect(rows(), 100);
      await tester.tap(find.byKey(const ValueKey('people-show-more')));
      await tester.pumpAndSettle();
      expect(rows(), 200);
      await tester.tap(find.byKey(const ValueKey('people-missing-only')));
      await tester.pumpAndSettle();
      expect(rows(), 100);
      await tester.tap(find.byKey(const ValueKey('people-show-more')));
      await tester.pumpAndSettle();
      expect(rows(), 150);
      expect(find.byKey(const ValueKey('people-show-more')), findsNothing);
    },
  );

  group('Reports table', () {
    testWidgets('search narrows the rows', (tester) async {
      await pumpApp(tester, demo: true, location: '/manager/reports');
      expect(find.text('Rova'), findsOneWidget);
      expect(find.text('Rado'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('reports-search')),
        'rova',
      );
      await tester.pumpAndSettle();
      expect(find.text('Rova'), findsOneWidget);
      expect(find.text('Rado'), findsNothing);
      await tester.enterText(
        find.byKey(const ValueKey('reports-search')),
        'nobody',
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('No report matches'), findsOneWidget);
    });

    testWidgets('on a phone every column stays on screen', (tester) async {
      await pumpApp(
        tester,
        demo: true,
        size: const Size(390, 4000),
        location: '/manager/reports',
      );
      expect(tester.takeException(), isNull);
      final met = find.textContaining(' met').first;
      expect(tester.getTopLeft(met).dx, lessThan(390));
      expect(find.byType(SingleChildScrollView), findsNothing);
    });
  });

  group('People at scale', () {
    testWidgets('300 people build lazily and can be searched', (tester) async {
      await pumpPeople(
        tester,
        catalog: bigCatalog(300),
        size: const Size(1200, 900),
      );
      // Only what is near the screen exists.
      expect(find.text('Edit person').evaluate().length, lessThan(40));
      await tester.enterText(
        find.byKey(const Key('people-search')),
        'Person 251',
      );
      await tester.pumpAndSettle();
      expect(find.text('Person 251'), findsOneWidget);
      expect(find.text('Person 250'), findsNothing);
      await tester.enterText(find.byKey(const Key('people-search')), 'nobody');
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.textContaining('No one matches'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.textContaining('No one matches'), findsOneWidget);
    });

    testWidgets('team filter and inactive people', (tester) async {
      await pumpPeople(
        tester,
        catalog: bigCatalog(60),
        size: const Size(1200, 4000),
      );
      await tester.tap(find.byKey(const Key('people-team-filter')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Team 1').last);
      await tester.pumpAndSettle();
      expect(find.text('Team 0'), findsNothing);
      expect(find.text('Person 001'), findsOneWidget);
      // Person 010 and 040 are inactive and sit in Team 4 and Team 4.
      await tester.tap(find.byKey(const Key('people-team-filter')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Team 4').last);
      await tester.pumpAndSettle();
      expect(find.text('Person 010'), findsNothing);
      await tester.tap(find.byKey(const Key('show-inactive')));
      await tester.pumpAndSettle();
      expect(find.text('Person 010'), findsOneWidget);
      expect(find.text('Inactive'), findsWidgets);
    });

    testWidgets('an empty catalog still explains itself', (tester) async {
      await pumpPeople(tester, catalog: emptyCatalog());
      expect(find.textContaining('No team yet'), findsOneWidget);
    });
  });

  testWidgets('the demo switcher has a name for screen readers', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await pumpApp(tester, location: '/manager');
    expect(find.bySemanticsLabel('Demo: act as someone else'), findsWidgets);
    handle.dispose();
  });
}
