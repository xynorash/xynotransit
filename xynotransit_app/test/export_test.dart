import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart';
import 'package:xynotransit_app/domain/deck.dart';
import 'package:xynotransit_app/domain/deck_text.dart';
import 'package:xynotransit_app/domain/period.dart';
import 'package:xynotransit_app/features/export/deck_export.dart';
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
      'Rova: results and next priorities. ${s.well.length} highlights, ${s.wrong.length} lowlights, ${s.next.length} priorities for the next three months.',
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
}
