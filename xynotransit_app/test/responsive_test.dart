import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xynotransit_app/app/app.dart';
import 'package:xynotransit_app/app/providers.dart';
import 'package:xynotransit_app/core/theme/tokens.dart';
import 'package:xynotransit_app/core/widgets.dart';
import 'package:xynotransit_app/data/memory_repository.dart';
import 'package:xynotransit_app/data/repository.dart';
import 'package:xynotransit_app/data/seed_data.dart';
import 'package:xynotransit_app/domain/enums.dart';
import 'package:xynotransit_app/features/slides/canvas.dart';

import 'helpers.dart';

Future<void> pump(
  WidgetTester tester, {
  required Size size,
  bool demo = false,
  double textScale = 1,
  Brightness brightness = Brightness.light,
  String location = '/report',
  AppUser? user,
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
  await goTo(tester, location);
}

Future<void> goTo(WidgetTester tester, String path) async {
  ProviderScope.containerOf(tester.element(find.byType(XynotransitApp)))
      .read(routerProvider)
      .go(path);
  await tester.pumpAndSettle();
}

/// Scrolls the dashboard until the Generate button is on screen.
Future<void> revealGenerate(WidgetTester tester) async {
  final gen = find.text('Generate slides');
  if (gen.evaluate().isEmpty) {
    await tester.scrollUntilVisible(
      gen,
      300,
      scrollable: find.byType(Scrollable).first,
    );
  }
  await tester.ensureVisible(gen);
  await tester.pumpAndSettle();
}

Future<void> choose(WidgetTester tester, String label) async {
  await tester.ensureVisible(find.text('Choose your name'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Choose your name'));
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

Future<void> walk(WidgetTester tester, {bool deck = true}) async {
  await choose(tester, 'Rova · Import');
  expect(tester.takeException(), isNull);
  await tester.ensureVisible(find.text('Send report'));
  await tester.tap(find.text('Send report'));
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
  await goTo(tester, '/manager/reports');
  expect(tester.takeException(), isNull);
  if (deck) {
    final gen = find.text('Generate slides');
    {
      await revealGenerate(tester);
      await tester.tap(gen);
      await tester.pump();
      if (find.text('Generate anyway').evaluate().isNotEmpty) {
        await tester.tap(find.text('Generate anyway'));
      }
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.pumpAndSettle();
    }
    final e = tester.takeException();
    expect(e, isNull);
  }
}

double luminance(Color c) {
  double ch(double v) =>
      v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * ch(c.r) + 0.7152 * ch(c.g) + 0.0722 * ch(c.b);
}

double contrast(Color a, Color b) {
  final la = luminance(a);
  final lb = luminance(b);
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

void main() {
  setUpAll(loadAppFonts);

  group('contrast', () {
    for (final entry in {
      'light': XynoTokens.light,
      'dark': XynoTokens.dark,
    }.entries) {
      test('${entry.key} palette text pairs reach 4.5:1', () {
        final t = entry.value;
        final pairs = <String, (Color, Color)>{
          'ink/surface': (t.ink, t.surface),
          'muted/surface': (t.muted, t.surface),
          'muted/bg': (t.muted, t.bg),
          'onAccent/accent': (t.onAccent, t.accent),
          'onOk/ok': (t.onOk, t.ok),
          'onWarn/warn': (t.onWarn, t.warn),
          'onBad/bad': (t.onBad, t.bad),
          'accent/surface': (t.accent, t.surface),
          'bad/surface': (t.bad, t.surface),
        };
        for (final p in pairs.entries) {
          expect(
            contrast(p.value.$1, p.value.$2),
            greaterThanOrEqualTo(4.5),
            reason: '${entry.key} ${p.key}',
          );
        }
      });
    }
  });

  final sizes = {
    'phone 360x800': const Size(360, 800),
    'tablet 800x1100': const Size(800, 1100),
    'desktop 1500x900': const Size(1500, 900),
  };
  for (final s in sizes.entries) {
    testWidgets('no overflow at ${s.key}', (tester) async {
      await pump(tester, size: s.value, demo: true);
      expect(tester.takeException(), isNull);
      await walk(tester);
      if (s.value.width < 500) {
        final slide = find.byType(SlideCanvas);
        if (slide.evaluate().isNotEmpty) {
          final box = tester.getRect(slide.first);
          expect(box.width, lessThanOrEqualTo(s.value.width));
        }
      }
    });

    testWidgets('empty state has no overflow at ${s.key}', (tester) async {
      await pump(tester, size: s.value);
      expect(tester.takeException(), isNull);
      await choose(tester, 'Rova · Import');
      expect(tester.takeException(), isNull);
    });

    testWidgets('empty dashboard has no overflow at ${s.key}', (tester) async {
      await pump(tester, size: s.value, location: '/manager/reports');
      expect(tester.takeException(), isNull);
      expect(find.text('Reports received'), findsOneWidget);
    });

    testWidgets('dashboard with a deck has no overflow at ${s.key}', (
      tester,
    ) async {
      await pump(
        tester,
        size: s.value,
        demo: true,
        location: '/manager/reports',
      );
      expect(tester.takeException(), isNull);
      await revealGenerate(tester);
      await tester.tap(find.text('Generate slides'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.textContaining('Slide 1 of 34'), findsOneWidget);
    });

    testWidgets('person without counts at ${s.key}', (tester) async {
      await pump(tester, size: s.value);
      await choose(tester, 'Shalini · Shipping clerk');
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('phone: month inputs are stacked and fit 1,000,000,000', (
    tester,
  ) async {
    // Deliberate change: three columns left about 80 px per box on a phone,
    // too narrow for a nine digit number with separators.
    await pump(tester, size: const Size(360, 800));
    await choose(tester, 'Rova · Import');
    final f = find.byType(NumberField);
    final a = tester.getTopLeft(f.at(0));
    final b = tester.getTopLeft(f.at(1));
    expect(b.dy, greaterThan(a.dy));
    expect(b.dx, a.dx);
    expect(tester.getSize(f.at(0)).width, greaterThanOrEqualTo(150));
    expect(tester.takeException(), isNull);
  });

  testWidgets('tablet: month inputs stay in 3 columns', (tester) async {
    await pump(tester, size: const Size(820, 1180));
    await choose(tester, 'Rova · Import');
    final f = find.byType(NumberField);
    final a = tester.getTopLeft(f.at(0));
    expect(tester.getTopLeft(f.at(1)).dy, a.dy);
    expect(tester.getTopLeft(f.at(2)).dy, a.dy);
    expect(
      tester.getTopLeft(f.at(2)).dx,
      greaterThan(tester.getTopLeft(f.at(1)).dx),
    );
    expect(tester.takeException(), isNull);
  });

  // ignore: unused_local_variable
  const topBarBug =
      'lib bug: manager top bar actions overflow at 360 px and text scale '
      '2.0 (top_bar.dart), see report';

  testWidgets('text scale 2.0 on the form at phone width', (tester) async {
    await pump(
      tester,
      size: const Size(360, 800),
      demo: true,
      textScale: 2,
      user: const AppUser(
        personId: 'p-rova',
        role: AppRole.contributor,
        label: 'Rova',
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.text('Your numbers, month by month'), findsOneWidget);
  });

  testWidgets(
    'text scale 2.0: no overflow, slides ignore scaling', // see topBarBug
    (tester) async {
      await pump(tester, size: const Size(360, 800), demo: true, textScale: 2);
      expect(tester.takeException(), isNull);
      await walk(tester);
      final slide = find.byType(SlideCanvas);
      if (slide.evaluate().isNotEmpty) {
        final sz = tester.getSize(slide.first);
        expect(sz.width, slideWidth);
        expect(sz.height, slideHeight);
      }
    },
  );

  testWidgets(
    'text scale 2.0 on the dashboard at phone width', // see topBarBug
    (tester) async {
      await pump(
        tester,
        size: const Size(360, 800),
        demo: true,
        textScale: 2,
        location: '/manager/reports',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('text scale 2.0 on the dashboard at desktop width', (
    tester,
  ) async {
    await pump(
      tester,
      size: const Size(1500, 900),
      demo: true,
      textScale: 2,
      location: '/manager/reports',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('text scale 2.0 on desktop', (tester) async {
    await pump(tester, size: const Size(1500, 900), demo: true, textScale: 2);
    await walk(tester, deck: false);
  });

  testWidgets('text scale 2.0 on desktop after Generate', (tester) async {
    await pump(tester, size: const Size(1500, 900), demo: true, textScale: 2);
    await walk(tester);
  });

  testWidgets('dark mode renders without errors', (tester) async {
    await pump(
      tester,
      size: const Size(360, 800),
      demo: true,
      brightness: Brightness.dark,
    );
    expect(tester.takeException(), isNull);
    await walk(tester);
    final ctx = tester.element(find.byType(Scaffold).first);
    expect(Theme.of(ctx).brightness, Brightness.dark);
  });

  testWidgets('form controls have semantics labels', (tester) async {
    final handle = tester.ensureSemantics();
    await pump(tester, size: const Size(1500, 2600), demo: true);
    await choose(tester, 'Rova · Import');
    expect(find.bySemanticsLabel('Send report'), findsWidgets);
    expect(find.bySemanticsLabel('Met'), findsNWidgets(3));
    expect(find.bySemanticsLabel('Partly'), findsNWidgets(3));
    expect(find.bySemanticsLabel('Missed'), findsNWidgets(3));
    expect(find.bySemanticsLabel('Went well, point 1'), findsWidgets);
    // Every text field is labelled.
    final fields = find.byType(TextField);
    expect(fields, findsWidgets);
    for (final e in fields.evaluate()) {
      final data = tester
          .getSemantics(find.byWidget(e.widget))
          .getSemanticsData();
      final text = '${data.label} ${data.hint}'.trim();
      expect(text, isNotEmpty, reason: 'unlabelled field ${e.widget.key}');
    }
    handle.dispose();
  });

  testWidgets('dashboard controls have semantics labels', (tester) async {
    final handle = tester.ensureSemantics();
    await pump(
      tester,
      size: const Size(1500, 2600),
      demo: true,
      location: '/manager/reports',
    );
    expect(find.bySemanticsLabel(RegExp(r'^Edit report of ')), findsWidgets);
    expect(find.bySemanticsLabel('Generate slides'), findsWidgets);
    for (final e in find.byType(TextField).evaluate()) {
      final data = tester
          .getSemantics(find.byWidget(e.widget))
          .getSemanticsData();
      expect('${data.label} ${data.hint}'.trim(), isNotEmpty);
    }
    handle.dispose();
  });

  testWidgets('Tab moves focus forward in visual order', (tester) async {
    await pump(tester, size: const Size(1500, 2600));
    await choose(tester, 'Rova · Import');
    final seen = <Rect>[];
    for (var i = 0; i < 8; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      final f = FocusManager.instance.primaryFocus;
      expect(f, isNotNull);
      final ctx = f!.context;
      if (ctx != null && ctx.findRenderObject() is RenderBox) {
        final box = ctx.findRenderObject()! as RenderBox;
        seen.add(box.localToGlobal(Offset.zero) & box.size);
      }
    }
    expect(seen.length, greaterThan(3));
    // Reading order: rows never go back up by more than a row's height
    // except wrapped to the right column.
    for (var i = 1; i < seen.length; i++) {
      expect(
        seen[i].top >= seen[i - 1].top - 1 ||
            seen[i].left > seen[i - 1].right - 1,
        isTrue,
        reason: 'focus jumped backwards: ${seen[i - 1]} -> ${seen[i]}',
      );
    }
  });

  testWidgets('touch targets are at least 44 high', (tester) async {
    await pump(tester, size: const Size(1500, 2600), demo: false);
    await choose(tester, 'Rova · Import');
    final send = tester.getRect(
      find
          .ancestor(
            of: find.text('Send report'),
            matching: find.byType(FilledButton),
          )
          .first,
    );
    expect(send.height, greaterThanOrEqualTo(46));
    for (final label in ['Met', 'Partly', 'Missed']) {
      final segs = find.ancestor(
        of: find.text(label),
        matching: find.byType(InkWell),
      );
      expect(segs, findsWidgets);
      for (final e in segs.evaluate()) {
        final r = tester.getRect(find.byWidget(e.widget));
        expect(r.height, greaterThanOrEqualTo(46), reason: label);
      }
    }
    final fields = find.byType(TextField);
    expect(fields, findsWidgets);
    for (final e in fields.evaluate()) {
      expect(
        tester.getSize(find.byWidget(e.widget)).height,
        greaterThanOrEqualTo(46),
      );
    }
  });
}
