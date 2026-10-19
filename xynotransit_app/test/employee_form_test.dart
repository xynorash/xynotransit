import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xynotransit_app/app/providers.dart';
import 'package:xynotransit_app/core/format.dart';
import 'package:xynotransit_app/core/theme/tokens.dart';
import 'package:xynotransit_app/core/widgets.dart';
import 'package:xynotransit_app/data/memory_repository.dart';
import 'package:xynotransit_app/domain/enums.dart';
import 'package:xynotransit_app/domain/period.dart';
import 'package:xynotransit_app/domain/report.dart';
import 'package:xynotransit_app/features/form/form_controller.dart';
import 'package:xynotransit_app/features/form/form_screen.dart';

import 'form_text_test.dart' show customCatalog, pumpCustom, point;
import 'helpers.dart';

Finder numberText(int i) => find.descendant(
  of: find.byType(NumberField).at(i),
  matching: find.byType(TextField),
);

String textOf(WidgetTester t, int i) =>
    t.widget<TextField>(numberText(i)).controller!.text;

double contrast(Color a, Color b) {
  final la = a.computeLuminance(), lb = b.computeLuminance();
  final hi = la > lb ? la : lb, lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

void main() {
  setUpAll(loadAppFonts);

  group('parseWholeNumber', () {
    test('accepts separators and spaces', () {
      expect(parseWholeNumber('1 200').digits, '1200');
      expect(parseWholeNumber('1,234,567').digits, '1234567');
      expect(parseWholeNumber('1 200').digits, '1200');
      expect(parseWholeNumber("1'200").digits, '1200');
      expect(parseWholeNumber('  ').digits, '');
      expect(parseWholeNumber('007').digits, '7');
      expect(parseWholeNumber('0').digits, '0');
    });
    test('refuses decimals, negatives, letters and huge numbers', () {
      expect(parseWholeNumber('12.5').problem, 'Whole numbers only');
      expect(parseWholeNumber('-5').problem, 'Whole numbers only');
      expect(parseWholeNumber('−5').problem, 'Whole numbers only');
      expect(parseWholeNumber('12a').problem, 'Digits only');
      expect(
        parseWholeNumber('1000000001').problem,
        'A number can be at most 1000000000.',
      );
      expect(parseWholeNumber('1000000000').digits, '1000000000');
      expect(parseWholeNumber('1 000 000 000').digits, '1000000000');
      expect(parseWholeNumber('999999999').digits, '999999999');
      expect(parseWholeNumber('abc').problem, 'Digits only');
    });
  });

  group('number fields', () {
    testWidgets('paste with spaces and commas is read as a number', (t) async {
      final c = await pumpCustom(t, customCatalog(1));
      await t.enterText(numberText(0), '1 234,567');
      await t.pump();
      expect(c.read(formControllerProvider).report!.values['m0']![0], 1234567);
      expect(textOf(t, 0), '1234567');
    });

    testWidgets('the documented maximum is accepted, one more is refused', (
      t,
    ) async {
      final c = await pumpCustom(t, customCatalog(1));
      await t.enterText(numberText(0), '1 000 000 000');
      await t.pump();
      expect(
        c.read(formControllerProvider).report!.values['m0']![0],
        1000000000,
      );
      expect(textOf(t, 0), '1000000000');
      await t.enterText(numberText(0), '1000000001');
      await t.pump();
      await t.pump();
      expect(textOf(t, 0), '1000000000');
      expect(find.text('A number can be at most 1000000000.'), findsOneWidget);
      for (final bad in ['12.5', '-5', 'abc']) {
        await t.enterText(numberText(0), bad);
        await t.pump();
        await t.pump();
        expect(textOf(t, 0), '1000000000');
        expect(
          c.read(formControllerProvider).report!.values['m0']![0],
          1000000000,
        );
      }
    });

    testWidgets('a decimal or minus sign is refused with a plain message', (
      t,
    ) async {
      final c = await pumpCustom(t, customCatalog(1));
      await t.enterText(numberText(0), '12');
      await t.enterText(numberText(0), '12.5');
      await t.pump();
      await t.pump();
      expect(textOf(t, 0), '12');
      expect(find.text('Whole numbers only'), findsOneWidget);
      expect(c.read(formControllerProvider).report!.values['m0']![0], 12);
      await t.enterText(numberText(0), '-3');
      await t.pump();
      await t.pump();
      expect(textOf(t, 0), '12');
      // The next good entry clears the message.
      await t.enterText(numberText(0), '13');
      await t.pump();
      await t.pump();
      expect(find.text('Whole numbers only'), findsNothing);
    });

    testWidgets('thousands separators show when the field is left', (t) async {
      await pumpCustom(t, customCatalog(1));
      await t.enterText(numberText(0), '1234567');
      await t.pump();
      expect(textOf(t, 0), '1234567');
      await t.enterText(numberText(1), '5');
      await t.pump();
      expect(textOf(t, 0), '1,234,567');
      await t.showKeyboard(numberText(0));
      await t.pump();
      expect(textOf(t, 0), '1234567');
    });

    testWidgets('the largest number fits on a 360 px phone', (t) async {
      await pumpCustom(t, customCatalog(1));
      t.view.physicalSize = const Size(360, 3000);
      await t.pumpAndSettle();
      await t.enterText(numberText(0), '1000000000');
      await t.enterText(numberText(1), '1');
      await t.pump();
      expect(textOf(t, 0), '1,000,000,000');
      final tp = TextPainter(
        text: TextSpan(
          text: '1,000,000,000',
          style: monoStyle(
            t.element(find.byType(NumberField).first),
            size: 22,
            weight: FontWeight.w500,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final w = t.getSize(numberText(0)).width;
      expect(
        w - 8,
        greaterThan(tp.width),
        reason: 'field $w, text ${tp.width}',
      );
      expect(t.takeException(), isNull);
    });
  });

  group('gaps, errors and focus', () {
    testWidgets('formGaps lists name, numbers, targets in page order', (
      t,
    ) async {
      final cat = customCatalog(1);
      final a = cat.assignments.first;
      final r = Report(
        periodId: 'p',
        assignmentId: 'a',
        values: {
          'm0': [1, null, 3],
        },
        reporter: const Reporter(name: ' ', country: 'KE', role: 'x'),
      );
      final g = formGaps(r, a);
      expect(g.map((e) => e.fieldId), ['name', 'm:m0:1', 'k:k1', 'k:k2']);
      expect(g.map((e) => e.part), [
        FormPart.who,
        FormPart.numbers,
        FormPart.targets,
        FormPart.targets,
      ]);
    });

    testWidgets(
      'a failed Send shows errors under the fields and focuses the first',
      (t) async {
        final c = await pumpCustom(t, customCatalog(1));
        await t.enterText(numberText(0), '5');
        await t.tap(find.text('Send report'));
        await t.pumpAndSettle();
        expect(find.text('Enter a number'), findsNWidgets(2));
        expect(find.text('Choose Met, Partly or Missed'), findsNWidgets(2));
        final focus = c.read(fieldFocusProvider);
        expect(focus.node('m:m0:1').hasFocus, isTrue);
        // Fixing one removes its message at once.
        await t.enterText(numberText(1), '6');
        await t.pump();
        expect(find.text('Enter a number'), findsOneWidget);
        await t.tap(find.text('Met').first);
        await t.pump();
        expect(find.text('Choose Met, Partly or Missed'), findsOneWidget);
      },
    );

    testWidgets('with an empty name the name field gets focus and the error', (
      t,
    ) async {
      final c = await pumpCustom(t, customCatalog(1));
      await t.enterText(find.byKey(const ValueKey('reporter-name')), '');
      await t.tap(find.text('Send report'));
      await t.pumpAndSettle();
      expect(find.text('Enter your name.'), findsWidgets);
      expect(c.read(fieldFocusProvider).node('name').hasFocus, isTrue);
    });

    testWidgets('no errors are shown before the first Send', (t) async {
      await pumpCustom(t, customCatalog(1));
      expect(find.text('Enter a number'), findsNothing);
      expect(find.text('Choose Met, Partly or Missed'), findsNothing);
    });
  });

  group('progress and draft', () {
    testWidgets('progress counts parts and jumps to the unfinished one', (
      t,
    ) async {
      final c = await pumpCustom(t, customCatalog(1));
      expect(find.text('1 of 3 parts done'), findsOneWidget);
      expect(find.text('Numbers: 3 left'), findsOneWidget);
      expect(find.text('Targets: 2 left'), findsOneWidget);
      await t.tap(find.text('Numbers: 3 left'));
      await t.pumpAndSettle();
      expect(c.read(fieldFocusProvider).node('m:m0:0').hasFocus, isTrue);
      for (var i = 0; i < 3; i++) {
        await t.enterText(numberText(i), '1');
      }
      await t.tap(find.text('Met').first);
      await t.tap(find.text('Met').last);
      await t.pump();
      expect(find.textContaining('All 3 parts done'), findsOneWidget);
    });

    testWidgets('draft status shows the time of the last change', (t) async {
      await pumpCustom(t, customCatalog(1));
      expect(
        find.text('Your answers are kept on this device as you type.'),
        findsOneWidget,
      );
      await t.enterText(numberText(0), '5');
      await t.pump();
      expect(
        find.textContaining('Draft saved on this device at '),
        findsOneWidget,
      );
    });

    testWidgets('a restored draft remembers when it was saved', (t) async {
      final c = await pumpCustom(t, customCatalog(1));
      await t.enterText(numberText(0), '5');
      await t.pump();
      final at = c.read(formControllerProvider).draftSavedAt!;
      await c.read(formControllerProvider.notifier).selectAssignment(null);
      await c.read(formControllerProvider.notifier).selectAssignment('a');
      await t.pumpAndSettle();
      final back = c.read(formControllerProvider).draftSavedAt!;
      expect(back.difference(at).inSeconds.abs(), lessThan(2));
      expect(
        find.text('Draft saved on this device at ${hourMinute(back)}.'),
        findsOneWidget,
      );
    });
  });

  group('after sending', () {
    Future<ProviderContainer> sendComplete(WidgetTester t) async {
      final c = await pumpCustom(t, customCatalog(2));
      for (var i = 0; i < 6; i++) {
        await t.enterText(numberText(i), '${1000 * (i + 1)}');
      }
      await t.tap(find.text('Met').first);
      await t.tap(find.text('Missed').last);
      await t.enterText(point('1'), 'Cleared the backlog');
      await t.pump();
      await t.tap(find.text('Send report'));
      await t.pumpAndSettle();
      return c;
    }

    testWidgets('shows what was sent and Edit again goes back', (t) async {
      final c = await sendComplete(t);
      expect(c.read(formControllerProvider).phase, SendPhase.sent);
      expect(find.textContaining('Report sent, '), findsOneWidget);
      expect(find.text('Count 0: 6,000 in total'), findsOneWidget);
      expect(find.text('Count 1: 15,000 in total'), findsOneWidget);
      expect(find.text('Targets: 1 met, 0 partly, 1 missed'), findsOneWidget);
      expect(find.text('1 note'), findsOneWidget);
      // The progress card steps aside.
      expect(find.textContaining('parts done'), findsNothing);
      await t.tap(find.text('Edit again'));
      await t.pumpAndSettle();
      expect(find.textContaining('Report sent, '), findsNothing);
      expect(c.read(fieldFocusProvider).node('name').hasFocus, isTrue);
      expect(c.read(formControllerProvider).phase, SendPhase.idle);
    });

    testWidgets('the sent heading takes focus', (t) async {
      await sendComplete(t);
      final f = FocusManager.instance.primaryFocus;
      expect(f?.debugLabel, 'sent-heading');
    });
  });

  group('changed seat definitions', () {
    testWidgets('a draft is cut to the seat and the person is told', (t) async {
      final c = await pumpCustom(t, customCatalog(1));
      final ctl = c.read(formControllerProvider.notifier);
      ctl.setValue('m0', 0, 7);
      ctl.setKpi('k1', KpiStatus.met);
      // The draft is for a seat that had an extra count and target.
      final old = c
          .read(formControllerProvider)
          .report!
          .copyWith(
            values: {
              'm0': [7, null, null],
              'gone': [1, 2, 3],
            },
            kpis: {
              'k1': const KpiResult(KpiStatus.met),
              'old': const KpiResult(KpiStatus.missed),
            },
          );
      c.read(formControllerProvider.notifier).setReporter(name: 'Ana');
      final prefs = c.read(prefsProvider);
      await prefs.setString(
        'draft/${Period.dateOnly(MemoryRepository.demoStart)}/a',
        jsonEncode(old.toDraftJson()),
      );
      await ctl.selectAssignment(null);
      await ctl.selectAssignment('a');
      await t.pumpAndSettle();
      final r = c.read(formControllerProvider).report!;
      expect(r.values.keys, ['m0']);
      expect(r.values['m0']![0], 7);
      expect(r.kpis.keys, ['k1']);
      expect(
        find.textContaining(
          '1 count and 1 target you answered no longer exist',
        ),
        findsOneWidget,
      );
    });

    test('no notice when nothing was lost', () {
      final a = customCatalog(1).assignments.first;
      final r = Report(periodId: 'p', assignmentId: 'a');
      expect(reconcileNotice(r.reconciliation(a)), isNull);
    });
  });

  group('character counters', () {
    test('warn from 90 percent', () {
      expect(CharCounter.isNear(62, 70), isFalse);
      expect(CharCounter.isNear(63, 70), isTrue);
      expect(CharCounter.isNear(70, 70), isTrue);
    });

    testWidgets('a counter near the limit changes colour and words', (t) async {
      await pumpCustom(t, customCatalog(1));
      final tokens = Theme.of(t.element(find.byType(FormCards)))
          .extension<XynoTokens>()!;
      await t.enterText(point('1'), 'a' * 65);
      await t.pump();
      final txt = t.widget<Text>(find.text('65/70'));
      expect(txt.style!.color, tokens.warn);
      await t.enterText(point('1'), 'a' * 10);
      await t.pump();
      expect(t.widget<Text>(find.text('10/70')).style!.color, tokens.muted);
    });
  });

  group('contrast (WCAG AA)', () {
    for (final (name, tk) in [
      ('light', XynoTokens.light),
      ('dark', XynoTokens.dark),
    ]) {
      test('$name tokens', () {
        for (final bg in [tk.bg, tk.surface, tk.soft]) {
          for (final (n, c) in [
            ('ink', tk.ink),
            ('muted', tk.muted),
            ('bad', tk.bad),
            ('warn', tk.warn),
            ('ok', tk.ok),
            ('accent', tk.accent),
          ]) {
            expect(contrast(c, bg), greaterThanOrEqualTo(4.5), reason: n);
          }
        }
        // The sent card sits on `flash`: text and the check icon on it.
        expect(contrast(tk.ink, tk.flash), greaterThanOrEqualTo(4.5));
        expect(contrast(tk.muted, tk.flash), greaterThanOrEqualTo(4.5));
        expect(contrast(tk.ok, tk.flash), greaterThanOrEqualTo(3));
        expect(contrast(tk.onAccent, tk.accent), greaterThanOrEqualTo(4.5));
        // Field borders and focus rings need 3:1 against the page.
        expect(contrast(tk.accent, tk.bg), greaterThanOrEqualTo(3));
      });
    }
  });
}
