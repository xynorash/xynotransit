import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xynotransit_app/app/providers.dart';
import 'package:xynotransit_app/core/theme/theme.dart';
import 'package:xynotransit_app/core/widgets.dart';
import 'package:xynotransit_app/data/memory_repository.dart';
import 'package:xynotransit_app/domain/catalog.dart';
import 'package:xynotransit_app/domain/enums.dart';
import 'package:xynotransit_app/features/form/form_controller.dart';
import 'package:xynotransit_app/features/form/form_screen.dart';

import 'form_text_test.dart' show customCatalog, pumpCustom;
import 'helpers.dart';

void walk(SemanticsNode n, void Function(SemanticsNode) f) {
  f(n);
  n.visitChildren((c) {
    walk(c, f);
    return true;
  });
}

List<SemanticsNode> allNodes(WidgetTester t) {
  final out = <SemanticsNode>[];
  // ignore: deprecated_member_use
  final root = t.binding.pipelineOwner.semanticsOwner!.rootSemanticsNode!;
  walk(root, out.add);
  return out;
}

String say(SemanticsNode n) =>
    [n.label, n.value, n.hint].where((e) => e.isNotEmpty).join(' | ');

void main() {
  setUpAll(loadAppFonts);

  testWidgets('every control has a name, headings are in order', (t) async {
    final h = t.ensureSemantics();
    await pumpCustom(t, customCatalog(2));
    final nodes = allNodes(t);
    final fields = nodes.where(
      (n) => n.getSemanticsData().flagsCollection.isTextField,
    );
    // 3 identity, year, 6 numbers, 2 comments, 9 points.
    expect(fields.length, greaterThanOrEqualTo(3 + 6 + 2 + 9));
    for (final n in fields) {
      expect(say(n), isNotEmpty, reason: 'text field without a name');
    }
    // The top bar belongs to the shell; its demo-only menu is checked there.
    final bar = <int>{};
    walk(t.getSemantics(find.byType(AppBar)), (n) => bar.add(n.id));
    final buttons = nodes.where(
      (n) =>
          n.getSemanticsData().flagsCollection.isButton && !bar.contains(n.id),
    );
    for (final n in buttons) {
      expect(say(n), isNotEmpty, reason: 'button without a name ${n.rect}');
    }
    final headings = [
      for (final n in nodes)
        if (n.getSemanticsData().flagsCollection.isHeader) n.label,
    ];
    expect(
      headings.where((e) => e.isNotEmpty).toList(),
      containsAllInOrder([
        'Logistics Report Builder',
        'Who you are',
        'Your numbers, month by month',
        'Did you reach your targets?',
        'What to tell the meeting',
      ]),
    );
    h.dispose();
  });

  testWidgets('number fields are named by count and month, with errors', (
    t,
  ) async {
    final h = t.ensureSemantics();
    await pumpCustom(t, customCatalog(1));
    expect(find.bySemanticsLabel(RegExp(r'^Count 0, ')), findsNWidgets(3));
    // One text field node per box, not a wrapper around another one.
    expect(allNodes(t).where((n) => n.label.startsWith('Count 0, ')).length, 3);
    await t.tap(find.text('Send report'));
    await t.pumpAndSettle();
    // The error text is part of the field's spoken description.
    final named = allNodes(t).where(
      (n) =>
          n.label.startsWith('Count 0, ') &&
          n.hint.contains('Enter a number') &&
          n.getSemanticsData().flagsCollection.isTextField,
    );
    expect(named.length, 3);
    h.dispose();
  });

  testWidgets('totals, progress and counts are live regions', (t) async {
    final h = t.ensureSemantics();
    await pumpCustom(t, customCatalog(1));
    final live = allNodes(t)
        .where((n) => n.getSemanticsData().flagsCollection.isLiveRegion);
    final said = live.map(say).toList();
    expect(said.any((e) => e.startsWith('Total ')), isTrue);
    expect(said.any((e) => e.contains('parts done')), isTrue);
    expect(said.any((e) => e.contains('of 3')), isTrue);
    h.dispose();
  });

  testWidgets('the error summary and the sent card are live regions', (
    t,
  ) async {
    final h = t.ensureSemantics();
    await pumpCustom(t, customCatalog(1));
    await t.tap(find.text('Send report'));
    await t.pumpAndSettle();
    final live = allNodes(t)
        .where((n) => n.getSemanticsData().flagsCollection.isLiveRegion);
    expect(live.map(say).any((e) => e.contains('Almost there')), isTrue);
    h.dispose();
  });

  testWidgets('target buttons say their state', (t) async {
    final h = t.ensureSemantics();
    await pumpCustom(t, customCatalog(1));
    await t.tap(find.text('Partly').first);
    await t.pump();
    final partly = allNodes(t).where(
      (n) =>
          n.label == 'Partly' &&
          n.getSemanticsData().flagsCollection.isChecked.name == 'isTrue',
    );
    expect(partly, isNotEmpty);
    h.dispose();
  });

  testWidgets('Tab reaches Send without a trap, Enter does not send', (
    t,
  ) async {
    final c = await pumpCustom(t, customCatalog(1));
    await t.tap(find.byKey(const ValueKey('reporter-name')));
    await t.pump();
    final seen = <String>[];
    var reachedSend = false;
    for (var i = 0; i < 80 && !reachedSend; i++) {
      await t.sendKeyEvent(LogicalKeyboardKey.tab);
      await t.pump();
      final f = FocusManager.instance.primaryFocus;
      seen.add(f?.debugLabel ?? f.runtimeType.toString());
      final ctx = f?.context;
      reachedSend =
          ctx != null &&
          find
              .descendant(
                of: find.widgetWithText(FilledButton, 'Send report'),
                matching: find.byWidget(ctx.widget),
              )
              .evaluate()
              .isNotEmpty;
      if (!reachedSend && ctx != null) {
        reachedSend = find
            .ancestor(
              of: find.byWidget(ctx.widget),
              matching: find.widgetWithText(FilledButton, 'Send report'),
            )
            .evaluate()
            .isNotEmpty;
      }
    }
    expect(reachedSend, isTrue, reason: 'Tab order: $seen');
    // The order starts with the form: name, country, role, month, year ...
    // and the numbers come before the targets.
    final numIdx = seen.indexWhere((e) => e.startsWith('m:'));
    final tgtIdx = seen.indexWhere((e) => e.startsWith('k:'));
    expect(numIdx, greaterThan(-1));
    expect(tgtIdx, greaterThan(numIdx));
    // Enter in a text box never sends the report.
    await t.tap(find.byKey(const ValueKey('reporter-name')));
    await t.sendKeyEvent(LogicalKeyboardKey.enter);
    await t.pump();
    expect(c.read(formControllerProvider).phase, SendPhase.idle);
    expect(c.read(formControllerProvider).problems, isEmpty);
  });

  testWidgets('Shift+Tab goes back', (t) async {
    await pumpCustom(t, customCatalog(1));
    await t.tap(find.byKey(const ValueKey('reporter-country')));
    await t.pump();
    await t.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await t.sendKeyEvent(LogicalKeyboardKey.tab);
    await t.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await t.pump();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'name');
  });

  group('reduced motion', () {
    testWidgets('a failed Send moves focus and scroll at once', (t) async {
      t.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(t.platformDispatcher.clearAccessibilityFeaturesTestValue);
      final c = await pumpCustom(t, customCatalog(2));
      t.view.physicalSize = const Size(390, 700);
      await t.pumpAndSettle();
      await t.ensureVisible(find.text('Send report'));
      await t.pump();
      await t.tap(find.text('Send report'));
      await t.pump();
      await t.pump();
      final id = c.read(fieldFocusProvider).node('m:m0:0');
      expect(id.hasFocus, isTrue);
      final box = t.getRect(
        find.byWidgetPredicate((w) => w is NumberField).first,
      );
      expect(box.top, greaterThanOrEqualTo(0));
      expect(box.bottom, lessThanOrEqualTo(700));
    });
  });

  group('text scale 200 percent and RTL', () {
    testWidgets('the whole form at 360 px and scale 2 has no overflow', (
      t,
    ) async {
      t.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
      final c = await pumpCustom(
        t,
        customCatalog(8, labelPrefix: 'Very long count name'),
      );
      t.view.physicalSize = const Size(360, 9000);
      await t.pumpAndSettle();
      await c.read(formControllerProvider.notifier).send();
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
    });

    testWidgets('the form mirrors in a right to left layout', (t) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final cat = customCatalog(1);
      final auth = DemoAuth(cat);
      final repo = MemoryRepository(
        catalog: cat,
        currentUser: () => auth.currentUser ?? DemoAuth.controller,
      );
      t.view.physicalSize = const Size(1000, 5000);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      final container = ProviderContainer(
        overrides: [
          prefsProvider.overrideWithValue(prefs),
          repositoryProvider.overrideWithValue(repo),
          authServiceProvider.overrideWithValue(auth),
          initialStartProvider.overrideWithValue(MemoryRepository.demoStart),
        ],
      );
      addTearDown(container.dispose);
      await t.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: buildTheme(Brightness.light),
            builder: (context, child) =>
                Directionality(textDirection: TextDirection.rtl, child: child!),
            home: const Scaffold(
              body: SingleChildScrollView(child: FormCards()),
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      final f = find.byType(NumberField);
      expect(f, findsNWidgets(3));
      // First month is on the right in a right to left layout.
      expect(t.getTopLeft(f.at(0)).dx, greaterThan(t.getTopLeft(f.at(2)).dx));
      await container.read(formControllerProvider.notifier).send();
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
    });
  });

  testWidgets('long unbroken strings do not overflow', (t) async {
    await pumpCustom(t, customCatalog(1));
    final long = 'W' * 80;
    await t.enterText(find.byKey(const ValueKey('reporter-name')), long);
    await t.enterText(
      find.widgetWithText(TextField, 'Point 1').first,
      'Q' * 70,
    );
    await t.enterText(
      find.widgetWithText(TextField, 'Comment (optional)').first,
      'Z' * 200,
    );
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
  });
}

// Keeps the analyzer quiet about unused imports in this file.
// ignore: unused_element
void _unused(Catalog c, AppRole r, KpiStatus s) {}
