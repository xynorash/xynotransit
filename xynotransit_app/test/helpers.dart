import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xynotransit_app/core/theme/theme.dart';
import 'package:xynotransit_app/data/demo_data.dart';
import 'package:xynotransit_app/data/seed_data.dart';
import 'package:xynotransit_app/domain/catalog.dart';
import 'package:xynotransit_app/domain/period.dart';
import 'package:xynotransit_app/domain/snapshot.dart';

/// Loads the bundled fonts so tests and goldens draw real glyphs, not boxes.
Future<void> loadAppFonts() async {
  Future<void> load(String family, List<String> files) async {
    final loader = FontLoader(family);
    for (final f in files) {
      final bytes = File('assets/fonts/$f').readAsBytesSync();
      loader.addFont(Future.value(ByteData.view(bytes.buffer)));
    }
    await loader.load();
  }

  await load('DM Sans', [
    'DMSans-Regular.ttf',
    'DMSans-Medium.ttf',
    'DMSans-Bold.ttf',
  ]);
  await load('IBM Plex Mono', [
    'IBMPlexMono-Regular.ttf',
    'IBMPlexMono-Medium.ttf',
  ]);
}

final testCatalog = buildSeedCatalog();
final testPeriod = Period(
  id: 'p',
  startMonth: DateTime(2026, 2),
  meetingDate: DateTime(2026, 6, 9),
);

/// Snapshot of the demo report of [code].
ReportSnapshot demoSnapshot(String code) {
  final a = testCatalog.assignmentByCode(code)!;
  final r = buildDemoReports(
    testCatalog,
    testPeriod.id,
  ).firstWhere((r) => r.assignmentId == a.id);
  return ReportSnapshot.build(
    report: r,
    assignment: a,
    catalog: testCatalog,
    period: testPeriod,
  );
}

Catalog get catalog => testCatalog;

/// Sizes the test view to the slide and pumps [slide] on a plain app.
Future<void> pumpSlide(WidgetTester tester, Widget slide) async {
  tester.view.physicalSize = const Size(1920, 1080);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light),
      home: Align(
        alignment: Alignment.topLeft,
        child: RepaintBoundary(child: slide),
      ),
    ),
  );
  await tester.pump();
}
