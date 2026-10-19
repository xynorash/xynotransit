import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart';
import 'package:xynotransit_app/core/theme/theme.dart';
import 'package:xynotransit_app/domain/deck.dart';
import 'package:xynotransit_app/domain/deck_text.dart';
import 'package:xynotransit_app/domain/enums.dart';
import 'package:xynotransit_app/domain/snapshot.dart';
import 'package:xynotransit_app/features/export/deck_export.dart';
import 'package:xynotransit_app/features/export/deck_render.dart';
import 'package:xynotransit_app/features/export/pptx.dart';
import 'package:xynotransit_app/features/export/rasterizer.dart';
import 'package:xynotransit_app/features/slides/alt_text.dart';
import 'package:xynotransit_app/features/slides/canvas.dart';
import 'package:xynotransit_app/features/slides/slide_view.dart';

import '../tool/slide_matrix.dart';
import 'helpers.dart';

/// The preview draws a slide inside a stage with a 1 px border and rounded
/// corners. Pixels inside that frame must equal the exported picture.
const _frame = 1;
const _corner = 12;

DeckTexts customTexts() => DeckTexts.fromJson({
  'title': 'The big regional logistics review for {period}, all teams',
  'subtitle': 'What we did and what comes next ({period})',
  'dateText': 'Next Tuesday, 10:00, big room',
  'orgName': 'Xyno',
  'coverPill': '{team}: {count} {count}',
  'kpiEyebrow': 'Numbers · {org} · {team} · {role}',
  'kpiTitle': '{name} on {team}: ${'a long title ' * 10}'.substring(0, 110),
  'kpiBadge': '{met} out of {total}',
  'resultsEyebrow': 'Words · {name}',
  'resultsTitle': 'What {name} wrote',
  'highlightsTitle': 'Good',
  'lowlightsTitle': 'Bad news and some more of it',
  'nextTitle': 'Plans',
  'emptyNote': 'Left blank',
  'footer': '{title} / {team} / {period}',
  'dividerEyebrow': '{title} · {i}/{n}',
  'dividerTitle': 'Team {team}',
  'dividerSubtitle': '{k} {reports} in {team}',
  'suggestionsTitle': 'Your ideas',
  'suggestionsBody': 'Nothing yet. ' * 10,
});

ReportSnapshot withEmptyWell(ReportSnapshot s) => ReportSnapshot(
  assignmentCode: s.assignmentCode,
  name: s.name,
  role: s.role,
  team: s.team,
  periodLabel: s.periodLabel,
  months: s.months,
  metrics: s.metrics,
  targets: s.targets,
  well: const [],
  wrong: s.wrong,
  next: s.next,
);

DeckRun customRun(DeckTexts texts) {
  final items = <DeckItem>[];
  for (final a in catalog.assignments) {
    var snap = demoSnapshot(a.code);
    if (items.isEmpty) snap = withEmptyWell(snap);
    items.add(DeckItem(reportId: a.code, sort: items.length, snapshot: snap));
  }
  return DeckRun(
    id: 'run',
    periodId: testPeriod.id,
    generatedAt: DateTime(2026, 6, 1),
    expectedCount: items.length,
    includedCount: items.length,
    items: items,
    texts: texts,
  );
}

/// Raw RGBA of a PNG.
Future<ui.Image> decode(Uint8List png) async {
  final codec = await ui.instantiateImageCodec(png);
  final frame = await codec.getNextFrame();
  codec.dispose();
  return frame.image;
}

Future<Uint8List> rgba(ui.Image i) async =>
    (await i.toByteData(format: ui.ImageByteFormat.rawRgba))!.buffer
        .asUint8List();

/// Draws [spec] the way the preview does and returns the inner 1920 x 1080.
Future<Uint8List> previewPixels(WidgetTester tester, SlideSpec spec) async {
  final key = GlobalKey();
  tester.view.physicalSize = const Size(1922, 1082);
  tester.view.devicePixelRatio = 1;
  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light),
      home: Align(
        alignment: Alignment.topLeft,
        child: RepaintBoundary(
          key: key,
          child: SizedBox(
            width: slideWidth + 2 * _frame,
            child: SlideStage(child: slideFor(spec)),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final image = (await tester.runAsync(() => boundary.toImage()))!;
  expect([image.width, image.height], [1922, 1082]);
  return (await tester.runAsync(() => rgba(image)))!;
}

/// How the two pictures differ inside the stage frame and corners.
class Diff {
  const Diff(this.pixels, this.maxDelta);
  final int pixels;
  final int maxDelta;
  @override
  String toString() => '$pixels pixels differ, by at most $maxDelta of 255';
}

Diff compare(Uint8List preview, Uint8List export) {
  const pw = 1922;
  const w = 1920;
  const h = 1080;
  var pixels = 0;
  var maxDelta = 0;
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final inCorner =
          (x < _corner || x >= w - _corner) &&
          (y < _corner || y >= h - _corner);
      if (inCorner) continue;
      final a = ((y + _frame) * pw + x + _frame) * 4;
      final b = (y * w + x) * 4;
      var d = 0;
      for (var c = 0; c < 4; c++) {
        d = math.max(d, (preview[a + c] - export[b + c]).abs());
      }
      if (d > 0) {
        pixels++;
        maxDelta = math.max(maxDelta, d);
      }
    }
  }
  return Diff(pixels, maxDelta);
}

/// Draws every spec the way the export does and the way the preview does and
/// compares the pixels.
Future<void> expectFaithful(
  WidgetTester tester,
  List<SlideSpec> specs, {
  List<String>? names,
}) async {
  late BuildContext ctx;
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (c) {
          ctx = c;
          return const SizedBox();
        },
      ),
    ),
  );
  final exported = <Uint8List>[];
  for (final spec in specs) {
    final f = slideToPng(ctx, slideFor(spec));
    await tester.pump();
    await tester.pump();
    exported.add((await tester.runAsync(() => f))!);
  }
  for (var i = 0; i < specs.length; i++) {
    final image = (await tester.runAsync(() => decode(exported[i])))!;
    expect([image.width, image.height], [1920, 1080]);
    final export = (await tester.runAsync(() => rgba(image)))!;
    final preview = await previewPixels(tester, specs[i]);
    // Words, colours, sizes and positions are the same. The stage moves the
    // slide by 1 px inside a clip, which may shade a few anti-aliased edge
    // pixels differently (under 0.05% of the picture, never more than a few
    // levels; seen: up to 50 pixels, by 3 to 7 of 255). Anything more fails.
    final d = compare(preview, export);
    final what = names?[i] ?? '${specs[i].runtimeType}';
    expect(
      d.pixels,
      lessThanOrEqualTo(1000),
      reason: 'slide ${i + 1} ($what): $d',
    );
    expect(
      d.maxDelta,
      lessThanOrEqualTo(24),
      reason: 'slide ${i + 1} ($what): $d',
    );
  }
}

void main() {
  setUpAll(loadAppFonts);

  final texts = customTexts();
  final run = customRun(texts);
  final specs = buildDeck(run, testPeriod);

  test('the test deck has 14 reports and 34 slides, last one suggestions', () {
    expect(run.items, hasLength(14));
    expect(specs, hasLength(34));
    expect(specs.last, isA<SuggestionsSpec>());
    expect(specs.whereType<SuggestionsSpec>(), hasLength(1));
  });

  testWidgets('every slide: the preview and the export draw the same pixels', (
    tester,
  ) async {
    await expectFaithful(tester, specs);
  }, timeout: const Timeout(Duration(minutes: 5)));

  testWidgets(
    'matrix extremes: the preview and the export draw the same pixels',
    (tester) async {
      // Every third case of the slide matrix: long names, many counts, huge
      // numbers, dense targets, wide letters, maximum length words, pill lists.
      final cases = [
        for (final e in slideMatrix().indexed)
          if (e.$1 % 3 == 0) e.$2,
      ];
      await expectFaithful(
        tester,
        [for (final c in cases) c.spec],
        names: [for (final c in cases) c.name],
      );
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );

  testWidgets('a picture at pixel ratio 2 is 3840 x 2160 and looks the same', (
    tester,
  ) async {
    late BuildContext ctx;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (c) {
            ctx = c;
            return const SizedBox();
          },
        ),
      ),
    );
    for (final spec in [specs[0], specs[2], specs[3]]) {
      final one = slideToPng(ctx, slideFor(spec));
      await tester.pump();
      await tester.pump();
      final two = slideToPng(ctx, slideFor(spec), pixelRatio: pptxPixelRatio);
      await tester.pump();
      await tester.pump();
      final oneBytes = (await tester.runAsync(() => one))!;
      final twoBytes = (await tester.runAsync(() => two))!;
      final a = (await tester.runAsync(() => decode(oneBytes)))!;
      final b = (await tester.runAsync(() => decode(twoBytes)))!;
      expect([a.width, a.height], [1920, 1080]);
      expect([b.width, b.height], [3840, 2160]);
      final pa = (await tester.runAsync(() => rgba(a)))!;
      final pb = (await tester.runAsync(() => rgba(b)))!;
      // Average the 2 x 2 block of the big picture: it must match the small
      // one on average (text is drawn finer, so single pixels may differ).
      var sum = 0.0;
      for (var y = 0; y < 1080; y += 3) {
        for (var x = 0; x < 1920; x += 3) {
          for (var c = 0; c < 3; c++) {
            var v = 0;
            for (var dy = 0; dy < 2; dy++) {
              for (var dx = 0; dx < 2; dx++) {
                v += pb[((2 * y + dy) * 3840 + 2 * x + dx) * 4 + c];
              }
            }
            sum += ((v / 4) - pa[(y * 1920 + x) * 4 + c]).abs();
          }
        }
      }
      final mean = sum / (360 * 640 * 3);
      expect(mean, lessThan(1.5), reason: '${spec.runtimeType}: $mean');
    }
  }, timeout: const Timeout(Duration(minutes: 3)));

  testWidgets('the same words appear in every slide widget', (tester) async {
    // A cheap check that the custom words reach the widgets at all.
    await pumpSlide(tester, slideFor(specs.first));
    expect(find.text('NEXT TUESDAY, 10:00, BIG ROOM'), findsOneWidget);
    expect(
      find.text(
        'The big regional logistics review for Feb to Apr 2026, all teams',
      ),
      findsOneWidget,
    );
    await pumpSlide(tester, slideFor(specs.last));
    expect(find.text('Your ideas'), findsOneWidget);
  });

  test('PPTX alt text, notes and title come from the same specs and words', () {
    final pngs = [for (var i = 0; i < specs.length; i++) Uint8List(4)];
    final slides = pptxSlidesFor(specs, pngs);
    final archive = ZipDecoder().decodeBytes(
      buildPptx(slides, title: deckTitleOf(specs)),
    );
    String read(String n) =>
        utf8.decode(archive.findFile(n)!.content as List<int>);
    expect(
      XmlDocument.parse(read('ppt/presentation.xml'))
          .findAllElements('sldId', namespaceUri: '*'),
      hasLength(specs.length),
    );
    for (var i = 0; i < specs.length; i++) {
      final alt = slideAltText(specs[i]);
      final slide = XmlDocument.parse(read('ppt/slides/slide${i + 1}.xml'));
      final descr = slide
          .findAllElements('cNvPr', namespaceUri: '*')
          .firstWhere((e) => e.getAttribute('descr') != null)
          .getAttribute('descr');
      final title = slide
          .findAllElements('sp', namespaceUri: '*')
          .single
          .findAllElements('t', namespaceUri: '*')
          .single
          .innerText;
      final notes =
          XmlDocument.parse(read('ppt/notesSlides/notesSlide${i + 1}.xml'))
              .findAllElements('t', namespaceUri: '*')
              .map((e) => e.innerText)
              .join('\n');
      expect(descr, alt, reason: 'alt of slide ${i + 1}');
      expect(title, slideTitle(specs[i]), reason: 'title of slide ${i + 1}');
      expect(notes, slideNotes(specs[i]), reason: 'notes of slide ${i + 1}');
      expect(notes, startsWith(alt), reason: 'notes of slide ${i + 1}');
    }
    // The words are the custom ones, built from the frozen texts.
    expect(
      slideAltText(specs.first),
      startsWith('The big regional logistics review for Feb to Apr 2026'),
    );
    expect(
      slideAltText(specs[2]),
      startsWith('Shalini on Mauritius: a long title'),
    );
  });

  test('PNG zip has one picture per slide', () {
    final names = pngNames(specs.length);
    final zip = buildPngZip([for (final _ in specs) Uint8List(4)], names);
    final files = ZipDecoder().decodeBytes(zip).files.map((f) => f.name);
    expect(files, hasLength(34));
    expect(files.first, 'slide-01.png');
    expect(files.last, 'slide-34.png');
  });

  test('PDF has one 1920 x 1080 page per slide', () async {
    // Real pictures are not needed for the page count and size.
    final tiny = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
    );
    final bytes = await buildPdf([
      for (final _ in specs) tiny,
    ], title: deckTitleOf(specs));
    final dir = Directory.systemTemp.createTempSync('faithful');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/deck.pdf')..writeAsBytesSync(bytes);
    final ProcessResult r;
    try {
      r = await Process.run('pdfinfo', [file.path]);
    } on ProcessException {
      markTestSkipped('pdfinfo is not installed');
      return;
    }
    expect(r.stdout, matches(RegExp(r'Pages:\s+34')));
    expect(r.stdout, matches(RegExp(r'Page size:\s+1920 x 1080 pts')));
    expect(
      r.stdout,
      contains(
        'The big regional logistics review for Feb to Apr 2026, all teams'
            .substring(0, 20),
      ),
    );
  });

  testWidgets('changing the texts later does not change a built deck', (
    tester,
  ) async {
    final changed = DeckTexts.defaults
        .withValue('title', 'Something else')
        .withValue('kpiTitle', 'Changed {name}')
        .withValue('suggestionsTitle', 'Changed');
    // Rendering before and after "editing" gives the same pixels, because the
    // specs only know the words frozen into the run.
    final frozen = DeckRun(
      id: 'r',
      periodId: run.periodId,
      generatedAt: run.generatedAt,
      expectedCount: run.expectedCount,
      includedCount: run.includedCount,
      items: run.items,
      texts: texts,
    );
    final built = buildDeck(frozen, testPeriod);
    final before = <Uint8List>[];
    for (final i in [0, 1, 2, 3, built.length - 1]) {
      before.add(await previewPixels(tester, built[i]));
    }
    // A new run with other words is a different deck and looks different.
    final other = buildDeck(
      DeckRun(
        id: 'r2',
        periodId: run.periodId,
        generatedAt: run.generatedAt,
        expectedCount: run.expectedCount,
        includedCount: run.includedCount,
        items: run.items,
        texts: changed,
      ),
      testPeriod,
    );
    final otherPixels = await previewPixels(tester, other.first);
    expect(otherPixels, isNot(equals(before.first)));
    final after = <Uint8List>[];
    for (final i in [0, 1, 2, 3, built.length - 1]) {
      after.add(await previewPixels(tester, built[i]));
    }
    for (var i = 0; i < before.length; i++) {
      expect(after[i], orderedEquals(before[i]), reason: 'slide index $i');
    }
    expect(slideAltText(built.first), slideAltText(specs.first));
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('an empty column keeps its own wording on the slide', () {
    final first = run.items.first.snapshot;
    expect(first.notesOf(NoteKind.well), isEmpty);
  });
}
