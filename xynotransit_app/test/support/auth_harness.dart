import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xynotransit_app/app/app.dart';
import 'package:xynotransit_app/app/providers.dart';
import 'package:xynotransit_app/data/memory_repository.dart';
import 'package:xynotransit_app/data/repository.dart';
import 'package:xynotransit_app/data/seed_data.dart';

/// The app on the in-memory backend with the real sign-in (or the demo
/// switcher), for the password screens.
class AuthHarness {
  AuthHarness(this.repo, this.auth, this.container, this.clock);
  final MemoryRepository repo;
  final DemoAuth auth;
  final ProviderContainer container;
  final Clock clock;

  String get location => container
      .read(routerProvider)
      .routerDelegate
      .currentConfiguration
      .last
      .matchedLocation;

  /// Gives a person a password the way a manager and the person would: a
  /// reset, then the person chooses their own.
  Future<void> givePassword(String? personId, String password) async {
    final who = personId;
    if (who == null) {
      final s = repo.sessionFor(null);
      repo.changePasswordOf(s, newPassword: password);
      return;
    }
    final temp = await repo.resetPassword(who);
    repo.changePasswordOf(
      repo.sessionFor(who),
      currentPassword: temp.password,
      newPassword: password,
    );
  }
}

class Clock {
  DateTime now = DateTime(2026, 6, 1, 9);
  void advance(Duration d) => now = now.add(d);
}

/// Pumps the app. [requireSignIn] starts signed out on /signin; otherwise
/// it is the demo (signed in as the manager, or as [user]).
Future<AuthHarness> pumpAuthApp(
  WidgetTester tester, {
  bool requireSignIn = true,
  AppUser? user,
  Size size = const Size(1000, 1100),
  double textScale = 1.0,
  Brightness brightness = Brightness.light,
  String location = '/',
  Future<void> Function(AuthHarness h)? before,
}) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final catalog = buildSeedCatalog();
  final auth = DemoAuth(catalog, requireSignIn: requireSignIn);
  final clock = Clock();
  late final MemoryRepository repo;
  repo = MemoryRepository(
    catalog: catalog,
    currentUser: () => auth.currentUser ?? repo.sessionFor(null),
    clock: () => clock.now,
  );
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  tester.platformDispatcher.platformBrightnessTestValue = brightness;
  addTearDown(() {
    tester.view.reset();
    tester.platformDispatcher.clearAllTestValues();
  });
  final container = ProviderContainer(
    overrides: [
      prefsProvider.overrideWithValue(prefs),
      repositoryProvider.overrideWithValue(repo),
      authServiceProvider.overrideWithValue(auth),
      initialStartProvider.overrideWithValue(MemoryRepository.demoStart),
    ],
  );
  addTearDown(container.dispose);
  final h = AuthHarness(repo, auth, container, clock);
  if (before != null) await before(h);
  if (user != null) auth.actAs(user);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const XynotransitApp(),
    ),
  );
  await tester.pumpAndSettle();
  if (location != '/') {
    container.read(routerProvider).go(location);
    await tester.pumpAndSettle();
  }
  return h;
}
