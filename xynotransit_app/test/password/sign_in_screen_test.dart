import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xynotransit_app/app/providers.dart';
import 'package:xynotransit_app/core/theme/theme.dart';
import 'package:xynotransit_app/data/api/api_auth.dart';
import 'package:xynotransit_app/data/api/api_client.dart';
import 'package:xynotransit_app/features/sign_in_screen.dart';

import '../api/api_client_test.dart' show json;
import '../helpers.dart';
import '../support/auth_harness.dart';

final _user = find.byKey(const Key('signin-username'));
final _pass = find.byKey(const Key('signin-password'));
final _passField = find.descendant(of: _pass, matching: find.byType(TextField));

bool _obscured(WidgetTester t, Finder field) => t
    .widget<EditableText>(
      find.descendant(of: field, matching: find.byType(EditableText)),
    )
    .obscureText;

/// The sign-in screen alone, on the real ApiAuthService with a fake server.
Future<List<http.Request>> pumpApi(
  WidgetTester tester,
  MockClientHandler h, {
  Size size = const Size(800, 1000),
}) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final seen = <http.Request>[];
  final auth = ApiAuthService(
    ApiClient(
      baseUrl: '/api',
      tokens: TokenStore(prefs),
      client: MockClient((r) {
        seen.add(r);
        return h(r);
      }),
      timeout: const Duration(milliseconds: 200),
      retryDelay: (_) => Duration.zero,
    ),
  );
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [authServiceProvider.overrideWithValue(auth)],
      child: MaterialApp(
        theme: buildTheme(Brightness.light),
        home: const SignInScreen(),
      ),
    ),
  );
  return seen;
}

void main() {
  setUpAll(loadAppFonts);

  testWidgets('shows the password form first and the link form below', (
    tester,
  ) async {
    await pumpApi(tester, (r) async => fail('no call expected'));
    expect(find.text('Logistics Report Builder'), findsOneWidget);
    expect(find.text('Username'), findsOneWidget);
    expect(find.text('Password'), findsOneWidget);
    expect(find.text('Sign in'), findsOneWidget);
    expect(find.text('Sign in with a link instead'), findsOneWidget);
    expect(find.text('Work email'), findsOneWidget);
    expect(find.text('Send me a link'), findsOneWidget);
    expect(
      find.text('No email address? Ask your manager for a sign-in link.'),
      findsOneWidget,
    );
    expect(
      find.text('Forgot your password? Ask your manager for a new one.'),
      findsOneWidget,
    );
    // The password form comes first, the link section below it.
    expect(
      tester.getTopLeft(find.text('Sign in')).dy,
      lessThan(tester.getTopLeft(find.text('Sign in with a link instead')).dy),
    );
  });

  testWidgets(
    'fields carry the autofill hints browsers and password managers need',
    (tester) async {
      await pumpApi(tester, (r) async => fail('no call expected'));
      TextField field(Finder f) => tester.widget<TextField>(
        find.descendant(of: f, matching: find.byType(TextField)).first,
      );
      final u = tester.widget<TextField>(_user);
      expect(u.autofillHints, [AutofillHints.username]);
      expect(field(_pass).autofillHints, [AutofillHints.password]);
      expect(find.byType(AutofillGroup), findsOneWidget);
      // The group holds the two fields of the password form and nothing else.
      expect(
        find.descendant(
          of: find.byType(AutofillGroup),
          matching: find.byType(TextField),
        ),
        findsNWidgets(2),
      );
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('signin-email')))
            .autofillHints,
        [AutofillHints.email],
      );
    },
  );

  testWidgets('the eye shows and hides the password', (tester) async {
    await pumpApi(tester, (r) async => fail('no call expected'));
    expect(_obscured(tester, _pass), isTrue);
    expect(find.byTooltip('Show password'), findsOneWidget);
    await tester.tap(find.byTooltip('Show password'));
    await tester.pump();
    expect(_obscured(tester, _pass), isFalse);
    expect(find.byTooltip('Hide password'), findsOneWidget);
    await tester.tap(find.byTooltip('Hide password'));
    await tester.pump();
    expect(_obscured(tester, _pass), isTrue);
  });

  testWidgets('Enter in the password box signs in; spaces are kept', (
    tester,
  ) async {
    final seen = await pumpApi(
      tester,
      (r) async => json({
        'access_token': 'tok',
        'expires_at': '2026-10-26T00:00:00Z',
        'user': {'person_id': 'p1', 'role': 'contributor', 'label': 'Rosa'},
        'must_change_password': false,
        'has_password': true,
      }),
    );
    await tester.enterText(_user, ' Rosa.Rakoto ');
    await tester.enterText(_pass, ' a purple  bicycle ');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(seen, hasLength(1));
    expect(seen.single.url.path, '/api/auth/login');
    expect(jsonDecode(seen.single.body), {
      'username': 'rosa.rakoto',
      'password': ' a purple  bicycle ',
    });
    // The browser is told the sign-in worked, so it offers to save the password.
    expect(
      tester.testTextInput.log.any(
        (c) => c.method == 'TextInput.finishAutofillContext',
      ),
      isTrue,
    );
  });

  testWidgets('the button signs in too, and shows a busy label', (
    tester,
  ) async {
    final gate = Completer<void>();
    final seen = await pumpApi(tester, (r) async {
      await gate.future;
      return json({
        'access_token': 't',
        'expires_at': 'x',
        'user': {'person_id': 'p1', 'role': 'contributor', 'label': 'Rosa'},
        'has_password': true,
        'must_change_password': false,
      });
    });
    await tester.enterText(_user, 'rosa');
    await tester.enterText(_pass, 'a purple bicycle');
    await tester.tap(find.text('Sign in'));
    await tester.pump();
    expect(find.text('Signing in…'), findsOneWidget);
    // A second press while waiting does nothing.
    await tester.tap(find.text('Signing in…'), warnIfMissed: false);
    gate.complete();
    await tester.pumpAndSettle();
    expect(seen, hasLength(1));
  });

  testWidgets('empty boxes are not sent', (tester) async {
    final seen = await pumpApi(tester, (r) async => fail('no call expected'));
    await tester.tap(find.text('Sign in'));
    await tester.pump();
    expect(find.text('Enter your username.'), findsOneWidget);
    await tester.enterText(_user, 'rosa');
    await tester.tap(find.text('Sign in'));
    await tester.pump();
    expect(find.text('Enter your password.'), findsOneWidget);
    expect(seen, isEmpty);
  });

  testWidgets('a wrong login shows only the generic words', (tester) async {
    await pumpApi(
      tester,
      (r) async => json({'error': 'Username or password is wrong.'}, 401),
    );
    await tester.enterText(_user, 'nobody');
    await tester.enterText(_pass, 'a purple bicycle');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('signin-error')), findsOneWidget);
    expect(find.text('Username or password is wrong.'), findsOneWidget);
    // The password stays typed, so a typo can be fixed.
    expect(
      tester.widget<TextField>(_passField).controller!.text,
      'a purple bicycle',
    );
  });

  testWidgets('a 429 says when to try again', (tester) async {
    await pumpApi(
      tester,
      (r) async => http.Response(
        jsonEncode({'error': 'Too many sign-in attempts. Try again later.'}),
        429,
        headers: {'retry-after': '840'},
      ),
    );
    await tester.enterText(_user, 'rosa');
    await tester.enterText(_pass, 'a purple bicycle');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    expect(
      find.text('Too many sign-in attempts. Try again in 14 minutes.'),
      findsOneWidget,
    );
    expect(find.textContaining('later'), findsNothing);
  });

  testWidgets('no connection reads plainly and keeps the boxes', (
    tester,
  ) async {
    await pumpApi(tester, (r) async => http.Response('', 502));
    await tester.enterText(_user, 'rosa');
    await tester.enterText(_pass, 'a purple bicycle');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    expect(
      find.text('Could not sign in. Check your connection and try again.'),
      findsOneWidget,
    );
  });

  testWidgets('the link form still works and says where the link went', (
    tester,
  ) async {
    final seen = await pumpApi(tester, (r) async => json({'ok': true}));
    await tester.enterText(
      find.byKey(const Key('signin-email')),
      'rosa@example.com',
    );
    await tester.tap(find.text('Send me a link'));
    await tester.pumpAndSettle();
    expect(seen.single.url.path, '/api/auth/magic-link');
    expect(jsonDecode(seen.single.body), {'email': 'rosa@example.com'});
    expect(
      find.text('Link sent to rosa@example.com. Open it on this device.'),
      findsOneWidget,
    );
    // The password form is still there.
    expect(find.text('Sign in'), findsOneWidget);
  });

  testWidgets('a link request with a bad address is stopped in the page', (
    tester,
  ) async {
    final seen = await pumpApi(tester, (r) async => fail('no call expected'));
    await tester.enterText(find.byKey(const Key('signin-email')), 'nope');
    await tester.tap(find.text('Send me a link'));
    await tester.pump();
    expect(find.text('Enter your work email.'), findsOneWidget);
    expect(seen, isEmpty);
  });

  testWidgets('the real app: sign in with a password goes home', (
    tester,
  ) async {
    final h = await pumpAuthApp(
      tester,
      before: (h) => h.givePassword('p-rova', 'a purple bicycle'),
    );
    expect(h.location, '/signin');
    await tester.enterText(_user, 'rova');
    await tester.enterText(_pass, 'a purple bicycle');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(h.location, '/report');
    expect(h.auth.currentUser!.username, 'rova');
  });

  testWidgets('the real app: five wrong tries lock the name with a wait', (
    tester,
  ) async {
    await pumpAuthApp(
      tester,
      before: (h) => h.givePassword('p-rova', 'a purple bicycle'),
    );
    for (var i = 0; i < 5; i++) {
      await tester.enterText(_user, 'rova');
      await tester.enterText(_pass, 'wrong guess $i');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
      expect(find.text('Username or password is wrong.'), findsOneWidget);
    }
    await tester.enterText(_pass, 'a purple bicycle');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    expect(
      find.text('Too many sign-in attempts. Try again in 15 minutes.'),
      findsOneWidget,
    );
  });

  testWidgets('semantics: fields and the toggle have names', (tester) async {
    final handle = tester.ensureSemantics();
    await pumpApi(tester, (r) async => fail('no call expected'));
    expect(find.bySemanticsLabel('Username'), findsWidgets);
    expect(find.bySemanticsLabel('Password'), findsWidgets);
    expect(find.bySemanticsLabel('Work email'), findsWidgets);
    expect(
      tester
          .getSemantics(find.byTooltip('Show password'))
          .getSemanticsData()
          .tooltip,
      'Show password',
    );
    handle.dispose();
  });

  for (final (w, h) in [(360.0, 800.0), (800.0, 1100.0), (1500.0, 900.0)]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('no overflow at ${w}x$h, text scale $scale, with an error', (
        tester,
      ) async {
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        addTearDown(tester.platformDispatcher.clearAllTestValues);
        await pumpApi(
          tester,
          (r) async => http.Response(
            jsonEncode({
              'error': 'Too many sign-in attempts. Try again later.',
            }),
            429,
            headers: {'retry-after': '3000'},
          ),
          size: Size(w, h),
        );
        await tester.enterText(_user, 'rosa');
        await tester.enterText(_pass, 'a purple bicycle');
        await tester.tap(find.text('Sign in'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.textContaining('Try again in 50 minutes'), findsOneWidget);
      });
    }
  }
}
