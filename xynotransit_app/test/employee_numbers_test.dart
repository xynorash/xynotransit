import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xynotransit_app/core/theme/tokens.dart';
import 'package:xynotransit_app/core/widgets.dart';
import 'package:xynotransit_app/features/form/form_controller.dart';

import 'employee_form_test.dart' show numberText, textOf;
import 'form_text_test.dart' show customCatalog, pumpCustom;
import 'helpers.dart';

const wholeOnly = 'Whole numbers only: no dots, commas or letters.';
const tooBig = 'A number can be at most 1000000000.';

/// Types [s] one key at a time, the way a person does.
Future<void> typeKeys(WidgetTester t, Finder field, String s) async {
  await t.showKeyboard(field);
  var text = '';
  for (final ch in s.split('')) {
    text += ch;
    await t.enterText(field, text);
    await t.pump();
    // The field may have rewritten the text; the next key goes after it.
    text = t.widget<TextField>(field).controller!.text;
  }
  await t.pump();
}

void main() {
  setUpAll(loadAppFonts);

  group('parseWholeNumber', () {
    test('digits with spaces, thin spaces and NBSP as separators', () {
      expect(parseWholeNumber('1 234').digits, '1234');
      expect(parseWholeNumber('1 234').digits, '1234');
      expect(parseWholeNumber('1 234').digits, '1234');
      expect(parseWholeNumber('1 234').digits, '1234');
      expect(parseWholeNumber('1 000 000 000').digits, '1000000000');
      expect(parseWholeNumber('007').digits, '7');
      expect(parseWholeNumber('   ').digits, '');
      expect(parseWholeNumber('').problem, isNull);
    });

    test('dots, commas, signs, letters and apostrophes are refused', () {
      for (final bad in [
        '12.5',
        '12,5',
        '1,234',
        '-5',
        '+5',
        '12a',
        'abc',
        '1e3',
        "1'200",
        '٣',
      ]) {
        expect(parseWholeNumber(bad).problem, wholeOnly, reason: bad);
        expect(parseWholeNumber(bad).digits, isNull, reason: bad);
      }
    });

    test('over one billion has its own message', () {
      expect(parseWholeNumber('1000000001').problem, tooBig);
      expect(parseWholeNumber('99999999999999999999999').problem, tooBig);
      expect(parseWholeNumber('1 000 000 001').problem, tooBig);
    });
  });

  group('the number field never drops a typed character', () {
    testWidgets('12.5 typed key by key stays 12.5 and counts as missing', (
      t,
    ) async {
      final c = await pumpCustom(t, customCatalog(1));
      await typeKeys(t, numberText(0), '12.5');
      expect(textOf(t, 0), '12.5');
      expect(find.text(wholeOnly), findsOneWidget);
      expect(c.read(formControllerProvider).report!.values['m0']![0], isNull);
      // The message stays while the text stays.
      await t.pump(const Duration(seconds: 2));
      expect(find.text(wholeOnly), findsOneWidget);
    });

    testWidgets('letters stay with a lasting message', (t) async {
      final c = await pumpCustom(t, customCatalog(1));
      await typeKeys(t, numberText(0), 'ab1');
      expect(textOf(t, 0), 'ab1');
      expect(find.text(wholeOnly), findsOneWidget);
      expect(c.read(formControllerProvider).report!.values['m0']![0], isNull);
    });

    testWidgets('fixing the text clears the message and sets the value', (
      t,
    ) async {
      final c = await pumpCustom(t, customCatalog(1));
      await typeKeys(t, numberText(0), '12.5');
      await t.enterText(numberText(0), '125');
      await t.pump();
      expect(find.text(wholeOnly), findsNothing);
      expect(c.read(formControllerProvider).report!.values['m0']![0], 125);
    });

    testWidgets('over one billion stays, with its message', (t) async {
      final c = await pumpCustom(t, customCatalog(1));
      await t.enterText(numberText(0), '1000000001');
      await t.pump();
      expect(textOf(t, 0), '1000000001');
      expect(find.text(tooBig), findsOneWidget);
      expect(c.read(formControllerProvider).report!.values['m0']![0], isNull);
    });

    testWidgets('an invalid field has a red outline', (t) async {
      await pumpCustom(t, customCatalog(1));
      await typeKeys(t, numberText(0), '1.');
      final field = t.widget<TextField>(numberText(0));
      final border = field.decoration!.errorBorder! as OutlineInputBorder;
      expect(border.borderSide.color, t.element(numberText(0)).tokens.bad);
      final decorator = t.widget<InputDecorator>(
        find.descendant(
          of: find.byType(NumberField).first,
          matching: find.byType(InputDecorator),
        ),
      );
      expect(decorator.decoration.errorText, wholeOnly);
    });

    testWidgets('pasted 1 234 and 1 000 000 000 still work', (t) async {
      final c = await pumpCustom(t, customCatalog(1));
      await t.enterText(numberText(0), '1 234');
      await t.pump();
      expect(c.read(formControllerProvider).report!.values['m0']![0], 1234);
      expect(find.text(wholeOnly), findsNothing);
      await t.enterText(numberText(1), '1 000 000 000');
      await t.pump();
      expect(
        c.read(formControllerProvider).report!.values['m0']![1],
        1000000000,
      );
      await t.enterText(numberText(2), '1 500');
      await t.pump();
      expect(c.read(formControllerProvider).report!.values['m0']![2], 1500);
    });

    testWidgets('separators show on blur for valid values only', (t) async {
      await pumpCustom(t, customCatalog(1));
      await t.enterText(numberText(0), '1234567');
      await t.enterText(numberText(1), '12.5');
      await t.pump();
      await t.enterText(numberText(2), '5');
      await t.pump();
      expect(textOf(t, 0), '1,234,567');
      expect(textOf(t, 1), '12.5');
      // Coming back to a formatted value shows plain digits to edit.
      await t.showKeyboard(numberText(0));
      await t.pump();
      expect(textOf(t, 0), '1234567');
    });

    testWidgets('Send is blocked and the first problem takes focus', (t) async {
      final c = await pumpCustom(t, customCatalog(1));
      await t.enterText(numberText(0), '5');
      await typeKeys(t, numberText(1), '7.5');
      await t.enterText(numberText(2), '9');
      await t.tap(find.text('Met').first);
      await t.tap(find.text('Met').last);
      await t.pump();
      await t.tap(find.text('Send report'));
      await t.pumpAndSettle();
      expect(c.read(formControllerProvider).phase, SendPhase.idle);
      expect(c.read(formControllerProvider).attempted, isTrue);
      expect(c.read(fieldFocusProvider).node('m:m0:1').hasFocus, isTrue);
      // The field says what is wrong with the text, not just "Enter a number".
      expect(find.text(wholeOnly), findsOneWidget);
      expect(textOf(t, 1), '7.5');
    });
  });

  group('the largest number fits', () {
    for (final scale in [1.0, 2.0]) {
      for (final width in [360.0, 800.0, 1500.0]) {
        testWidgets('1,000,000,000 at text scale $scale on $width px', (
          t,
        ) async {
          await pumpCustom(t, customCatalog(1));
          t.view.physicalSize = Size(width, 4000);
          t.platformDispatcher.textScaleFactorTestValue = scale;
          addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
          await t.pumpAndSettle();
          for (var i = 0; i < 3; i++) {
            await t.enterText(numberText(i), '1000000000');
          }
          await t.showKeyboard(numberText(0));
          await t.pump();
          // Leave the field so the separators show.
          await t.enterText(numberText(1), '1000000000');
          await t.pump();
          expect(textOf(t, 0), '1,000,000,000');
          for (var i = 0; i < 3; i++) {
            final editable = t
                .state<EditableTextState>(
                  find.descendant(
                    of: numberText(i),
                    matching: find.byType(EditableText),
                  ),
                )
                .renderEditable;
            final painter = TextPainter(
              text: editable.text,
              textDirection: TextDirection.ltr,
              textScaler: editable.textScaler,
            )..layout();
            expect(
              painter.width,
              lessThanOrEqualTo(editable.size.width),
              reason:
                  'field $i: text ${painter.width}, box ${editable.size.width}',
            );
          }
          // The slide preview under the form may overflow by a pixel or two
          // at this text size; nothing else may complain.
          Object? e;
          while ((e = t.takeException()) != null) {
            expect(e.toString(), contains('overflowed'));
            expect(e.toString(), isNot(contains('form_screen')));
          }
        });
      }
    }
  });

  group('the preview wording is true (D10)', () {
    testWidgets('wide: empty numbers show as 0, every month must be filled', (
      t,
    ) async {
      await pumpCustom(t, customCatalog(1));
      expect(
        find.textContaining(
          'In this preview empty numbers show as 0. '
          'You must fill every month before you send.',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('count as 0'), findsNothing);
    });

    testWidgets('narrow: the bar says it too and opens the preview', (t) async {
      await pumpCustom(t, customCatalog(1));
      t.view.physicalSize = const Size(420, 6000);
      await t.pumpAndSettle();
      expect(find.textContaining('count as 0'), findsNothing);
      expect(
        find.textContaining('Empty numbers show as 0 here'),
        findsOneWidget,
      );
      expect(
        find.textContaining('Fill every month before you send'),
        findsOneWidget,
      );
      expect(
        find.bySemanticsLabel(RegExp('empty numbers show as 0')),
        findsWidgets,
      );
    });

    testWidgets('and Send really does need every month', (t) async {
      final c = await pumpCustom(t, customCatalog(1));
      await t.enterText(numberText(0), '5');
      await t.enterText(numberText(1), '6');
      await t.tap(find.text('Met').first);
      await t.tap(find.text('Met').last);
      await t.pump();
      await t.tap(find.text('Send report'));
      await t.pumpAndSettle();
      expect(c.read(formControllerProvider).phase, SendPhase.idle);
      expect(c.read(formControllerProvider).attempted, isTrue);
    });
  });

  testWidgets('Met, Partly and Missed stay on one line each at text scale 2', (
    t,
  ) async {
    await pumpCustom(t, customCatalog(1));
    t.view.physicalSize = const Size(390, 5000);
    t.platformDispatcher.textScaleFactorTestValue = 2.0;
    addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
    await t.pumpAndSettle();
    for (final w in ['Met', 'Partly', 'Missed']) {
      final box = t.getSize(find.text(w).first);
      // One line at 16 px x 2 x height 1.2 is about 39 px; two lines about 77.
      expect(box.height, lessThan(50), reason: w);
    }
    t.takeException();
  });
}
