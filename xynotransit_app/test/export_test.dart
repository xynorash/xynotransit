import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart';
import 'package:xynotransit_app/core/format.dart';
import 'package:xynotransit_app/domain/deck.dart';
import 'package:xynotransit_app/domain/deck_text.dart';
import 'package:xynotransit_app/domain/period.dart';
import 'package:xynotransit_app/domain/snapshot.dart';
import 'package:xynotransit_app/features/export/deck_export.dart';
import 'package:xynotransit_app/features/export/deck_render.dart';
import 'package:xynotransit_app/features/export/pptx.dart';
import 'package:xynotransit_app/features/export/rasterizer.dart';
import 'package:xynotransit_app/features/slides/alt_text.dart';
import 'package:xynotransit_app/features/slides/canvas.dart';
import 'package:xynotransit_app/features/slides/kpi_slide.dart';

import 'helpers.dart';

/// 1x1 transparent PNG.
final tinyPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
);

void main() {
  setUpAll(loadAppFonts);

  group('PPTX', () {
    final slides = [
      for (var i = 0; i < 3; i++)
        PptxSlide(
          png: Uint8List.fromList(tinyPng),
          altText: 'Alt $i & <more>',
          notes: 'Notes "$i"',
        ),
    ];
    final archive = ZipDecoder().decodeBytes(buildPptx(slides));
    String read(String name) =>
        utf8.decode(archive.findFile(name)!.content as List<int>);

    test('is a zip with every part and every part is well formed XML', () {
      final names = archive.files.map((f) => f.name).toSet();
      for (final n in [
        '[Content_Types].xml',
        '_rels/.rels',
        'ppt/presentation.xml',
        'ppt/_rels/presentation.xml.rels',
        'ppt/slideMasters/slideMaster1.xml',
        'ppt/slideLayouts/slideLayout1.xml',
        'ppt/notesMasters/notesMaster1.xml',
        'ppt/theme/theme1.xml',
        'ppt/theme/theme2.xml',
        for (var i = 1; i <= 3; i++) ...[
          'ppt/slides/slide$i.xml',
          'ppt/slides/_rels/slide$i.xml.rels',
          'ppt/notesSlides/notesSlide$i.xml',
          'ppt/media/image$i.png',
        ],
      ]) {
        expect(names, contains(n));
      }
      for (final f in archive.files.where(
        (f) => f.name.endsWith('.xml') || f.name.endsWith('.rels'),
      )) {
        expect(
          () => XmlDocument.parse(utf8.decode(f.content as List<int>)),
          returnsNormally,
          reason: f.name,
        );
      }
    });

    test('slide size is widescreen 12192000 x 6858000', () {
      final doc = XmlDocument.parse(read('ppt/presentation.xml'));
      final sz = doc.findAllElements('sldSz', namespaceUri: '*').single;
      expect(sz.getAttribute('cx'), '12192000');
      expect(sz.getAttribute('cy'), '6858000');
      expect(doc.findAllElements('sldId', namespaceUri: '*'), hasLength(3));
    });

    test(
      'every relationship target exists and every part has a content type',
      () {
        final names = archive.files.map((f) => f.name).toSet();
        for (final relFile in names.where((n) => n.endsWith('.rels'))) {
          final base = relFile.contains('/_rels/')
              ? relFile.split('/_rels/').first
              : '';
          final doc = XmlDocument.parse(read(relFile));
          for (final r in doc.findAllElements('Relationship')) {
            final target = r.getAttribute('Target')!;
            final path = Uri.parse('${base.isEmpty ? '' : '$base/'}$target')
                .normalizePath()
                .path;
            expect(names, contains(path), reason: '$relFile -> $target');
          }
        }
        final types = XmlDocument.parse(read('[Content_Types].xml'));
        final defaults = types
            .findAllElements('Default')
            .map((e) => e.getAttribute('Extension'))
            .toSet();
        final overrides = types
            .findAllElements('Override')
            .map((e) => e.getAttribute('PartName'))
            .toSet();
        for (final n in names.where((n) => n != '[Content_Types].xml')) {
          final ext = n.split('.').last;
          expect(
            defaults.contains(ext) || overrides.contains('/$n'),
            isTrue,
            reason: n,
          );
        }
      },
    );

    test('pictures are full bleed with alt text, notes carry the words', () {
      final slide = XmlDocument.parse(read('ppt/slides/slide2.xml'));
      final pic = slide
          .findAllElements('cNvPr', namespaceUri: '*')
          .firstWhere((e) => e.getAttribute('descr') != null);
      expect(pic.getAttribute('descr'), 'Alt 1 & <more>');
      final ext = slide
          .findAllElements('ext', namespaceUri: '*')
          .firstWhere((e) => e.getAttribute('cx') != '0');
      expect(
        [ext.getAttribute('cx'), ext.getAttribute('cy')],
        ['12192000', '6858000'],
      );
      final notes = XmlDocument.parse(read('ppt/notesSlides/notesSlide2.xml'));
      expect(
        notes.findAllElements('t', namespaceUri: '*').single.innerText,
        'Notes "1"',
      );
    });
  });

  test('PDF has one 1920 x 1080 page per slide', () async {
    final bytes = await buildPdf([
      tinyPng,
      tinyPng,
      tinyPng,
      tinyPng,
    ], title: 'T');
    expect(latin1.decode(bytes.sublist(0, 5)), '%PDF-');
    final file = File(
      '${Directory.systemTemp.createTempSync('pdf').path}/deck.pdf',
    )..writeAsBytesSync(bytes);
    final ProcessResult r;
    try {
      r = await Process.run('pdfinfo', [file.path]);
    } on ProcessException {
      markTestSkipped('pdfinfo is not installed');
      return;
    }
    expect(r.stdout, matches(RegExp(r'Pages:\s+4')));
    expect(r.stdout, matches(RegExp(r'Page size:\s+1920 x 1080 pts')));
  });

  group('PDF text layer', () {
    const notes = [
      'Cover. Xynotransit Regional Logistics Meeting, Feb to Apr 2026.',
      'Hanitra Rakoto: KPI and volumes.\nTargets:\n1. Deliver on time: met.',
      'Zoé Ñandú: highlights. Delays down by a third.',
    ];

    Future<String> pdftext(
      Uint8List bytes,
      List<String> args, {
      List<String> after = const [],
    }) async {
      final dir = Directory.systemTemp.createTempSync('pdftext');
      addTearDown(() => dir.deleteSync(recursive: true));
      final f = File('${dir.path}/deck.pdf')..writeAsBytesSync(bytes);
      final r = await Process.run(args.first, [
        ...args.skip(1),
        f.path,
        ...after,
      ]);
      return r.stdout as String;
    }

    test('every page carries its speaker notes as searchable text', () async {
      final bytes = await buildPdf(
        [tinyPng, tinyPng, tinyPng],
        title: 'T',
        notes: notes,
      );
      for (var i = 0; i < notes.length; i++) {
        final text = await pdftext(
          bytes,
          ['pdftotext', '-f', '${i + 1}', '-l', '${i + 1}'],
          after: ['-'],
        );
        final flat = text.replaceAll(RegExp(r'\s+'), ' ');
        for (final line in notes[i].split('\n')) {
          expect(flat, contains(line.replaceAll(RegExp(r'\s+'), ' ')));
        }
        // And only its own page's words.
        for (var j = 0; j < notes.length; j++) {
          if (j != i) expect(flat, isNot(contains(notes[j].split('\n').first)));
        }
      }
    });

    test('the text is invisible: the page looks the same without it', () async {
      Future<Uint8List> raster(List<String>? n) async {
        final bytes = await buildPdf([tinyPng], title: 'T', notes: n);
        final dir = Directory.systemTemp.createTempSync('pdfraster');
        addTearDown(() => dir.deleteSync(recursive: true));
        final f = File('${dir.path}/deck.pdf')..writeAsBytesSync(bytes);
        final r = await Process.run('pdftoppm', [
          '-r',
          '12',
          '-png',
          f.path,
          '${dir.path}/p',
        ]);
        expect(r.exitCode, 0, reason: '${r.stderr}');
        return File(
          dir.listSync().firstWhere((e) => e.path.endsWith('.png')).path,
        ).readAsBytesSync();
      }

      expect(await raster([notes.first]), await raster(null));
    });

    test('the document has a language, a title and an embedded font', () async {
      final bytes = await buildPdf(
        [tinyPng, tinyPng, tinyPng],
        title: 'Meeting, Feb to Apr 2026',
        notes: notes,
      );
      final raw = latin1.decode(bytes);
      expect(raw, contains('/Lang(en)'));
      expect(raw, contains('/DisplayDocTitle true'));
      final info = await pdftext(bytes, ['pdfinfo']);
      expect(info, contains('Title:           Meeting, Feb to Apr 2026'));
      final fonts = await pdftext(bytes, ['pdffonts']);
      expect(fonts, contains('DMSans'));
      expect(fonts, matches(RegExp(r'DMSans\S*\s+\S+.*yes\s+no\s+yes')));
      // One shared font, not one per page, and a reasonable size.
      expect(RegExp('DMSans').allMatches(fonts).length, 1);
      expect(bytes.length, lessThan(200 * 1024));
    });

    test('a deck without notes still works (pictures only)', () async {
      final bytes = await buildPdf([tinyPng], title: 'T');
      expect(latin1.decode(bytes.sublist(0, 5)), '%PDF-');
    });
  });

  test('file name uses the meeting date', () {
    final p = Period(
      id: 'p',
      startMonth: DateTime(2026, 2),
      meetingDate: DateTime(2026, 6, 9),
    );
    expect(
      deckFileBase(p),
      'Xynotransit_Regional_Logistics_Meeting_2026-06-09',
    );
  });

  test('file name follows a custom meeting title', () {
    final p = Period(
      id: 'p',
      startMonth: DateTime(2026, 2),
      meetingDate: DateTime(2026, 6, 9),
    );
    expect(
      deckFileBase(p, title: 'Q2 review: Tana & co!'),
      'Q2_review_Tana_co_2026-06-09',
    );
    expect(deckFileBase(p, title: '???'), startsWith('Xynotransit_Regional'));
  });

  test('speaker notes use the words of the deck', () {
    final t = DeckTexts.defaults
        .withValue('kpiTitle', 'KPI of {name}')
        .withValue('title', 'Big meeting {period}')
        .withValue('suggestionsTitle', 'Ideas');
    final s = demoSnapshot('rova');
    expect(
      slideAltText(KpiSlideSpec(s, texts: t)),
      startsWith('KPI of Rova. '),
    );
    expect(
      slideAltText(
        CoverSpec(
          periodLabel: 'Feb to Apr 2026',
          meetingDate: null,
          teamCounts: const [],
          texts: t,
        ),
      ),
      'Big meeting Feb to Apr 2026, Feb to Apr 2026.',
    );
    expect(
      slideAltText(SuggestionsSpec(periodLabel: 'x', texts: t)),
      'Ideas. Suggestions will be added here.',
    );
    expect(slideTitle(KpiSlideSpec(s, texts: t)), 'KPI of Rova');
    expect(slideTitle(SuggestionsSpec(periodLabel: 'x', texts: t)), 'Ideas');
  });

  test('speaker notes follow the agreed wording', () {
    final s = demoSnapshot('rova');
    final a = slideAltText(KpiSlideSpec(s));
    expect(
      a,
      startsWith(
        'Rova: KPI and volumes. ${s.metCount} of 3 KPI met. Air imports (IM5): ',
      ),
    );
    expect(a, contains('Sea imports (IM5): '));
    final b = slideAltText(ResultsSlideSpec(s));
    expect(
      b,
      'Rova: results and next priorities. ${s.well.length} Highlights, ${s.wrong.length} Lowlights, ${s.next.length} Next 3 months.',
    );
  });

  test('cover alt text has the custom date line, results use column titles', () {
    final texts = DeckTexts.defaults
        .withValue('dateText', 'Next Tuesday, 10:00')
        .withValue('highlightsTitle', 'Good')
        .withValue('lowlightsTitle', 'Bad')
        .withValue('nextTitle', 'Plans');
    final cover = CoverSpec(
      periodLabel: 'Feb to Apr 2026',
      meetingDate: DateTime(2026, 6, 9),
      teamCounts: const [('Mauritius', 1)],
      texts: texts,
    );
    expect(slideAltText(cover), contains('Next Tuesday, 10:00.'));
    final s = demoSnapshot('rova');
    expect(
      slideAltText(ResultsSlideSpec(s, texts: texts)),
      'Rova: results and next priorities. ${s.well.length} Good, ${s.wrong.length} Bad, ${s.next.length} Plans.',
    );
  });

  testWidgets('a slide renders to a 1920 x 1080 PNG', (tester) async {
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
    final future = slideToPng(ctx, SlideKpi(demoSnapshot('rova')));
    await tester.pump();
    await tester.pump();
    final png = (await tester.runAsync(() => future))!;
    final data = ByteData.sublistView(png);
    expect(png.sublist(1, 4), 'PNG'.codeUnits);
    expect(data.getUint32(16), slideWidth.toInt());
    expect(data.getUint32(20), slideHeight.toInt());
  });

  group('file names', () {
    final p = Period(
      id: 'p',
      startMonth: DateTime(2026, 2),
      meetingDate: DateTime(2026, 6, 9),
    );
    final clean = RegExp(r'^[A-Za-z0-9_]+_2026-06-09$');

    test('titles with illegal characters give a clean name', () {
      for (final title in [
        'a/b\\c',
        'Q2: review',
        'say "hello"',
        'line one\nline two\r\nline three',
        'tab\there',
        '<tag> | pipe * star ? mark',
        '../../etc/passwd',
        'CON',
        '   spaces   ',
        '山田太郎の会議',
        'مرحبا',
        'emoji 🚚 trip',
        '.hidden',
        'trailing dot.',
      ]) {
        final name = deckFileBase(p, title: title);
        expect(name, matches(clean), reason: '"$title" gave "$name"');
        expect(name.length, lessThanOrEqualTo(60 + 1 + 10), reason: name);
      }
    });

    test('accents become plain letters, not underscores', () {
      expect(
        deckFileBase(p, title: "Réunion Côte d'Ivoire Zoé Ñandú"),
        'Reunion_Cote_d_Ivoire_Zoe_Nandu_2026-06-09',
      );
      expect(deckFileBase(p, title: 'Straße Ærø'), 'Strasse_Aero_2026-06-09');
    });

    test('a very long title is cut at 60 characters without a trailing _', () {
      final name = deckFileBase(p, title: 'Word ' * 40);
      expect(name, matches(clean));
      final slug = name.substring(0, name.length - '_2026-06-09'.length);
      expect(slug.length, lessThanOrEqualTo(60));
      expect(slug, isNot(endsWith('_')));
    });

    test('a title with no usable letters falls back to the default name', () {
      for (final t in ['山田', '???', '', '   ', '\n']) {
        expect(
          deckFileBase(p, title: t),
          'Xynotransit_Regional_Logistics_Meeting_2026-06-09',
          reason: '"$t"',
        );
      }
    });
  });

  group('speaker notes', () {
    test('a KPI slide lists every target with its status and every number', () {
      final s = demoSnapshot('rova');
      final notes = slideNotes(KpiSlideSpec(s)).split('\n');
      expect(notes.first, slideAltText(KpiSlideSpec(s)));
      for (var i = 0; i < s.targets.length; i++) {
        expect(
          notes.any((l) => l.startsWith('${i + 1}. ${s.targets[i].text}: ')),
          isTrue,
          reason: 'target ${i + 1}',
        );
      }
      for (final m in s.metrics) {
        final line = notes.firstWhere((l) => l.startsWith('${m.label}: Feb '));
        for (var i = 0; i < 3; i++) {
          expect(
            line,
            contains('${s.months[i].short} ${thousands(m.values[i])}'),
          );
        }
        expect(line, contains('(total ${thousands(m.total)})'));
      }
    });

    test('numbers in notes and alt text have thousands separators', () {
      final s = ReportSnapshot(
        assignmentCode: 'x',
        name: 'Big',
        role: 'r',
        team: 't',
        periodLabel: 'Feb to Apr 2026',
        months: const [
          MonthRef(offset: 0, year: 2026, month: 2),
          MonthRef(offset: 1, year: 2026, month: 3),
          MonthRef(offset: 2, year: 2026, month: 4),
        ],
        metrics: [
          SnapshotMetric(
            key: 'k',
            label: 'Boxes',
            series: 0,
            values: const [1000000000, 12345, 7],
          ),
        ],
        targets: const [SnapshotTarget(text: 'On time', status: null)],
        well: const [],
        wrong: const [],
        next: const [],
      );
      final alt = slideAltText(KpiSlideSpec(s));
      expect(alt, contains('Boxes: 1,000,012,352.'));
      final notes = slideNotes(KpiSlideSpec(s));
      expect(notes, contains('Feb 1,000,000,000, Mar 12,345, Apr 7'));
      expect(notes, contains('1. On time: not answered.'));
    });

    test('a results slide gives the full text of every note', () {
      final s = demoSnapshot('rova');
      final notes = slideNotes(ResultsSlideSpec(s));
      for (final n in [...s.well, ...s.wrong, ...s.next]) {
        expect(notes, contains(n));
      }
      final texts = DeckTexts.defaults
          .withValue('highlightsTitle', 'Good')
          .withValue('emptyNote', 'Left blank');
      final empty = ReportSnapshot(
        assignmentCode: 'x',
        name: 'N',
        role: 'r',
        team: 't',
        periodLabel: 'p',
        months: s.months,
        metrics: const [],
        targets: const [],
        well: const [],
        wrong: const [],
        next: const ['Only this'],
      );
      final custom = slideNotes(ResultsSlideSpec(empty, texts: texts))
          .split('\n');
      expect(custom, contains('Good: Left blank'));
      expect(custom, contains('Next 3 months: Only this'));
    });

    test('cover and divider notes list the teams and the people', () {
      final cover = slideNotes(
        const CoverSpec(
          periodLabel: 'Feb to Apr 2026',
          meetingDate: null,
          teamCounts: [('Kenya', 2), ('Tana', 7)],
        ),
      );
      expect(cover, contains('Teams: Kenya · 2 reports; Tana · 7 reports.'));
      final divider = slideNotes(
        const DividerSpec(
          team: 'Kenya',
          periodLabel: 'Feb to Apr 2026',
          index: 1,
          total: 2,
          people: ['Zoé · Driver', 'Ali · Clerk'],
        ),
      );
      expect(divider, contains('Reports: Zoé · Driver; Ali · Clerk.'));
    });
  });

  testWidgets(
    'the demo deck exports to PDF, PPTX and PNG zip that open in other tools',
    (tester) async {
      final items = [
        for (var i = 0; i < catalog.assignments.length; i++)
          DeckItem(
            reportId: catalog.assignments[i].code,
            sort: i,
            snapshot: demoSnapshot(catalog.assignments[i].code),
          ),
      ];
      final run = DeckRun(
        id: 'r',
        periodId: testPeriod.id,
        generatedAt: DateTime(2026, 6, 1),
        expectedCount: items.length,
        includedCount: items.length,
        items: items,
        texts: DeckTexts.defaults,
      );
      final specs = buildDeck(run, testPeriod);
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
      Future<List<Uint8List>> render(double ratio) async {
        final f = renderDeckPngs(ctx, specs, pixelRatio: ratio);
        // The render waits for frames: keep pumping until it is done.
        var done = false;
        unawaited(f.whenComplete(() => done = true));
        while (!done) {
          await tester.pump(const Duration(milliseconds: 16));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 5)),
          );
        }
        return f;
      }

      final small = await render(1);
      final big = await render(pptxPixelRatio);
      expect(small, hasLength(34));
      final dims = ByteData.sublistView(big.first);
      expect([dims.getUint32(16), dims.getUint32(20)], [3840, 2160]);

      final dir = Directory('/tmp/xt-slides-export')
        ..createSync(recursive: true);
      final title = deckTitleOf(specs);
      final base = deckFileBase(testPeriod, title: meetingTitleOf(specs));
      final pdf = (await tester.runAsync(
        () => buildPdf(
          small,
          title: title,
          notes: [for (final s in specs) slideNotes(s)],
        ),
      ))!;
      final pptx = buildPptx(pptxSlidesFor(specs, big), title: title);
      final zip = buildPngZip(small, pngNames(small.length));
      File('${dir.path}/$base.pdf').writeAsBytesSync(pdf);
      File('${dir.path}/$base.pptx').writeAsBytesSync(pptx);
      File('${dir.path}/$base.zip').writeAsBytesSync(zip);
      for (final b in [pdf, pptx, zip]) {
        expect(b.length, lessThan(25 * 1024 * 1024));
      }
      expect(ZipDecoder().decodeBytes(zip).files, hasLength(34));

      final python = File('/tmp/xt-slides-venv/bin/python');
      if (!python.existsSync()) {
        markTestSkipped('no python-pptx venv at /tmp/xt-slides-venv');
        return;
      }
      final r = await tester.runAsync(
        () => Process.run(python.path, [
          '-I',
          '-c',
          '''
import sys
from pptx import Presentation
from pptx.util import Emu
p = Presentation(sys.argv[1])
assert p.slide_width == 12192000 and p.slide_height == 6858000, "size"
assert len(p.slides) == 34, len(p.slides)
for i, s in enumerate(p.slides, 1):
    pics = [x for x in s.shapes if x.shape_type == 13]
    assert len(pics) == 1, (i, "pictures")
    pic = pics[0]
    assert (pic.left, pic.top, pic.width, pic.height) == (0, 0, 12192000, 6858000), (i, "full bleed")
    assert pic.image.size == (3840, 2160), (i, pic.image.size)
    descr = pic._element.nvPicPr.cNvPr.get("descr")
    assert descr and len(descr) > 10, (i, "alt text")
    assert s.shapes.title is not None and s.shapes.title.text_frame.text, (i, "title")
    notes = s.notes_slide.notes_text_frame.text
    assert notes.startswith(descr), (i, "notes start with the alt text")
    assert "\\n" in notes or i in (1, 34), (i, "notes have lines")
print("ok", len(p.slides))
''',
          '${dir.path}/$base.pptx',
        ]),
      );
      expect(r!.stderr, isEmpty);
      expect(r.stdout, contains('ok 34'));
      final info = await tester.runAsync(
        () => Process.run('pdfinfo', ['${dir.path}/$base.pdf']),
      );
      expect(info!.stdout, matches(RegExp(r'Pages:\s+34')));
      expect(info.stdout, matches(RegExp(r'Page size:\s+1920 x 1080 pts')));
    },
    timeout: const Timeout(Duration(minutes: 8)),
  );
}
