import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xynotransit_app/app/providers.dart';
import 'package:xynotransit_app/core/theme/theme.dart';
import 'package:xynotransit_app/data/api/api_auth.dart';
import 'package:xynotransit_app/data/api/api_client.dart';
import 'package:xynotransit_app/data/memory_repository.dart';
import 'package:xynotransit_app/features/verify_screen.dart';

import 'api_client_test.dart' show json;

Future<void> pump(
  WidgetTester tester,
  MockClientHandler h,
  String? token,
) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final auth = ApiAuthService(
    ApiClient(
      baseUrl: '/api',
      tokens: TokenStore(prefs),
      client: MockClient(h),
    ),
  );
  final router = GoRouter(
    initialLocation: '/auth/verify',
    routes: [
      GoRoute(
        path: '/auth/verify',
        builder: (_, _) => VerifyScreen(token: token),
      ),
      GoRoute(path: '/', builder: (_, _) => const Text('HOME')),
      GoRoute(path: '/signin', builder: (_, _) => const Text('SIGNIN')),
    ],
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        authServiceProvider.overrideWithValue(auth),
        repositoryProvider.overrideWithValue(
          MemoryRepository(currentUser: () => throw UnimplementedError()),
        ),
        prefsProvider.overrideWithValue(prefs),
      ],
      child: MaterialApp.router(
        theme: buildTheme(Brightness.light),
        routerConfig: router,
      ),
    ),
  );
}

void main() {
  testWidgets('good link: signed in, then home', (tester) async {
    await pump(tester, (r) async {
      return json({
        'access_token': 'j',
        'expires_at': '2026-10-25T00:00:00Z',
        'user': {'person_id': 'p1', 'role': 'contributor', 'label': 'Mina'},
      });
    }, 'abc');
    await tester.pump();
    await tester.pump();
    expect(find.text('You are signed in'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(find.text('HOME'), findsOneWidget);
  });

  testWidgets('expired link: plain words and a way back', (tester) async {
    const words =
        'This link has expired or was already used. Ask for a new one.';
    await pump(tester, (r) async => json({'error': words}, 401), 'abc');
    await tester.pumpAndSettle();
    expect(find.text('This link does not work'), findsOneWidget);
    expect(find.text(words), findsOneWidget);
    await tester.tap(find.text('Back to sign in'));
    await tester.pumpAndSettle();
    expect(find.text('SIGNIN'), findsOneWidget);
  });

  testWidgets('missing token reads as an expired link', (tester) async {
    await pump(tester, (r) async => fail('no call expected'), null);
    await tester.pumpAndSettle();
    expect(find.text('This link does not work'), findsOneWidget);
  });

  testWidgets('no connection offers a retry', (tester) async {
    await pump(tester, (r) async => throw http.ClientException('x'), 'abc');
    await tester.pumpAndSettle();
    expect(find.text('No connection'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
  });
}
