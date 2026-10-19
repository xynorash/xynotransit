import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xynotransit_app/data/memory_repository.dart';
import 'package:xynotransit_app/data/repository.dart';
import 'package:xynotransit_app/domain/deck.dart';
import 'package:xynotransit_app/domain/deck_text.dart';
import 'package:xynotransit_app/domain/enums.dart';
import 'package:xynotransit_app/domain/report.dart';
import 'package:xynotransit_app/domain/snapshot.dart';
import 'package:xynotransit_app/features/employee/live_preview.dart';
import 'package:xynotransit_app/features/slides/slide_view.dart';

import 'faithful_test.dart' show compare, previewPixels;
import 'helpers.dart';

/// A complete draft for the Rova seat, with the reporter's own words.
Report completeDraft(String periodId) {
  final a = testCatalog.assignmentByCode('rova')!;
  return Report(
    periodId: periodId,
    assignmentId: a.id,
    values: {
      for (final m in a.metrics) m.id: [1200, 3400000, 999999999],
    },
    kpis: {
      for (final (i, k) in a.kpis.indexed)
        k.id: KpiResult(KpiStatus.values[i % KpiStatus.values.length]),
    },
    notes: {
      NoteKind.well: ['Customs backlog cleared'],
      NoteKind.wrong: ['Two late containers', 'Port strike'],
      NoteKind.next: ['Hire a second clerk'],
    },
    reporter: const Reporter(
      name: 'Rova R.',
      country: 'Kenya',
      role: 'Import lead',
    ),
  );
}

void main() {
  setUpAll(loadAppFonts);

  final texts = DeckTexts.defaults
      .withValue('kpiTitle', 'About {name} in {team}')
      .withValue('footer', '{title} / {team}');

  test('the preview shows the two slides, KPI first, then results', () {
    final a = testCatalog.assignmentByCode('rova')!;
    final snap = buildDraftSnapshot(
      completeDraft(testPeriod.id),
      a,
      testCatalog,
      testPeriod,
    );
    final slides = previewSlides(snapshot: snap, texts: texts);
    expect(slides[0], isA<KpiSlideSpec>());
    expect(slides[1], isA<ResultsSlideSpec>());
    expect(snap.name, 'Rova R.');
    expect(snap.team, 'Kenya');
    expect(snap.role, 'Import lead');
  });

  test('an empty draft shows targets as not answered and numbers as 0', () {
    final a = testCatalog.assignmentByCode('rova')!;
    final snap = buildDraftSnapshot(
      Report(periodId: testPeriod.id, assignmentId: a.id),
      a,
      testCatalog,
      testPeriod,
    );
    expect(snap.targets.every((t) => t.status == null), isTrue);
    expect(snap.metrics.every((m) => m.total == 0), isTrue);
  });

  testWidgets('the preview slides equal the slides of the generated deck', (
    tester,
  ) async {
    const user = AppUser(
      personId: null,
      role: AppRole.controller,
      label: 'Manager',
    );
    final repo = MemoryRepository(
      catalog: testCatalog,
      currentUser: () => user,
    );
    final period = await repo.ensurePeriod(MemoryRepository.demoStart);
    await repo.saveDeckTexts(period.id, texts);
    final draft = completeDraft(period.id);
    await repo.sendReport(draft);
    final run = await repo.generateDeck(period, testCatalog);
    final deck = buildDeck(run, period);
    final deckKpi = deck.whereType<KpiSlideSpec>().single;
    final deckResults = deck.whereType<ResultsSlideSpec>().single;

    final a = testCatalog.assignmentById(draft.assignmentId)!;
    final live = previewSlides(
      snapshot: buildDraftSnapshot(draft, a, testCatalog, period),
      texts: (await repo.loadDeckTexts(period.id)).texts,
    );
    // Same data first, then the same pixels (within the faithful tolerance).
    expect(
      (live[0] as KpiSlideSpec).snapshot.toJson(),
      deckKpi.snapshot.toJson(),
    );
    expect(
      (live[1] as ResultsSlideSpec).snapshot.toJson(),
      deckResults.snapshot.toJson(),
    );
    for (final (live, sent) in [(live[0], deckKpi), (live[1], deckResults)]) {
      final x = await previewPixels(tester, live);
      final y = await previewPixels(tester, sent);
      final d = compare(x, _asExport(y));
      expect(d.pixels, lessThanOrEqualTo(1000), reason: '$d');
      expect(d.maxDelta, lessThanOrEqualTo(24), reason: '$d');
    }
  }, timeout: const Timeout(Duration(minutes: 2)));

  testWidgets('an unanswered target reads NOT ANSWERED on the slide', (
    tester,
  ) async {
    final a = testCatalog.assignmentByCode('rova')!;
    final snap = buildDraftSnapshot(
      Report(periodId: testPeriod.id, assignmentId: a.id),
      a,
      testCatalog,
      testPeriod,
    );
    await pumpSlide(tester, slideFor(KpiSlideSpec(snap)));
    expect(find.textContaining('NOT ANSWERED'), findsWidgets);
  });
}

/// previewPixels returns the 1922 x 1082 stage; compare() wants the inner
/// 1920 x 1080 as the second picture.
Uint8List _asExport(Uint8List stage) {
  const pw = 1922;
  final out = List<int>.filled(1920 * 1080 * 4, 0);
  for (var y = 0; y < 1080; y++) {
    for (var x = 0; x < 1920; x++) {
      final a = ((y + 1) * pw + x + 1) * 4;
      final b = (y * 1920 + x) * 4;
      for (var c = 0; c < 4; c++) {
        out[b + c] = stage[a + c];
      }
    }
  }
  return Uint8List.fromList(out);
}
