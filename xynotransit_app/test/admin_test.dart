import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xynotransit_app/app/app.dart';
import 'package:xynotransit_app/app/providers.dart';
import 'package:xynotransit_app/core/theme/theme.dart';
import 'package:xynotransit_app/data/memory_repository.dart';
import 'package:xynotransit_app/data/seed_data.dart';
import 'package:xynotransit_app/domain/catalog.dart';
import 'package:xynotransit_app/domain/enums.dart';
import 'package:xynotransit_app/features/admin/people_screen.dart';

import 'helpers.dart';

Catalog emptyCatalog() => Catalog(
  teams: const [],
  persons: const [
    Person(
      id: 'ana',
      fullName: 'Ana',
      email: 'ana@example.com',
      appRole: AppRole.controller,
    ),
  ],
  assignments: const [],
);

class Setup {
  Setup(this.container, this.repo, this.prefs);
  final ProviderContainer container;
  final MemoryRepository repo;
  final SharedPreferences prefs;
}

Future<Setup> pumpPeople(
  WidgetTester tester, {
  Catalog? catalog,
  Size size = const Size(1200, 3000),
  double textScale = 1,
}) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final cat = catalog ?? emptyCatalog();
  final auth = DemoAuth(cat);
  final repo = MemoryRepository(
    catalog: cat,
    currentUser: () => DemoAuth.controller,
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
      child: MaterialApp(
        theme: buildTheme(Brightness.light),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: const PeopleScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return Setup(container, repo, prefs);
}

Future<void> tapText(WidgetTester tester, String text, {int? at}) async {
  var f = find.text(text);
  f = at == null ? f.last : f.at(at);
  await tester.ensureVisible(f);
  await tester.tap(f, warnIfMissed: false);
  await tester.pumpAndSettle();
}

Future<void> typeKey(WidgetTester tester, String key, String text) async {
  final f = find.byKey(Key(key));
  await tester.ensureVisible(f);
  await tester.enterText(f, text);
  await tester.pump();
}

Future<void> closeDialog(WidgetTester tester) async {
  await tester.tap(find.byTooltip('Close').last);
  await tester.pumpAndSettle();
}

Future<void> addTeam(WidgetTester tester, String name) async {
  await typeKey(tester, 'new-team', name);
  await tapText(tester, 'Add a team');
}

/// Adds a person with one seat and the given counts and targets, by hand.
Future<void> addPersonWithSeat(
  WidgetTester tester, {
  required String name,
  required String email,
  required String team,
  required String title,
  required List<String> counts,
  required List<String> targets,
}) async {
  await tapText(tester, 'Add a person');
  await typeKey(tester, 'person-name', name);
  await typeKey(tester, 'person-email', email);
  await tapText(tester, 'Add person');
  expect(find.text('Saved.'), findsOneWidget);
  await tester.tap(find.byKey(const Key('seat-team')));
  await tester.pumpAndSettle();
  await tester.tap(find.text(team).last);
  await tester.pumpAndSettle();
  await typeKey(tester, 'seat-title', title);
  await tapText(tester, 'Add a seat');
  expect(find.text('Seat added. Now say what they count.'), findsOneWidget);
  await tapText(tester, 'What they count');
  for (var i = 0; i < counts.length; i++) {
    await tapText(tester, 'Add a count');
    await typeKey(tester, 'count-field-$i', counts[i]);
  }
  for (var i = 0; i < targets.length; i++) {
    await tapText(tester, 'Add a target');
    await typeKey(tester, 'target-field-$i', targets[i]);
  }
  await tapText(tester, 'Save');
  expect(find.text('Saved.'), findsWidgets);
  await closeDialog(tester);
  await closeDialog(tester);
}

Future<Assignment> seatOf(Setup s, String title) async =>
    (await s.repo.loadCatalog(includeInactive: true)).assignments
        .firstWhere((a) => a.roleTitle == title);

void main() {
  setUpAll(loadAppFonts);

  testWidgets('starts empty and adds a team', (tester) async {
    await pumpPeople(tester);
    expect(find.text('People and what they report'), findsOneWidget);
    expect(find.text('No team yet.'), findsOneWidget);
    await addTeam(tester, 'Operations');
    expect(find.text('Team added.'), findsOneWidget);
    expect(find.textContaining('Operations  (0 seats)'), findsOneWidget);
    await addTeam(tester, '');
    expect(find.text('Type a name for the team.'), findsOneWidget);
  });

  testWidgets('rename and delete a team', (tester) async {
    await pumpPeople(tester);
    await addTeam(tester, 'Ops');
    await tapText(tester, 'Rename');
    await typeKey(tester, 'rename-team', 'Operations');
    await tapText(tester, 'Save name');
    expect(find.text('Team renamed.'), findsOneWidget);
    expect(find.textContaining('Operations  (0 seats)'), findsOneWidget);
    await tapText(tester, 'Delete');
    expect(find.text('Delete Operations?'), findsOneWidget);
    await tapText(tester, 'Keep team');
    expect(find.text('Team deleted.'), findsNothing);
    await tapText(tester, 'Delete');
    await tapText(tester, 'Delete team');
    expect(find.text('Team deleted.'), findsOneWidget);
    expect(find.text('No team yet.'), findsOneWidget);
  });

  testWidgets('a team with seats cannot be deleted', (tester) async {
    await pumpPeople(tester);
    await addTeam(tester, 'Operations');
    await addPersonWithSeat(
      tester,
      name: 'Bob',
      email: 'bob@example.com',
      team: 'Operations',
      title: 'Clerk',
      counts: ['Sea'],
      targets: [],
    );
    await tapText(tester, 'Delete');
    expect(
      find.text('Move or remove the seats of this team first.'),
      findsOneWidget,
    );
  });

  testWidgets('person with a seat, 5 counts and 2 targets, then the form', (
    tester,
  ) async {
    final s = await pumpPeople(tester);
    await addTeam(tester, 'Operations');
    await addPersonWithSeat(
      tester,
      name: 'Bob',
      email: 'Bob@Example.com',
      team: 'Operations',
      title: 'Clerk',
      counts: ['Sea', 'Air', 'Road', 'Rail', 'Post'],
      targets: ['Answer every call', 'Close files in 2 days'],
    );
    expect(find.text('Bob'), findsOneWidget);
    expect(find.textContaining('Clerk · 5 counts, 2 targets'), findsOneWidget);
    final a = await seatOf(s, 'Clerk');
    expect(
      [for (final m in a.metrics) m.label],
      ['Sea', 'Air', 'Road', 'Rail', 'Post'],
    );
    expect(
      [for (final k in a.kpis) k.text],
      ['Answer every call', 'Close files in 2 days'],
    );

    // The employee form shows exactly these counts.
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: s.container,
        child: const XynotransitApp(),
      ),
    );
    await tester.pump();
    s.container.read(routerProvider).go('/report');
    await tester.pumpAndSettle();
    // With a single seat the form picks it by itself.
    if (find.text('Choose your name').evaluate().isNotEmpty) {
      await tester.tap(find.text('Choose your name'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Bob · Clerk').last);
      await tester.pumpAndSettle();
    }
    for (final l in ['Sea', 'Air', 'Road', 'Rail', 'Post']) {
      expect(find.text(l), findsWidgets, reason: l);
    }
    expect(find.text('Answer every call'), findsWidgets);
    expect(find.text('Close files in 2 days'), findsWidgets);
  });

  testWidgets('one count only: Sea alone', (tester) async {
    final s = await pumpPeople(tester);
    await addTeam(tester, 'Operations');
    await addPersonWithSeat(
      tester,
      name: 'Cleo',
      email: 'cleo@example.com',
      team: 'Operations',
      title: 'Dock',
      counts: ['Sea'],
      targets: [],
    );
    expect(find.textContaining('Dock · 1 count, 0 targets'), findsOneWidget);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: s.container,
        child: const XynotransitApp(),
      ),
    );
    await tester.pump();
    s.container.read(routerProvider).go('/report');
    await tester.pumpAndSettle();
    // With a single seat the form picks it by itself.
    if (find.text('Choose your name').evaluate().isNotEmpty) {
      await tester.tap(find.text('Choose your name'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cleo · Dock').last);
      await tester.pumpAndSettle();
    }
    expect(find.text('Sea'), findsWidgets);
    expect(find.text('Air'), findsNothing);
  });

  testWidgets('reorder and remove counts, with the calm sentence', (
    tester,
  ) async {
    final s = await pumpPeople(tester);
    await addTeam(tester, 'Operations');
    await addPersonWithSeat(
      tester,
      name: 'Bob',
      email: 'bob@example.com',
      team: 'Operations',
      title: 'Clerk',
      counts: ['Sea', 'Air', 'Road'],
      targets: ['One'],
    );
    Future<String> labels() async =>
        (await seatOf(s, 'Clerk')).metrics.map((m) => m.label).join(',');
    final ids = (await seatOf(s, 'Clerk')).metrics.map((m) => m.id).toList();
    await tapText(tester, 'What they count');
    expect(
      find.textContaining('Old reports keep what they were answered against.'),
      findsNothing,
    );
    await tester.tap(find.byKey(const Key('count-up-2')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('count-down-0')));
    await tester.pumpAndSettle();
    // Sea, Air, Road -> Sea, Road, Air -> Road, Sea, Air
    await tapText(tester, 'Save');
    expect(await labels(), 'Road,Sea,Air');
    final now = (await seatOf(s, 'Clerk')).metrics;
    expect({for (final m in now) m.id}, ids.toSet());

    await tester.tap(find.byKey(const Key('count-remove-1')));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Old reports keep what they were answered against.'),
      findsOneWidget,
    );
    await tapText(tester, 'Save');
    expect(await labels(), 'Road,Air');
    expect(find.text('Saved.'), findsOneWidget);
  });

  testWidgets('live validation before saving', (tester) async {
    final s = await pumpPeople(tester);
    await addTeam(tester, 'Operations');
    await addPersonWithSeat(
      tester,
      name: 'Bob',
      email: 'bob@example.com',
      team: 'Operations',
      title: 'Clerk',
      counts: ['Sea'],
      targets: [],
    );
    await tapText(tester, 'What they count');
    await tapText(tester, 'Add a count');
    await typeKey(tester, 'count-field-1', 'sea ');
    expect(find.text('Another count already has this name.'), findsNWidgets(2));
    await typeKey(tester, 'count-field-1', 'x' * 61);
    expect(find.text('Use 60 characters or fewer.'), findsOneWidget);
    await typeKey(tester, 'count-field-1', '');
    await tapText(tester, 'Save');
    expect(find.text('Give this count a name.'), findsOneWidget);
    expect(
      find.text('Fix the lines marked in red, then save.'),
      findsOneWidget,
    );
    expect((await seatOf(s, 'Clerk')).metrics, hasLength(1));
    await tapText(tester, 'Add a target');
    await typeKey(tester, 'target-field-0', 'y' * 201);
    expect(find.text('Use 200 characters or fewer.'), findsOneWidget);
  });

  testWidgets('limits: 8 counts shown with the message', (tester) async {
    await pumpPeople(tester);
    await addTeam(tester, 'Operations');
    await addPersonWithSeat(
      tester,
      name: 'Bob',
      email: 'bob@example.com',
      team: 'Operations',
      title: 'Clerk',
      counts: List.generate(8, (i) => 'C$i'),
      targets: [],
    );
    await tapText(tester, 'What they count');
    expect(find.text('A seat can have 8 counts at most.'), findsOneWidget);
    final add = find.widgetWithText(FilledButton, 'Add a count');
    expect(tester.widget<FilledButton>(add).onPressed, isNull);
  });

  testWidgets('duplicate email and last manager messages', (tester) async {
    await pumpPeople(tester);
    await tapText(tester, 'Add a person');
    await typeKey(tester, 'person-name', 'Other');
    await typeKey(tester, 'person-email', ' ANA@example.com ');
    await tapText(tester, 'Add person');
    expect(find.text('That email is already used.'), findsOneWidget);
    await closeDialog(tester);

    await tapText(tester, 'Edit person');
    await tester.tap(find.byKey(const Key('person-active')));
    await tester.pumpAndSettle();
    expect(find.textContaining('cannot sign in'), findsOneWidget);
    await tapText(tester, 'Save person');
    expect(find.text('There must be at least one manager.'), findsOneWidget);
    await tester.tap(find.byKey(const Key('person-active')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Employee'));
    await tester.pumpAndSettle();
    await tapText(tester, 'Save person');
    expect(find.text('There must be at least one manager.'), findsOneWidget);
  });

  testWidgets('inactive people are dimmed, labelled and can be shown', (
    tester,
  ) async {
    final s = await pumpPeople(tester);
    await addTeam(tester, 'Operations');
    await addPersonWithSeat(
      tester,
      name: 'Bob',
      email: 'bob@example.com',
      team: 'Operations',
      title: 'Clerk',
      counts: ['Sea'],
      targets: [],
    );
    await tapText(tester, 'Edit person', at: 0);
    // Ana has no seat so her line is under "People without a seat"; pick Bob.
    await closeDialog(tester);
    await tester.tap(find.bySemanticsLabel('Edit Bob'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('person-active')));
    await tester.pumpAndSettle();
    await tapText(tester, 'Save person');
    expect(find.text('Saved.'), findsOneWidget);
    await closeDialog(tester);
    expect(find.text('Bob'), findsNothing);
    await tester.tap(find.byKey(const Key('show-inactive')));
    await tester.pumpAndSettle();
    expect(find.text('Bob'), findsOneWidget);
    expect(find.text('Inactive'), findsOneWidget);
    expect(
      (await s.repo.loadCatalog(includeInactive: true)).persons
          .firstWhere((p) => p.fullName == 'Bob')
          .active,
      isFalse,
    );
  });

  group('no overflow', () {
    Future<void> reveal(WidgetTester tester, Finder f, {bool dialog = false}) {
      final scrollable = dialog
          ? find
                .descendant(
                  of: find.byType(SingleChildScrollView).last,
                  matching: find.byType(Scrollable),
                )
                .first
          : find
                .descendant(
                  of: find.byType(ListView),
                  matching: find.byType(Scrollable),
                )
                .first;
      return tester.scrollUntilVisible(f, 200, scrollable: scrollable);
    }

    for (final size in const [
      Size(360, 800),
      Size(800, 1100),
      Size(1500, 900),
    ]) {
      for (final scale in const [1.0, 2.0]) {
        testWidgets('${size.width.toInt()}x${size.height.toInt()} at $scale', (
          tester,
        ) async {
          await pumpPeople(
            tester,
            catalog: buildSeedCatalog(),
            size: size,
            textScale: scale,
          );
          expect(tester.takeException(), isNull);
          // The page, scrolled to the end.
          await tester.drag(find.byType(ListView), const Offset(0, -20000));
          await tester.pumpAndSettle();
          await tester.drag(find.byType(ListView), const Offset(0, 20000));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);

          final add = find.text('Add a person');
          await reveal(tester, add);
          await tester.tap(add);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          await closeDialog(tester);

          final edit = find.text('Edit person').first;
          await reveal(tester, edit);
          await tester.ensureVisible(edit);
          await tester.pumpAndSettle();
          await tester.tap(edit);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          final seatBtn = find.text('What they count').last;
          await reveal(tester, seatBtn, dialog: true);
          await tester.tap(seatBtn);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);

          for (var i = 0; i < 3; i++) {
            final addCount = find.text('Add a count').last;
            await reveal(tester, addCount, dialog: true);
            if (tester
                    .widget<FilledButton>(
                      find.widgetWithText(FilledButton, 'Add a count').last,
                    )
                    .onPressed ==
                null) {
              break;
            }
            await tester.tap(addCount);
            await tester.pumpAndSettle();
          }
          final last = find.byKey(const Key('count-field-0'));
          await reveal(tester, last, dialog: true);
          await tester.enterText(last, 'A long count name ' * 3);
          final addTarget = find.text('Add a target').last;
          await reveal(tester, addTarget, dialog: true);
          await tester.tap(addTarget);
          await tester.pumpAndSettle();
          final t0 = find.byKey(const Key('target-field-0'));
          await reveal(tester, t0, dialog: true);
          await tester.enterText(t0, 'A long target text ' * 12);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        });
      }
    }
  });
}
