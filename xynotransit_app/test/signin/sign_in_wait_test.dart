import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xynotransit_app/app/providers.dart';
import 'package:xynotransit_app/core/theme/theme.dart';
import 'package:xynotransit_app/data/api/api_client.dart';
import 'package:xynotransit_app/data/repository.dart';
import 'package:xynotransit_app/features/sign_in_screen.dart';

import '../helpers.dart';

/// Refuses every sign-in with the answer of a real 429.
class _RateLimited implements AuthService {
  _RateLimited(this.body, this.retryAfter);
  final String body;
  final String? retryAfter;

  @override
  AppUser? get currentUser => null;
  @override
  bool get needsSignIn => true;
  @override
  Stream<AppUser?> get userChanges => const Stream.empty();
  @override
  Future<void> signOut() async {}
  @override
  Future<void> signInWithEmail(String email) async =>
      throw errorFromResponse(429, body, retryAfter: retryAfter);
}

Future<void> trySignIn(WidgetTester tester, AuthService auth) async {
  tester.view.physicalSize = const Size(800, 800);
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
  await tester.enterText(find.byType(TextField), 'shalini@xynotransit.example');
  await tester.tap(find.text('Send me a link'));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(loadAppFonts);

  testWidgets('a 429 with Retry-After says when to try again', (tester) async {
    await trySignIn(
      tester,
      _RateLimited(
        '{"error":"Too many sign-in links. Try again later."}',
        '720',
      ),
    );
    expect(
      find.text('Too many sign-in links. Try again in 12 minutes.'),
      findsOneWidget,
    );
    expect(find.textContaining('later'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a 429 without the header keeps the server words', (
    tester,
  ) async {
    await trySignIn(
      tester,
      _RateLimited(
        '{"error":"Too many sign-in links. Try again later."}',
        null,
      ),
    );
    expect(
      find.text('Too many sign-in links. Try again later.'),
      findsOneWidget,
    );
  });
}
