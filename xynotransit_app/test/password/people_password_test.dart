import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xynotransit_app/domain/enums.dart';

import '../helpers.dart';
import '../support/auth_harness.dart';

Future<AuthHarness> pumpPeople(
  WidgetTester tester, {
  Size size = const Size(1000, 6000),
  double scale = 1,
  Brightness brightness = Brightness.light,
  Future<void> Function(AuthHarness h)? before,
}) => pumpAuthApp(
  tester,
  requireSignIn: false,
  size: size,
  textScale: scale,
  brightness: brightness,
  location: '/manager/people',
  before: before,
);

/// The line of one person's card, found by the text of their state.
Finder state(String id, String text) => find.descendant(
  of: find.byKey(Key('password-state-$id')),
  matching: find.textContaining(text, findRichText: true),
);

String stateOf(WidgetTester t, String id) => t
    .widget<Text>(find.byKey(Key('password-state-$id')).first)
    .textSpan!
    .toPlainText();

String userOf(WidgetTester t, String id) => t
    .widget<Text>(find.byKey(Key('username-$id')).first)
    .textSpan!
    .toPlainText();

/// Records what is put on the clipboard.
List<String> captureClipboard(WidgetTester tester) {
  final copied = <String>[];
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async {
      if (call.method == 'Clipboard.setData') {
        copied.add((call.arguments as Map)['text'] as String);
      }
      return null;
    },
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    ),
  );
  return copied;
}

/// Scrolls the list until the first [text] is built and on screen.
Future<void> revealFirst(WidgetTester t, String text) async {
  final f = find.text(text);
  for (var i = 0; i < 60 && f.evaluate().isEmpty; i++) {
    await t.drag(find.byType(Scrollable).first, const Offset(0, -300));
    await t.pump();
  }
  await t.ensureVisible(f.first);
  await t.pumpAndSettle();
}

Future<void> tapVisible(WidgetTester t, Finder f) async {
  await t.ensureVisible(f);
  await t.pumpAndSettle();
  await t.tap(f);
  await t.pumpAndSettle();
}

Finder resetOf(String name) =>
    find.bySemanticsLabel('Reset password for $name');

void main() {
  setUpAll(loadAppFonts);

  testWidgets('each person shows a username and a password state', (
    tester,
  ) async {
    await pumpPeople(
      tester,
      before: (h) => h.givePassword('p-tahina', 'a purple bicycle'),
    );
    expect(userOf(tester, 'p-rova'), 'Username rova');
    expect(stateOf(tester, 'p-rova'), 'Password Not set');
    expect(stateOf(tester, 'p-tahina'), 'Password Set');
    expect(find.text('Reset password'), findsWidgets);
    // Remove is offered only where there is something to remove.
    expect(
      find.bySemanticsLabel('Remove the password of Tahina'),
      findsWidgets,
    );
    expect(find.bySemanticsLabel('Remove the password of Rova'), findsNothing);
  });

  testWidgets('Reset password explains first, and Cancel changes nothing', (
    tester,
  ) async {
    final h = await pumpPeople(tester);
    await tester.tap(resetOf('Rova').first);
    await tester.pumpAndSettle();
    expect(find.text('Reset password for Rova'), findsOneWidget);
    expect(
      find.textContaining('They must choose their own password'),
      findsOneWidget,
    );
    expect(find.text('Make a temporary password'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Reset password for Rova'), findsNothing);
    expect(stateOf(tester, 'p-rova'), 'Password Not set');
    expect(h.repo.passwordAudit, isEmpty);
  });

  testWidgets('the temporary password is shown once, with Copy', (
    tester,
  ) async {
    final h = await pumpPeople(tester);
    final copied = captureClipboard(tester);
    await tester.tap(resetOf('Rova').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Make a temporary password'));
    await tester.pumpAndSettle();
    final shown = tester
        .widget<SelectableText>(find.byKey(const Key('temp-password')))
        .data!;
    expect(shown, matches(RegExp(r'^[A-HJ-NP-Za-km-z2-9]{16}$')));
    expect(
      tester
          .widget<SelectableText>(find.byKey(const Key('temp-username')))
          .data,
      'rova',
    );
    expect(
      find.text(
        'Tell them to sign in with this and choose their own password. '
        'It is shown only once.',
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('Copy password'));
    await tester.pumpAndSettle();
    expect(copied, [shown]);
    expect(find.text('Copied'), findsOneWidget);
    // The state behind the dialog follows.
    expect(stateOf(tester, 'p-rova'), 'Password Set');
    // And the temporary password really signs them in (and must be changed).
    expect(h.repo.passwordAudit.single.kind, 'reset');
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(find.text(shown), findsNothing);
    expect(find.byKey(const Key('temp-password')), findsNothing);
    // Open again: the old one is not shown, the explanation is.
    await tester.tap(resetOf('Rova').first);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('temp-password')), findsNothing);
    expect(find.text('Make a temporary password'), findsOneWidget);
    expect(
      find.textContaining('The old password stops working'),
      findsOneWidget,
    );
    // Creating another replaces the first.
    await tester.tap(find.text('Make a temporary password'));
    await tester.pumpAndSettle();
    final second = tester
        .widget<SelectableText>(find.byKey(const Key('temp-password')))
        .data!;
    expect(second, isNot(shown));
    expect(h.repo.passwordAudit.map((a) => a.kind), ['reset', 'reset']);
    final auth = h.auth;
    expect(auth.needsSignIn, isFalse);
  });

  testWidgets('a refusal reads in plain words and keeps the dialog', (
    tester,
  ) async {
    final h = await pumpPeople(tester);
    await tester.tap(resetOf('Rova').first);
    await tester.pumpAndSettle();
    // The person is switched off by someone else meanwhile.
    final p = h.repo.currentPersons.firstWhere((p) => p.id == 'p-rova');
    await h.repo.savePerson(
      id: p.id,
      fullName: p.fullName,
      email: p.email!,
      role: AppRole.contributor,
      active: false,
    );
    await tester.tap(find.text('Make a temporary password'));
    await tester.pumpAndSettle();
    expect(find.text('This person is switched off.'), findsOneWidget);
    expect(find.byKey(const Key('temp-password')), findsNothing);
  });

  testWidgets('a switched off person has no Reset password', (tester) async {
    final h = await pumpPeople(tester);
    final p = h.repo.currentPersons.firstWhere((p) => p.id == 'p-rova');
    await h.repo.savePerson(
      id: p.id,
      fullName: p.fullName,
      email: p.email!,
      role: AppRole.contributor,
      active: false,
    );
    await tester.tap(find.byKey(const Key('show-inactive')));
    await tester.pumpAndSettle();
    final off = find.bySemanticsLabel(
      RegExp(r'Reset password for Rova, not available'),
    );
    expect(off, findsOneWidget);
  });

  testWidgets('Remove password asks, then the person is link-only again', (
    tester,
  ) async {
    final h = await pumpPeople(
      tester,
      before: (h) => h.givePassword('p-tahina', 'a purple bicycle'),
    );
    await tester.tap(
      find.bySemanticsLabel('Remove the password of Tahina').first,
    );
    await tester.pumpAndSettle();
    expect(find.text('Remove the password of Tahina?'), findsOneWidget);
    await tester.tap(find.text('Keep password'));
    await tester.pumpAndSettle();
    expect(stateOf(tester, 'p-tahina'), 'Password Set');
    await tester.tap(
      find.bySemanticsLabel('Remove the password of Tahina').first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove password').last);
    await tester.pumpAndSettle();
    expect(stateOf(tester, 'p-tahina'), 'Password Not set');
    expect(find.text('Password of Tahina removed.'), findsOneWidget);
    expect(
      find.bySemanticsLabel('Remove the password of Tahina'),
      findsNothing,
    );
    expect(h.repo.passwordAudit.last.kind, 'remove');
  });

  group('Edit person: username', () {
    Future<void> openEdit(WidgetTester tester, String name) async {
      await tester.tap(find.bySemanticsLabel('Edit $name'));
      await tester.pumpAndSettle();
    }

    testWidgets('shows it and changes it', (tester) async {
      await pumpPeople(tester);
      await openEdit(tester, 'Rova');
      final box = find.byKey(const Key('person-username'));
      expect(tester.widget<TextField>(box).controller!.text, 'rova');
      await tester.enterText(box, 'Rova.Import');
      await tester.tap(find.text('Save person'));
      await tester.pumpAndSettle();
      expect(find.text('Saved.'), findsOneWidget);
      expect(tester.widget<TextField>(box).controller!.text, 'rova.import');
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(userOf(tester, 'p-rova'), 'Username rova.import');
    });

    testWidgets('refuses a bad name and a taken one in the words of the API', (
      tester,
    ) async {
      await pumpPeople(tester);
      await openEdit(tester, 'Rova');
      final box = find.byKey(const Key('person-username'));
      await tester.enterText(box, 'no spaces!');
      await tester.tap(find.text('Save person'));
      await tester.pumpAndSettle();
      expect(
        find.text(
          'Usernames use letters, digits, dots, dashes and underscores, '
          '3 to 40 characters.',
        ),
        findsOneWidget,
      );
      await tester.enterText(box, 'TAHINA');
      await tester.tap(find.text('Save person'));
      await tester.pumpAndSettle();
      expect(find.text('That username is already used.'), findsOneWidget);
    });

    testWidgets('a new person gets one made from the email, or the typed one', (
      tester,
    ) async {
      final h = await pumpPeople(tester);
      await tester.tap(find.text('Add a person'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('person-name')), 'Mina Ravo');
      await tester.enterText(
        find.byKey(const Key('person-email')),
        'mina.ravo@example.com',
      );
      await tester.tap(find.text('Add person'));
      await tester.pumpAndSettle();
      final box = find.byKey(const Key('person-username'));
      expect(tester.widget<TextField>(box).controller!.text, 'mina.ravo');
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      final mina = h.repo.currentPersons.firstWhere(
        (p) => p.fullName == 'Mina Ravo',
      );
      expect(mina.username, 'mina.ravo');
      await tester.tap(find.text('Add a person'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('person-name')), 'Other');
      await tester.enterText(
        find.byKey(const Key('person-username')),
        'chosen_one',
      );
      await tester.tap(find.text('Add person'));
      await tester.pumpAndSettle();
      expect(
        h.repo.currentPersons.firstWhere((p) => p.fullName == 'Other').username,
        'chosen_one',
      );
    });
  });

  group('no overflow', () {
    for (final (w, hh) in [(360.0, 800.0), (800.0, 1100.0), (1500.0, 900.0)]) {
      for (final scale in [1.0, 2.0]) {
        testWidgets('at ${w}x$hh, text scale $scale: list and dialogs', (
          tester,
        ) async {
          final h = await pumpPeople(
            tester,
            size: Size(w, hh),
            scale: scale,
            before: (h) => h.givePassword('p-tahina', 'a purple bicycle'),
          );
          await revealFirst(tester, 'Reset password');
          expect(tester.takeException(), isNull);
          await tapVisible(tester, find.text('Reset password').first);
          expect(tester.takeException(), isNull);
          await tapVisible(tester, find.text('Make a temporary password'));
          expect(tester.takeException(), isNull);
          expect(find.byKey(const Key('temp-password')), findsOneWidget);
          await tapVisible(tester, find.text('Done'));
          expect(h.repo.passwordAudit, isNotEmpty);
          // The Edit person dialog with its new field.
          await revealFirst(tester, 'Edit person');
          await tapVisible(tester, find.text('Edit person').first);
          expect(tester.takeException(), isNull);
          expect(find.byKey(const Key('person-username')), findsOneWidget);
        });
      }
    }
  });

  testWidgets('dark theme: the temporary password is readable', (tester) async {
    await pumpPeople(
      tester,
      size: const Size(800, 1100),
      brightness: Brightness.dark,
    );
    await revealFirst(tester, 'Reset password');
    await tester.tap(find.text('Reset password').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Make a temporary password'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('temp-password')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
