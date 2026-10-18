import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xynotransit_app/app/app.dart';
import 'package:xynotransit_app/app/providers.dart';
import 'package:xynotransit_app/data/memory_repository.dart';
import 'package:xynotransit_app/data/seed_data.dart';
import 'package:xynotransit_app/domain/enums.dart';
import 'package:xynotransit_app/domain/report.dart';
import 'package:xynotransit_app/domain/summary.dart';
import 'package:xynotransit_app/features/summary/summary_provider.dart';
import 'package:xynotransit_app/features/summary/summary_widgets.dart';

import 'helpers.dart';

class Ctx {
  Ctx(this.repo, this.container, this.summary);
  final MemoryRepository repo;
  final ProviderContainer container;
  final Summary summary;
}

Future<Ctx> pumpOverview(
  WidgetTester tester, {
  Size size = const Size(1500, 5200),
  double textScale = 1,
  Brightness brightness = Brightness.light,
  bool demo = true,
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
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  tester.platformDispatcher.platformBrightnessTestValue = brightness;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearAllTestValues);
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
  final period = await container.read(periodProvider.future);
  final summary = await repo.loadSummary(period.id);
  return Ctx(repo, container, summary);
}

String tileValue(WidgetTester tester, String id) {
  final texts = find.descendant(
    of: find.byKey(ValueKey('tile-$id')),
    matching: find.byType(Text),
  );
  return (tester.widget<Text>(texts.at(1))).data!;
}

Finder semanticsStarting(String start) =>
    find.bySemanticsLabel(RegExp('^${RegExp.escape(start)}'));

double rowY(WidgetTester tester, String assignmentId) =>
    tester.getTopLeft(find.byKey(ValueKey('person-row-$assignmentId'))).dy;

List<String> rowOrder(WidgetTester tester, Summary s) {
  final ids = [for (final p in s.people) p.assignmentId];
  ids.sort((a, b) => rowY(tester, a).compareTo(rowY(tester, b)));
  return ids;
}

void main() {
  setUpAll(loadAppFonts);

  testWidgets('tiles show the numbers of the summary', (tester) async {
    final c = await pumpOverview(tester);
    final s = c.summary;
    expect(s.submitted, greaterThan(0));
    expect(tileValue(tester, 'reports'), '${s.submitted} of ${s.expected}');
    expect(tileValue(tester, 'met'), fmtPct(s.metRate));
    final volume = s.teams.fold<int>(
      0,
      (a, t) => a + t.volumeByMonth.fold<int>(0, (x, y) => x + y),
    );
    expect(tileValue(tester, 'volume'), fmtInt(volume));
    expect(
      tileValue(tester, 'missing'),
      '${s.people.where((p) => !p.submitted).length}',
    );
    expect(find.text('Overview'), findsWidgets);
    expect(find.text('Showing Feb to Apr 2026.'), findsOneWidget);
  });

  testWidgets('every chart has a text alternative with its numbers', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    final c = await pumpOverview(tester);
    final s = c.summary;
    expect(
      semanticsStarting(
        'Who has reported: ${s.submitted} of ${s.expected} reports sent.',
      ),
      findsOneWidget,
    );
    expect(
      semanticsStarting(
        'How targets went: ${s.met} met, ${s.partly} partly met, '
        '${s.missed} missed.',
      ),
      findsOneWidget,
    );
    expect(semanticsStarting('Volume by month: '), findsOneWidget);
    expect(
      semanticsStarting('Biggest counts by total: ${s.metrics.first.label} '),
      findsOneWidget,
    );
    expect(semanticsStarting('Trend over periods: '), findsOneWidget);
    expect(
      semanticsStarting('${s.people.first.name}, ${s.people.first.role}'),
      findsOneWidget,
    );
    for (final t in s.teams) {
      expect(
        semanticsStarting('Who has reported:'),
        findsOneWidget,
        reason: t.name,
      );
    }
    handle.dispose();
  });

  testWidgets('the metric picker shows the chosen count', (tester) async {
    final c = await pumpOverview(tester);
    final s = c.summary;
    expect(s.metrics.length, greaterThan(1));
    final first = s.metrics.first;
    final other = s.metrics[1];
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('metric-detail')),
        matching: find.text('${first.label}: ${fmtInt(first.total)} in total'),
      ),
      findsOneWidget,
    );
    await tester.ensureVisible(find.byKey(const ValueKey('metric-picker')));
    await tester.tap(find.byKey(const ValueKey('metric-picker')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(other.label).last);
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('metric-detail')),
        matching: find.text('${other.label}: ${fmtInt(other.total)} in total'),
      ),
      findsOneWidget,
    );
    for (final m in s.metrics.take(8)) {
      expect(find.text(fmtInt(m.total)), findsWidgets);
    }
  });

  testWidgets('the people table sorts when a header is clicked', (
    tester,
  ) async {
    final c = await pumpOverview(tester);
    final s = c.summary;
    // Everyone sent in the demo period, so the default keeps the deck order.
    expect(rowOrder(tester, s), [for (final p in s.people) p.assignmentId]);

    await tester.tap(find.byKey(const ValueKey('sort-volume')));
    await tester.pumpAndSettle();
    final byVolume = [...s.people]
      ..sort((a, b) => b.volumeTotal.compareTo(a.volumeTotal));
    final order = rowOrder(tester, s);
    expect(
      [
        for (final id in order)
          s.people.firstWhere((p) => p.assignmentId == id).volumeTotal,
      ],
      [for (final p in byVolume) p.volumeTotal],
    );

    await tester.tap(find.byKey(const ValueKey('sort-volume')));
    await tester.pumpAndSettle();
    final asc = rowOrder(tester, s);
    expect(
      s.people.firstWhere((p) => p.assignmentId == asc.first).volumeTotal,
      byVolume.last.volumeTotal,
    );

    await tester.tap(find.byKey(const ValueKey('sort-person')));
    await tester.pumpAndSettle();
    final names = [
      for (final id in rowOrder(tester, s))
        s.people.firstWhere((p) => p.assignmentId == id).name.toLowerCase(),
    ];
    expect(names, [...names]..sort());
  });

  testWidgets('missing people come first and the empty state explains', (
    tester,
  ) async {
    final c = await pumpOverview(tester);
    final s = c.summary;
    // Move to a period nobody reported in, then send one report.
    c.container
        .read(periodSelectionProvider.notifier)
        .select(DateTime(2026, 5));
    await tester.pumpAndSettle();
    expect(find.textContaining('No reports yet for'), findsOneWidget);
    expect(tileValue(tester, 'reports'), '0 of ${s.expected}');
    expect(tileValue(tester, 'met'), '–');
    expect(find.text('How targets went'), findsNothing);
    expect(find.text('What people wrote'), findsNothing);
    expect(find.text('Who has reported'), findsOneWidget);
    expect(find.text('Missing'), findsNWidgets(s.expected));

    // A report arrives: the page reloads by itself after a short wait.
    final period = await c.container.read(periodProvider.future);
    final catalog = c.container.read(catalogProvider).requireValue;
    final a = catalog.assignments.firstWhere((a) => a.metrics.isNotEmpty);
    await c.repo.sendReport(
      Report(
        periodId: period.id,
        assignmentId: a.id,
        status: ReportStatus.submitted,
        values: {
          for (final m in a.metrics) m.id: [1, 2, 3],
        },
        kpis: {for (final k in a.kpis) k.id: const KpiResult(KpiStatus.met)},
      ),
    );
    await tester.pump();
    await tester.pump(summaryDebounce + const Duration(milliseconds: 100));
    await tester.pumpAndSettle();
    expect(tileValue(tester, 'reports'), '1 of ${s.expected}');
    expect(find.textContaining('No reports yet for'), findsNothing);
    expect(find.text('How targets went'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(ValueKey('person-row-${a.id}')),
        matching: find.text('Sent'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('what people wrote shows five, then all on request', (
    tester,
  ) async {
    final c = await pumpOverview(tester);
    final w = c.container.read(writingsProvider);
    final big = NoteKind.values.firstWhere((k) => w.notes[k]!.length > 5);
    final all = w.notes[big]!;
    final section = find.byKey(ValueKey('writings-${big.name}'));
    expect(section, findsOneWidget);
    expect(
      find.descendant(
        of: section,
        matching: find.text('${big.slideTitle} (${all.length})'),
      ),
      findsOneWidget,
    );
    int shown() => all
        .where(
          (x) => find
              .descendant(of: section, matching: find.text(x.text))
              .evaluate()
              .isNotEmpty,
        )
        .length;
    expect(shown(), greaterThanOrEqualTo(5));
    final before = shown();
    await tester.ensureVisible(find.text('Show all ${all.length}'));
    await tester.tap(find.text('Show all ${all.length}'));
    await tester.pumpAndSettle();
    expect(shown(), greaterThan(before));
    expect(find.text('Show fewer'), findsWidgets);
    // Author and team are named.
    expect(
      find.descendant(
        of: section,
        matching: find.text('${all.first.author} · ${all.first.team}'),
      ),
      findsWidgets,
    );
  });

  group('layout', () {
    final sizes = {
      'phone': const Size(360, 800),
      'tablet': const Size(800, 1100),
      'desktop': const Size(1500, 900),
    };
    for (final e in sizes.entries) {
      for (final scale in [1.0, 2.0]) {
        for (final b in [Brightness.light, Brightness.dark]) {
          testWidgets('${e.key} text ${scale}x ${b.name}: no overflow', (
            tester,
          ) async {
            await pumpOverview(
              tester,
              size: e.value,
              textScale: scale,
              brightness: b,
            );
            expect(tester.takeException(), isNull);
            // Scroll through the whole page, nothing may overflow.
            final scroll = find.byType(Scrollable).first;
            for (var i = 0; i < 14; i++) {
              await tester.drag(scroll, const Offset(0, -700));
              await tester.pump();
            }
            expect(tester.takeException(), isNull);
            // The page itself never scrolls sideways.
            final pos = tester
                .state<ScrollableState>(find.byType(Scrollable).first)
                .position;
            expect(pos.axis, Axis.vertical);
          });
        }
      }
    }

    testWidgets('two columns of cards from 1100 px, one below', (tester) async {
      await pumpOverview(tester, size: const Size(1500, 5200));
      final a = tester.getTopLeft(find.text('Who has reported')).dx;
      final b = tester.getTopLeft(find.text('How targets went')).dx;
      expect(b, greaterThan(a + 300));
      await pumpOverview(tester, size: const Size(800, 5200));
      final a2 = tester.getTopLeft(find.text('Who has reported')).dx;
      final b2 = tester.getTopLeft(find.text('How targets went')).dx;
      expect(b2, a2);
    });
  });
}
