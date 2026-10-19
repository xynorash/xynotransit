// Slide matrix: every slide type with ordinary, extreme and hostile data,
// rendered with the real widgets at 1920 x 1080 and checked automatically.
//
//   flutter test test/slide_matrix_test.dart
//   XT_SHEETS=1 flutter test test/slide_matrix_test.dart --plain-name sheets
//     writes /tmp/xt-slides-sheets/ (one PNG per case, contact sheets of 12)
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xynotransit_app/core/format.dart';
import 'package:xynotransit_app/domain/deck.dart';
import 'package:xynotransit_app/features/slides/alt_text.dart';
import 'package:xynotransit_app/domain/deck_text.dart';
import 'package:xynotransit_app/features/slides/canvas.dart';
import 'package:xynotransit_app/features/slides/palette.dart';
import 'package:xynotransit_app/features/slides/slide_view.dart';

import '../tool/slide_matrix.dart';
import 'helpers.dart';

const _tol = 0.6;
const safe = Rect.fromLTRB(128, 128, 1792, 1016);

/// One painted piece of text.
class Para {
  Para(
    this.ro,
    this.text,
    this.rect,
    this.size,
    this.color,
    this.bg,
    this.ellipsis,
    this.bands,
  );
  final RenderParagraph ro;
  final String text;
  final Rect rect;

  /// Font size on the 1920 x 1080 page, after any scaling by ancestors.
  final double size;
  final Color color;
  final Color? bg;
  final bool ellipsis;

  /// One glyph band per line, for the overlap check.
  final List<Rect> bands;
  @override
  String toString() =>
      '"${text.length > 40 ? '${text.substring(0, 40)}...' : text}" $rect @${size.toStringAsFixed(1)}px';
}

double _lum(Color c) {
  double f(double v) =>
      v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * f(c.r) + 0.7152 * f(c.g) + 0.0722 * f(c.b);
}

/// WCAG contrast ratio of two opaque colours.
double contrast(Color a, Color b) {
  final x = _lum(a), y = _lum(b);
  return (math.max(x, y) + 0.05) / (math.min(x, y) + 0.05);
}

Rect _global(RenderBox b, Rect local) =>
    MatrixUtils.transformRect(b.getTransformTo(null), local);

Color? _bgOf(RenderObject ro) {
  if (ro is RenderDecoratedBox) {
    final d = ro.decoration;
    if (d is BoxDecoration && d.color != null) return d.color;
  }
  final n = ro.runtimeType.toString();
  if (n == '_RenderColoredBox') return (ro as dynamic).color as Color;
  return null;
}

/// Is [ro] a card or panel that must contain its text?
bool _isPanel(RenderObject ro) {
  if (ro is RenderDecoratedBox) {
    final d = ro.decoration;
    if (d is BoxDecoration && (d.color != null || d.border != null)) {
      return true;
    }
  }
  if (ro is RenderCustomPaint && ro.painter != null) return true;
  return ro.runtimeType.toString() == '_RenderColoredBox';
}

List<RenderObject> _chain(RenderObject ro) {
  final out = <RenderObject>[];
  for (RenderObject? p = ro.parent; p != null; p = p.parent) {
    out.add(p);
  }
  return out;
}

void _walk(RenderObject ro, void Function(RenderObject) f) {
  f(ro);
  ro.visitChildren((c) => _walk(c, f));
}

List<Para> collect(WidgetTester tester) {
  final root = tester.renderObject<RenderBox>(find.byType(SlideCanvas));
  final out = <Para>[];
  _walk(root, (ro) {
    if (ro is! RenderParagraph) return;
    final text = ro.text.toPlainText();
    if (text.trim().isEmpty) return;
    final painter = TextPainter(
      text: ro.text,
      textAlign: ro.textAlign,
      textDirection: ro.textDirection,
      maxLines: ro.maxLines,
      ellipsis: ro.overflow == TextOverflow.ellipsis ? '\u2026' : null,
      textHeightBehavior: ro.textHeightBehavior,
      textWidthBasis: ro.textWidthBasis,
      textScaler: ro.textScaler,
    )..layout(minWidth: ro.size.width, maxWidth: ro.size.width);
    final lines = painter.computeLineMetrics();
    painter.dispose();
    if (lines.isEmpty) {
      return;
    }
    final style = ro.text.style;
    final fs = style?.fontSize ?? 14;
    final tf = ro.getTransformTo(null);
    // The line boxes of the font are taller than the glyphs. Compare the
    // glyph band of each line: one font size high, centred on the line.
    final bands = <Rect>[];
    for (final m in lines) {
      final top = m.baseline - m.ascent;
      final full = m.ascent + m.descent;
      final h = math.min(full, fs);
      final c = top + full / 2;
      bands.add(
        MatrixUtils.transformRect(
          tf,
          Rect.fromLTWH(m.left, c - h / 2, m.width, h),
        ),
      );
    }
    var g = bands.first;
    for (final b in bands.skip(1)) {
      g = g.expandToInclude(b);
    }
    final scale = tf.getMaxScaleOnAxis();
    Color? bg;
    for (final a in _chain(ro)) {
      bg = _bgOf(a);
      if (bg != null) break;
    }
    out.add(
      Para(
        ro,
        text,
        g,
        fs * scale,
        style?.color ?? const Color(0xFF000000),
        bg,
        ro.didExceedMaxLines,
        bands,
      ),
    );
  });
  return out;
}

final _thousands = RegExp(r'^\d{1,3}(,\d{3})*$');

/// Every rule, as plain sentences. Empty means the slide is clean.
List<String> checkSlide(WidgetTester tester, MatrixCase c) {
  final bad = <String>[];
  final paras = collect(tester);
  if (paras.isEmpty) bad.add('no text found');

  for (final p in paras) {
    // Safe area.
    if (p.rect.left < safe.left - _tol ||
        p.rect.right > safe.right + _tol ||
        p.rect.top < safe.top - _tol ||
        p.rect.bottom > safe.bottom + _tol) {
      bad.add('outside safe area: $p');
    }
    // Inside its own card or panel and every clip above it.
    for (final a in _chain(p.ro)) {
      if (a is RenderBox && a.hasSize && _isPanel(a)) {
        final r = _global(a, Offset.zero & a.size);
        if (p.rect.left < r.left - _tol ||
            p.rect.right > r.right + _tol ||
            p.rect.top < r.top - _tol ||
            p.rect.bottom > r.bottom + _tol) {
          bad.add('outside its card $r: $p');
        }
        break;
      }
    }
    for (final a in _chain(p.ro)) {
      if ((a is RenderClipRect ||
              a is RenderClipRRect ||
              a is RenderClipPath) &&
          a is RenderBox) {
        final r = _global(a, Offset.zero & a.size);
        if (p.rect.left < r.left - _tol ||
            p.rect.right > r.right + _tol ||
            p.rect.top < r.top - _tol ||
            p.rect.bottom > r.bottom + _tol) {
          bad.add('clipped by $r: $p');
        }
      }
    }
    // Ellipsis only in the dense target cards.
    if (p.ellipsis) {
      // The dense target layout draws its cards with a 16 px radius.
      final dense = _chain(p.ro).any(
        (a) =>
            a is RenderDecoratedBox &&
            (a.decoration as BoxDecoration).borderRadius ==
                BorderRadius.circular(16),
      );
      if (!dense && !c.ellipsisOk) bad.add('ellipsis: $p');
    }
    // Sizes.
    final isNumber = RegExp(r'^[\d,]+$').hasMatch(p.text);
    final isFooter = p.rect.top > 900;
    final min = isFooter ? 22.0 : (isNumber ? 18.0 : 20.0);
    if (p.size < min - 0.01) {
      bad.add('font ${p.size.toStringAsFixed(1)} < $min: $p');
    }
    // Contrast.
    final bg = p.bg;
    if (bg != null) {
      final cr = contrast(p.color, bg);
      if (cr < 4.5) bad.add('contrast ${cr.toStringAsFixed(2)}: $p on $bg');
    }
    // Number format.
    if (isNumber && !_thousands.hasMatch(p.text)) bad.add('number format: $p');
  }

  // Overlap of unrelated text.
  for (var i = 0; i < paras.length; i++) {
    for (var j = i + 1; j < paras.length; j++) {
      var hit = false;
      for (final a in paras[i].bands) {
        for (final b in paras[j].bands) {
          final x = a.intersect(b);
          if (x.width > 1.5 && x.height > 1.5) hit = true;
        }
      }
      if (hit) bad.add('overlap: ${paras[i]} with ${paras[j]}');
    }
  }

  // Cards and bars stay on the page and, for the chart, in the panel.
  final root = tester.renderObject<RenderBox>(find.byType(SlideCanvas));
  RenderBox? panel;
  _walk(root, (ro) {
    if (ro is RenderDecoratedBox) {
      final d = ro.decoration;
      if (d is BoxDecoration &&
          d.color == SlidePalette.navy &&
          d.borderRadius == BorderRadius.circular(24) &&
          ro.size.width > 600) {
        panel = ro;
      }
    }
  });
  if (panel != null) {
    final pr = _global(panel!, Offset.zero & panel!.size);
    final inner = pr.deflate(16);
    _walk(panel!, (ro) {
      if (ro == panel || ro is! RenderBox || !ro.hasSize) return;
      final isBar =
          ro is RenderDecoratedBox &&
          (ro.decoration as BoxDecoration).borderRadius != null &&
          (ro.decoration as BoxDecoration).color != null;
      if (!isBar) return;
      final r = _global(ro, Offset.zero & ro.size);
      if (r.left < inner.left - _tol ||
          r.right > inner.right + _tol ||
          r.top < inner.top - _tol ||
          r.bottom > inner.bottom + _tol) {
        bad.add('bar outside panel: $r in $pr');
      }
    });
    for (final p in paras) {
      if (!pr.contains(p.rect.center)) continue;
      if (p.rect.left < inner.left - _tol ||
          p.rect.right > inner.right + _tol ||
          p.rect.top < inner.top - _tol ||
          p.rect.bottom > inner.bottom + _tol) {
        bad.add('text too close to panel edge: $p in $pr');
      }
    }
  }
  return bad;
}

Future<List<String>> pumpCase(WidgetTester tester, MatrixCase c) async {
  final errors = <String>[];
  final old = FlutterError.onError;
  FlutterError.onError = (d) =>
      errors.add(d.exceptionAsString().split('\n').first);
  try {
    await pumpSlide(tester, slideFor(c.spec));
    await tester.pump();
  } finally {
    FlutterError.onError = old;
  }
  final ex = tester.takeException();
  if (ex != null) errors.add('exception: ${ex.toString().split('\n').first}');
  return errors;
}

/// Draws the slide and returns the PNG bytes.
Future<ui.Image> shot(WidgetTester tester) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byType(RepaintBoundary).first,
  );
  return (await tester.runAsync(() => boundary.toImage()))!;
}

/// The 14 demo reports as a real deck (cover, dividers, two slides each, suggestions).
List<MatrixCase> demoDeck() {
  final items = <DeckItem>[
    for (final a in catalog.assignments)
      DeckItem(reportId: a.code, sort: 0, snapshot: demoSnapshot(a.code)),
  ];
  final run = DeckRun(
    id: 'run',
    periodId: testPeriod.id,
    generatedAt: DateTime(2026, 6, 1),
    expectedCount: items.length,
    includedCount: items.length,
    items: [
      for (var i = 0; i < items.length; i++)
        DeckItem(
          reportId: items[i].reportId,
          sort: i,
          snapshot: items[i].snapshot,
        ),
    ],
    texts: DeckTexts.defaults,
  );
  final specs = buildDeck(run, testPeriod);
  return [
    for (var i = 0; i < specs.length; i++)
      MatrixCase('demo', 'demo ${i + 1} ${slideTitle(specs[i])}', specs[i]),
  ];
}

void main() {
  setUpAll(loadAppFonts);
  final cases = [...slideMatrix(), ...demoDeck()];

  test('the matrix has at least 60 cases and covers every slide type', () {
    expect(cases.length, greaterThanOrEqualTo(60));
    final types = {for (final c in cases) c.spec.runtimeType.toString()};
    expect(
      types,
      containsAll([
        'CoverSpec',
        'DividerSpec',
        'KpiSlideSpec',
        'ResultsSlideSpec',
        'SuggestionsSpec',
      ]),
    );
    expect(
      {for (final c in cases) c.name}.length,
      cases.length,
      reason: 'unique names',
    );
  });

  test('contrast of every palette pair is at least 4.5 : 1', () {
    final pairs = <String, (Color, Color)>{
      'ink on paper': (SlidePalette.ink, SlidePalette.paper),
      'ink on card': (SlidePalette.ink, SlidePalette.card),
      'blue on paper': (SlidePalette.blue, SlidePalette.paper),
      'muted on paper': (SlidePalette.mutedOnLight, SlidePalette.paper),
      'muted on dark': (SlidePalette.mutedOnDark, SlidePalette.navy),
      'panelText on navy': (SlidePalette.panelText, SlidePalette.navy),
      'paper on navy': (SlidePalette.paper, SlidePalette.navy),
      'white on navy': (SlidePalette.white, SlidePalette.navy),
      'orange on navy': (SlidePalette.orange, SlidePalette.navy),
      'emptyNote on paper': (SlidePalette.emptyNote, SlidePalette.paper),
      'white on blue (divider)': (SlidePalette.white, SlidePalette.blue),
      'white on green (column)': (SlidePalette.white, SlidePalette.green),
      'white on rust (column)': (SlidePalette.white, SlidePalette.rust),
      'white on blue (column)': (SlidePalette.white, SlidePalette.blue),
      'white on met chip': (Colors.white, SlidePalette.met),
      'white on partly chip': (Colors.white, SlidePalette.partly),
      'white on missed chip': (Colors.white, SlidePalette.missed),
      'white on unanswered chip': (Colors.white, SlidePalette.unanswered),
      'met on card': (SlidePalette.met, SlidePalette.card),
      'partly on card': (SlidePalette.partly, SlidePalette.card),
      'missed on card': (SlidePalette.missed, SlidePalette.card),
      'unanswered on card': (SlidePalette.unanswered, SlidePalette.card),
      'navy on paper pill': (SlidePalette.navy, SlidePalette.paper),
      'navy on white pill': (SlidePalette.navy, SlidePalette.white),
      'orange on navy (cover date)': (SlidePalette.orange, SlidePalette.navy),
      'targets-only met': (const Color(0xFF5FD3B0), SlidePalette.navy),
      'targets-only partly': (const Color(0xFFF0C24A), SlidePalette.navy),
      'targets-only missed': (const Color(0xFFF0933A), SlidePalette.navy),
      for (var i = 0; i < SlidePalette.series.length; i++)
        'series $i on navy': (SlidePalette.series[i], SlidePalette.navy),
    };
    final bad = <String>[];
    pairs.forEach((k, v) {
      final r = contrast(v.$1, v.$2);
      if (r < 4.5) bad.add('$k ${r.toStringAsFixed(2)}');
    });
    expect(bad, isEmpty);
  });

  test('thousands separators', () {
    expect(thousands(0), '0');
    expect(thousands(999), '999');
    expect(thousands(12345), '12,345');
    expect(thousands(999999999), '999,999,999');
    expect(thousands(1000000000), '1,000,000,000');
  });

  for (final c in cases) {
    testWidgets('matrix ${c.group}: ${c.name}', (tester) async {
      final errors = await pumpCase(tester, c);
      final bad = [...errors, ...checkSlide(tester, c)];
      expect(bad, isEmpty, reason: bad.take(12).join('\n'));
    });
  }

  // Goldens of the layouts that only exist for hard data. Update them only
  // for a deliberate change of design: flutter test --update-goldens.
  const goldenCases = {
    'targets 0 targets no counts': 'matrix_no_targets_no_counts',
    'targets 1 targets x80': 'matrix_one_target',
    'targets 5 targets x200': 'matrix_five_long_targets',
    'targets 6 targets x200': 'matrix_six_long_targets_dense',
    'targets 3 unanswered': 'matrix_unanswered',
    'values 8 counts mixed tiny/huge': 'matrix_eight_counts_mixed',
    'values 3 counts all 12345': 'matrix_values_12345',
    'counts 8 counts label60': 'matrix_eight_counts_long_labels',
    'notes 3 notes x70 words': 'matrix_notes_full',
    'notes 3 notes x70 wide': 'matrix_notes_wide',
    'divider divider 30 people long': 'matrix_divider_more',
    'cover cover 12 countries': 'matrix_cover_12',
    'names all 80 words / KPI': 'matrix_names_80',
  };
  for (final c in cases) {
    final file = goldenCases['${c.group} ${c.name}'];
    if (file == null) continue;
    testWidgets('golden ${c.name}', (tester) async {
      await pumpCase(tester, c);
      await expectLater(
        find.byType(SlideCanvas),
        matchesGoldenFile('goldens/$file.png'),
      );
    });
  }
  test('every golden case exists in the matrix', () {
    final names = {for (final c in cases) '${c.group} ${c.name}'};
    expect(names, containsAll(goldenCases.keys));
  });

  testWidgets('sheets', (tester) async {
    if (Platform.environment['XT_SHEETS'] == null) return;
    final dir = Directory('/tmp/xt-slides-sheets/cases')
      ..createSync(recursive: true);
    final images = <ui.Image>[];
    File('/tmp/xt-slides-sheets/index.txt').writeAsStringSync(
      [
        for (var i = 0; i < cases.length; i++)
          '${i.toString().padLeft(3, '0')} ${cases[i].group} ${cases[i].name}',
      ].join('\n'),
    );
    for (var i = 0; i < cases.length; i++) {
      await pumpCase(tester, cases[i]);
      final img = await shot(tester);
      images.add(img);
      final bytes = await tester.runAsync(
        () => img.toByteData(format: ui.ImageByteFormat.png),
      );
      File('${dir.path}/${i.toString().padLeft(3, '0')}.png')
          .writeAsBytesSync(bytes!.buffer.asUint8List());
    }
    const tw = 640.0, th = 360.0, lab = 30.0, cols = 3, rows = 4;
    for (var s = 0; s * 12 < cases.length; s++) {
      final rec = ui.PictureRecorder();
      final cv = Canvas(rec);
      cv.drawRect(
        const Rect.fromLTWH(0, 0, tw * cols, (th + lab) * rows),
        Paint()..color = const Color(0xFF888888),
      );
      for (var k = 0; k < 12 && s * 12 + k < cases.length; k++) {
        final idx = s * 12 + k;
        final x = (k % cols) * tw, y = (k ~/ cols) * (th + lab);
        cv.drawImageRect(
          images[idx],
          const Rect.fromLTWH(0, 0, 1920, 1080),
          Rect.fromLTWH(x + 2, y + lab, tw - 4, th - 2),
          Paint()..filterQuality = FilterQuality.high,
        );
        final tp = TextPainter(
          text: TextSpan(
            text: '$idx ${cases[idx].name}',
            style: const TextStyle(
              fontFamily: 'DM Sans',
              fontSize: 20,
              color: Colors.white,
            ),
          ),
          textDirection: TextDirection.ltr,
          maxLines: 1,
          ellipsis: '...',
        )..layout(maxWidth: tw - 8);
        tp.paint(cv, Offset(x + 4, y + 3));
      }
      final pic = rec.endRecording();
      final img = await pic.toImage(
        (tw * cols).toInt(),
        ((th + lab) * rows).toInt(),
      );
      final bytes = await tester.runAsync(
        () => img.toByteData(format: ui.ImageByteFormat.png),
      );
      File('/tmp/xt-slides-sheets/sheet-${s.toString().padLeft(2, '0')}.png')
          .writeAsBytesSync(bytes!.buffer.asUint8List());
    }
  });
}
