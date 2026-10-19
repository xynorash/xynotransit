import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xynotransit_app/app/app.dart';
import 'package:xynotransit_app/data/repository.dart';
import 'package:xynotransit_app/domain/enums.dart';

import '../helpers.dart';
import '../support/auth_harness.dart';

final _user = find.byKey(const Key('signin-username'));
final _pass = find.byKey(const Key('signin-password'));
final _cur = find.byKey(const Key('current-password'));
final _new = find.byKey(const Key('new-password'));
final _again = find.byKey(const Key('repeat-password'));

Future<void> login(WidgetTester t, String u, String p) async {
  await t.enterText(_user, u);
  await t.enterText(_pass, p);
  await t.tap(find.text('Sign in').last);
  await t.pumpAndSettle();
}

Future<void> fill(
  WidgetTester t, {
  String? current,
  String? next,
  String? again,
}) async {
  if (current != null) await t.enterText(_cur, current);
  if (next != null) await t.enterText(_new, next);
  if (again != null) await t.enterText(_again, again);
  await t.pump();
}

Future<void> save(WidgetTester t) async {
  await t.ensureVisible(find.text('Save password'));
  await t.pump();
  await t.tap(find.text('Save password'));
  await t.pumpAndSettle();
}

Future<String> linkTokenFor(
  AuthHarness h,
  String personId, {
  bool recovery = false,
}) async {
  final link = await h.repo.createSignInLink(personId, recovery: recovery);
  return Uri.parse(link.url).queryParameters['token']!;
}

void main() {
  setUpAll(loadAppFonts);

  group('after a link sign-in without a password', () {
    testWidgets('offers Choose a password, and Skip for now is allowed', (
      tester,
    ) async {
      final h = await pumpAuthApp(tester);
      final token = await linkTokenFor(h, 'p-rova');
      h.container.read(routerProvider).go('/auth/verify?token=$token');
      await tester.pumpAndSettle();
      expect(find.text('Choose a password'), findsOneWidget);
      expect(find.byKey(const Key('verify-username')), findsOneWidget);
      expect(find.text('Your username is rova.'), findsOneWidget);
      expect(find.text('Skip for now'), findsOneWidget);
      expect(find.text('Save password'), findsOneWidget);
      // Nothing to type for a current password: there is none.
      expect(_cur, findsNothing);
      await tester.tap(find.text('Skip for now'));
      await tester.pumpAndSettle();
      expect(h.location, '/report');
      expect(h.auth.currentUser!.personId, 'p-rova');
      expect(h.auth.currentUser!.hasPassword, isFalse);
    });

    testWidgets('choosing one signs in with it next time', (tester) async {
      final h = await pumpAuthApp(tester);
      final token = await linkTokenFor(h, 'p-rova');
      h.container.read(routerProvider).go('/auth/verify?token=$token');
      await tester.pumpAndSettle();
      await fill(tester, next: 'a purple bicycle', again: 'a purple bicycle');
      await save(tester);
      expect(h.location, '/report');
      expect(h.auth.currentUser!.hasPassword, isTrue);
      await h.auth.signOut();
      await tester.pumpAndSettle();
      expect(h.location, '/signin');
      await login(tester, 'rova', 'a purple bicycle');
      expect(h.location, '/report');
    });

    testWidgets('a person who has a password goes straight home', (
      tester,
    ) async {
      final h = await pumpAuthApp(
        tester,
        before: (h) => h.givePassword('p-rova', 'a purple bicycle'),
      );
      final token = await linkTokenFor(h, 'p-rova');
      h.container.read(routerProvider).go('/auth/verify?token=$token');
      await tester.pump();
      await tester.pump();
      expect(find.text('You are signed in'), findsOneWidget);
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(h.location, '/report');
    });

    testWidgets('says the policy in plain words', (tester) async {
      final h = await pumpAuthApp(tester);
      final token = await linkTokenFor(h, 'p-rova');
      h.container.read(routerProvider).go('/auth/verify?token=$token');
      await tester.pumpAndSettle();
      for (final (next, again, words) in [
        ('short', 'short', 'Use at least 10 characters.'),
        (
          'password123',
          'password123',
          'That password is too common. Pick something only you would think of.',
        ),
        ('rova', 'rova', 'Use at least 10 characters.'),
        (
          'a purple bicycle',
          'a purple bicyclf',
          'The two passwords are not the same.',
        ),
      ]) {
        await fill(tester, next: next, again: again);
        await save(tester);
        expect(find.byKey(const Key('password-error')), findsOneWidget);
        expect(find.text(words), findsOneWidget, reason: next);
      }
      expect(h.auth.currentUser!.hasPassword, isFalse);
    });
  });

  group('live hints and the strength meter', () {
    Future<void> openChoose(WidgetTester tester) async {
      final h = await pumpAuthApp(tester);
      final token = await linkTokenFor(h, 'p-rova');
      h.container.read(routerProvider).go('/auth/verify?token=$token');
      await tester.pumpAndSettle();
    }

    String words(WidgetTester t) =>
        t.widget<Text>(find.byKey(const Key('strength-words'))).data!;

    testWidgets('the meter only reflects length and common-ness', (
      tester,
    ) async {
      await openChoose(tester);
      expect(words(tester), 'Strength');
      final seen = <String, String>{};
      for (final pw in [
        'Ab1!',
        'password123',
        '1234567890',
        'abcdefghik',
        'Zq9!Zq9!Zq',
        'twelve chars',
        'a purple bicycle',
        'correct horse battery staple',
      ]) {
        await fill(tester, next: pw);
        seen[pw] = words(tester);
      }
      expect(seen, {
        'Ab1!': 'Too short',
        'password123': 'Too easy to guess',
        '1234567890': 'Too easy to guess',
        'abcdefghik': 'Fair',
        'Zq9!Zq9!Zq': 'Fair',
        'twelve chars': 'Fair',
        'a purple bicycle': 'Good',
        'correct horse battery staple': 'Strong',
      });
    });

    testWidgets('the three hints tick as the password gets better', (
      tester,
    ) async {
      await openChoose(tester);
      int ticks() => find.byIcon(Icons.check_circle).evaluate().length;
      expect(ticks(), 0);
      await fill(tester, next: 'short');
      expect(ticks(), 0);
      await fill(tester, next: 'password123');
      expect(ticks(), 2); // long enough, not the username; but too common
      await fill(tester, next: 'a purple bicycle');
      expect(ticks(), 3);
      await fill(tester, next: 'rova');
      expect(ticks(), 0);
    });

    testWidgets('the meter has a spoken name', (tester) async {
      final handle = tester.ensureSemantics();
      await openChoose(tester);
      await fill(tester, next: 'a purple bicycle');
      expect(find.bySemanticsLabel('Password strength: Good'), findsOneWidget);
      handle.dispose();
    });
  });

  group('a temporary password', () {
    Future<AuthHarness> pumpForced(
      WidgetTester tester, {
      Size size = const Size(1000, 1100),
      double scale = 1,
    }) async {
      late String temp;
      final h = await pumpAuthApp(
        tester,
        size: size,
        textScale: scale,
        before: (h) async =>
            temp = (await h.repo.resetPassword('p-rova')).password,
      );
      await login(tester, 'rova', temp);
      _temp = temp;
      return h;
    }

    testWidgets('lands on a blocking Choose a new password screen', (
      tester,
    ) async {
      final h = await pumpForced(tester);
      expect(h.location, '/account/password');
      expect(find.text('Choose a new password'), findsOneWidget);
      expect(find.text('Temporary password'), findsOneWidget);
      // No way around it: no skip, no cancel, no navigation bar.
      expect(find.text('Skip for now'), findsNothing);
      expect(find.text('Cancel'), findsNothing);
      expect(find.byType(AppBar), findsNothing);
      expect(find.text('Sign out'), findsOneWidget);
    });

    testWidgets('nothing else is reachable', (tester) async {
      final h = await pumpForced(tester);
      for (final path in [
        '/',
        '/report',
        '/manager',
        '/manager/people',
        '/manager/reports',
        '/gallery',
        '/signin',
        '/auth/verify?token=x',
        '/nothing',
      ]) {
        h.container.read(routerProvider).go(path);
        await tester.pumpAndSettle();
        expect(h.location, '/account/password', reason: path);
        expect(find.text('Choose a new password'), findsOneWidget);
      }
    });

    testWidgets('a manager is held too', (tester) async {
      late String temp;
      final h = await pumpAuthApp(
        tester,
        before: (h) async =>
            temp = (await h.repo.resetPassword('p-rova')).password,
      );
      // Make the manager (no person) a person with a temp password: use a
      // controller person instead.
      await h.repo.savePerson(
        fullName: 'Ana Boss',
        email: 'ana@example.com',
        role: AppRole.controller,
      );
      final t = await h.repo.resetPassword(
        h.repo.currentPersons
            .firstWhere((p) => p.email == 'ana@example.com')
            .id,
      );
      await login(tester, 'ana', t.password);
      expect(h.location, '/account/password');
      h.container.read(routerProvider).go('/manager');
      await tester.pumpAndSettle();
      expect(h.location, '/account/password');
      expect(temp, isNotEmpty);
    });

    testWidgets('the wrong temporary password is refused in words', (
      tester,
    ) async {
      final h = await pumpForced(tester);
      await fill(
        tester,
        current: 'not the one at all',
        next: 'a purple bicycle',
        again: 'a purple bicycle',
      );
      await save(tester);
      expect(find.text('Your current password is not right.'), findsOneWidget);
      expect(h.location, '/account/password');
    });

    testWidgets('an empty temporary password box is asked for', (tester) async {
      await pumpForced(tester);
      await fill(tester, next: 'a purple bicycle', again: 'a purple bicycle');
      await save(tester);
      expect(find.text('Enter the temporary password.'), findsOneWidget);
    });

    testWidgets('choosing a new one opens the app and ends the temporary one', (
      tester,
    ) async {
      final h = await pumpForced(tester);
      await fill(
        tester,
        current: _temp,
        next: 'a purple bicycle',
        again: 'a purple bicycle',
      );
      await save(tester);
      expect(h.location, '/report');
      expect(h.auth.currentUser!.mustChangePassword, isFalse);
      expect(find.text('Choose a new password'), findsNothing);
      // The page works again.
      expect(find.text('Who you are'), findsOneWidget);
      await h.auth.signOut();
      await tester.pumpAndSettle();
      await login(tester, 'rova', _temp);
      expect(find.text('Username or password is wrong.'), findsOneWidget);
      await login(tester, 'rova', 'a purple bicycle');
      expect(h.location, '/report');
    });

    testWidgets('Sign out leaves the screen', (tester) async {
      final h = await pumpForced(tester);
      await tester.tap(find.text('Sign out'));
      await tester.pumpAndSettle();
      expect(h.location, '/signin');
      expect(h.auth.currentUser, isNull);
    });

    for (final (w, hh) in [(360.0, 800.0), (800.0, 1100.0), (1500.0, 900.0)]) {
      for (final scale in [1.0, 2.0]) {
        testWidgets('no overflow at ${w}x$hh, text scale $scale', (
          tester,
        ) async {
          await pumpForced(tester, size: Size(w, hh), scale: scale);
          await fill(tester, current: 'x', next: 'password123', again: 'y');
          await save(tester);
          expect(tester.takeException(), isNull);
          expect(
            find.text(
              'That password is too common. Pick something only you would '
              'think of.',
            ),
            findsOneWidget,
          );
        });
      }
    }
  });

  group('the account menu', () {
    testWidgets('an employee changes the password from the top bar', (
      tester,
    ) async {
      final h = await pumpAuthApp(
        tester,
        before: (h) => h.givePassword('p-rova', 'a purple bicycle'),
      );
      await login(tester, 'rova', 'a purple bicycle');
      expect(h.location, '/report');
      await tester.tap(find.byTooltip('Account'));
      await tester.pumpAndSettle();
      expect(find.text('Rova (rova)'), findsOneWidget);
      expect(find.text('Sign out'), findsOneWidget);
      await tester.tap(find.text('Change password'));
      await tester.pumpAndSettle();
      expect(h.location, '/account/password');
      expect(find.text('Change password'), findsOneWidget);
      expect(find.text('Current password'), findsOneWidget);
      expect(find.text('Cancel'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(h.location, '/report');
    });

    testWidgets('a person without a password sees Choose a password', (
      tester,
    ) async {
      final h = await pumpAuthApp(tester);
      final token = await linkTokenFor(h, 'p-rova');
      h.container.read(routerProvider).go('/auth/verify?token=$token');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Skip for now'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Account'));
      await tester.pumpAndSettle();
      expect(find.text('Change password'), findsNothing);
      await tester.tap(find.text('Choose a password'));
      await tester.pumpAndSettle();
      expect(h.location, '/account/password');
      expect(_cur, findsNothing);
      expect(find.text('Skip for now'), findsOneWidget);
    });

    testWidgets('change: current, new, repeat; the old session ends', (
      tester,
    ) async {
      final h = await pumpAuthApp(
        tester,
        before: (h) => h.givePassword('p-rova', 'a purple bicycle'),
      );
      await login(tester, 'rova', 'a purple bicycle');
      final before = h.auth.currentUser!;
      h.container.read(routerProvider).go('/account/password');
      await tester.pumpAndSettle();
      await fill(
        tester,
        current: 'a purple bicycle',
        next: 'a green kitchen sink',
        again: 'a green kitchen sink',
      );
      await save(tester);
      expect(find.text('Password saved'), findsOneWidget);
      expect(find.text('Continue'), findsOneWidget);
      final after = h.auth.currentUser!;
      expect(after.sessionEpoch, greaterThan(before.sessionEpoch));
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(h.location, '/report');
      // The session of another device (the old one) is refused.
      expect(
        () => h.repo.changePasswordOf(
          before,
          currentPassword: 'a green kitchen sink',
          newPassword: 'yet another long phrase',
        ),
        throwsA(
          isA<RepositoryException>().having(
            (e) => e.message,
            'message',
            'Please sign in again.',
          ),
        ),
      );
    });

    testWidgets('the demo reaches the screens from the menu too', (
      tester,
    ) async {
      final h = await pumpAuthApp(
        tester,
        requireSignIn: false,
        location: '/manager',
      );
      await tester.tap(find.byTooltip('Account'));
      await tester.pumpAndSettle();
      // No sign out in the public demo.
      expect(find.text('Sign out'), findsNothing);
      await tester.tap(find.text('Choose a password'));
      await tester.pumpAndSettle();
      expect(h.location, '/account/password');
      await fill(
        tester,
        next: 'the demo manager phrase',
        again: 'the demo manager phrase',
      );
      await save(tester);
      expect(h.location, '/manager');
      expect(h.auth.currentUser!.hasPassword, isTrue);
      await tester.tap(find.byTooltip('Account'));
      await tester.pumpAndSettle();
      expect(find.text('Change password'), findsOneWidget);
    });

    testWidgets('the phone menu has it as well', (tester) async {
      final h = await pumpAuthApp(
        tester,
        size: const Size(360, 800),
        requireSignIn: false,
        location: '/manager',
      );
      await tester.tap(find.byTooltip('Menu'));
      await tester.pumpAndSettle();
      expect(find.text('Choose a password'), findsOneWidget);
      await tester.tap(find.text('Choose a password'));
      await tester.pumpAndSettle();
      expect(h.location, '/account/password');
    });
  });

  group('the change screen at every size', () {
    for (final (w, hh) in [(360.0, 800.0), (800.0, 1100.0), (1500.0, 900.0)]) {
      for (final scale in [1.0, 2.0]) {
        for (final dark in [false, true]) {
          testWidgets('no overflow at ${w}x$hh, scale $scale, dark $dark', (
            tester,
          ) async {
            await pumpAuthApp(
              tester,
              requireSignIn: false,
              size: Size(w, hh),
              textScale: scale,
              brightness: dark ? Brightness.dark : Brightness.light,
              location: '/account/password',
            );
            await fill(tester, next: 'password123', again: 'password124');
            await save(tester);
            expect(tester.takeException(), isNull);
            expect(find.text('Choose a password'), findsOneWidget);
          });
        }
      }
    }
  });

  group('a link sign-in by a person who has a password', () {
    Future<AuthHarness> openAfterLink(
      WidgetTester tester, {
      Size size = const Size(1000, 1100),
      double textScale = 1.0,
      bool recovery = true,
    }) async {
      final h = await pumpAuthApp(
        tester,
        size: size,
        textScale: textScale,
        before: (h) => h.givePassword('p-rova', 'a purple bicycle'),
      );
      final token = await linkTokenFor(h, 'p-rova', recovery: recovery);
      h.container.read(routerProvider).go('/auth/verify?token=$token');
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      h.container.read(routerProvider).go('/account/password');
      await tester.pumpAndSettle();
      return h;
    }

    testWidgets('no current password box, and the words say why', (
      tester,
    ) async {
      final h = await openAfterLink(tester);
      expect(find.text('Change password'), findsWidgets);
      expect(_cur, findsNothing);
      expect(find.text('Current password'), findsNothing);
      expect(
        find.text(
          'You signed in with a link, so you can choose a new password '
          'without the old one.',
        ),
        findsOneWidget,
      );
      await fill(
        tester,
        next: 'green kitchen sink',
        again: 'green kitchen sink',
      );
      await save(tester);
      expect(find.text('Password saved'), findsOneWidget);
      expect(h.auth.currentUser!.recentLinkSession, isFalse);
      // The next change is a password session: the box is back.
      h.container.read(routerProvider).go('/report');
      await tester.pumpAndSettle();
      h.container.read(routerProvider).go('/account/password');
      await tester.pumpAndSettle();
      expect(_cur, findsOneWidget);
      expect(find.byKey(const Key('link-recovery-note')), findsNothing);
    });

    testWidgets('after 15 minutes the server asks and the box comes back', (
      tester,
    ) async {
      final h = await openAfterLink(tester);
      expect(_cur, findsNothing);
      h.clock.advance(const Duration(minutes: 16));
      await fill(
        tester,
        next: 'green kitchen sink',
        again: 'green kitchen sink',
      );
      await save(tester);
      expect(find.text('Enter your current password.'), findsOneWidget);
      expect(_cur, findsOneWidget);
      expect(find.byKey(const Key('link-recovery-note')), findsNothing);
      await fill(tester, current: 'a purple bicycle');
      await save(tester);
      expect(find.text('Password saved'), findsOneWidget);
    });

    testWidgets('a link without recovery still asks for the current password', (
      tester,
    ) async {
      final h = await openAfterLink(tester, recovery: false);
      expect(_cur, findsOneWidget);
      expect(find.byKey(const Key('link-recovery-note')), findsNothing);
      expect(h.auth.currentUser!.recentLinkSession, isFalse);
      await fill(
        tester,
        current: 'not it at all',
        next: 'green kitchen sink',
        again: 'green kitchen sink',
      );
      await save(tester);
      expect(find.text('Your current password is not right.'), findsOneWidget);
      await fill(tester, current: 'a purple bicycle');
      await save(tester);
      expect(find.text('Password saved'), findsOneWidget);
    });

    testWidgets('ten wrong current passwords sign the person out', (
      tester,
    ) async {
      final h = await openAfterLink(tester, recovery: false);
      for (var i = 0; i < 9; i++) {
        await fill(
          tester,
          current: 'wrong guess $i',
          next: 'green kitchen sink',
          again: 'green kitchen sink',
        );
        await save(tester);
        expect(
          find.text('Your current password is not right.'),
          findsOneWidget,
        );
      }
      await fill(tester, current: 'wrong guess 9');
      await save(tester);
      expect(h.auth.currentUser, isNull);
      expect(find.byKey(const Key('signin-username')), findsOneWidget);
      expect(
        find.text(
          'You were signed out for safety after too many wrong passwords. '
          'Sign in again.',
        ),
        findsOneWidget,
      );
      // The person signs in again with the password.
      await tester.enterText(find.byKey(const Key('signin-username')), 'rova');
      await tester.enterText(
        find.byKey(const Key('signin-password')),
        'a purple bicycle',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(h.auth.currentUser, isNotNull);
    });

    testWidgets('a password sign-in shows the current password box', (
      tester,
    ) async {
      final h = await pumpAuthApp(
        tester,
        before: (h) => h.givePassword('p-rova', 'a purple bicycle'),
      );
      await login(tester, 'rova', 'a purple bicycle');
      h.container.read(routerProvider).go('/account/password');
      await tester.pumpAndSettle();
      expect(_cur, findsOneWidget);
      expect(find.text('Current password'), findsOneWidget);
    });

    testWidgets('the note and the fields have semantics', (tester) async {
      final handle = tester.ensureSemantics();
      await openAfterLink(tester);
      expect(
        find.bySemanticsLabel(RegExp('You signed in with a link')),
        findsOneWidget,
      );
      expect(find.bySemanticsLabel('New password'), findsOneWidget);
      handle.dispose();
    });

    for (final (w, hh) in [(360.0, 800.0), (800.0, 1100.0), (1500.0, 900.0)]) {
      for (final scale in [1.0, 2.0]) {
        testWidgets('no overflow at ${w}x$hh, scale $scale', (tester) async {
          await openAfterLink(tester, size: Size(w, hh), textScale: scale);
          await fill(tester, next: 'password123', again: 'password124');
          await save(tester);
          expect(tester.takeException(), isNull);
          expect(find.byKey(const Key('link-recovery-note')), findsOneWidget);
        });
      }
    }
  });
}

String _temp = '';
