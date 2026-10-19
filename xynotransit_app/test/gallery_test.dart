import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xynotransit_app/app/app.dart';
import 'package:xynotransit_app/app/providers.dart';
import 'package:xynotransit_app/data/memory_repository.dart';
import 'package:xynotransit_app/features/slides/slide_view.dart';

import 'helpers.dart';

void main() {
  setUpAll(loadAppFonts);

  testWidgets('the gallery opened directly shows slides, not a spinner', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final auth = DemoAuth(testCatalog);
    final repo = MemoryRepository(
      catalog: testCatalog,
      currentUser: () => auth.currentUser ?? DemoAuth.controller,
      withDemoReports: true,
    );
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final c = ProviderContainer(
      overrides: [
        prefsProvider.overrideWithValue(prefs),
        repositoryProvider.overrideWithValue(repo),
        authServiceProvider.overrideWithValue(auth),
        initialStartProvider.overrideWithValue(MemoryRepository.demoStart),
      ],
    );
    addTearDown(c.dispose);
    // The gallery is the first and only page, as when its link is opened.
    c.read(routerProvider).go('/gallery');
    await tester.pumpWidget(
      UncontrolledProviderScope(container: c, child: const XynotransitApp()),
    );
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(seconds: 2));
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byType(SlideStage), findsWidgets);
  });
}
