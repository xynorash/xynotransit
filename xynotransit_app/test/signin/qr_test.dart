import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr/qr.dart';
import 'package:xynotransit_app/core/theme/theme.dart';
import 'package:xynotransit_app/features/admin/qr_view.dart';

const url =
    'https://reports.example.org/auth/verify?token=Zk3Qm9xT1vB7nLd2WcR8yHs5AaEoJp0UiGfKtXe4N6M';

/// What the 'qr' package itself says, at level M.
List<List<bool>> reference(String data, {int level = QrErrorCorrectLevel.M}) {
  final img = QrImage(QrCode.fromData(data: data, errorCorrectLevel: level));
  return [
    for (var r = 0; r < img.moduleCount; r++)
      [for (var c = 0; c < img.moduleCount; c++) img.isDark(r, c)],
  ];
}

/// Draws the painter to a PNG, reads the PNG back and returns its pixels.
Future<(int, ByteData)> renderPng(String data, int side) async {
  final rec = ui.PictureRecorder();
  QrPainter(data).paint(Canvas(rec), Size(side.toDouble(), side.toDouble()));
  final image = await rec.endRecording().toImage(side, side);
  final png = (await image.toByteData(format: ui.ImageByteFormat.png))!;
  final bytes = png.buffer.asUint8List();
  expect(bytes.sublist(0, 8), [
    137,
    80,
    78,
    71,
    13,
    10,
    26,
    10,
  ], reason: 'a PNG');
  final codec = await ui.instantiateImageCodec(Uint8List.fromList(bytes));
  final back = (await codec.getNextFrame()).image;
  expect(back.width, side);
  final raw = (await back.toByteData())!;
  return (side, raw);
}

int pixel(ByteData d, int side, int x, int y) {
  final o = (y * side + x) * 4;
  return (d.getUint8(o) << 24) |
      (d.getUint8(o + 1) << 16) |
      (d.getUint8(o + 2) << 8) |
      d.getUint8(o + 3);
}

const black = 0x000000FF;
const white = 0xFFFFFFFF;

void main() {
  test('level M, quiet zone 4', () {
    expect(qrErrorLevel, QrErrorCorrectLevel.M);
    expect(qrQuietZone, 4);
    expect(qrMatrix(url), reference(url));
    expect(
      qrMatrix(url),
      isNot(reference(url, level: QrErrorCorrectLevel.L)),
      reason: 'level M is not level L',
    );
    final n = qrMatrix(url).length;
    expect(n, inInclusiveRange(29, 45), reason: 'about version 3 to 7');
    expect(QrPainter(url).modules, n + 8);
  });

  testWidgets('the picture drawn has exactly the modules of the qr package', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final ref = reference(url);
      final n = ref.length;
      const cell = 6;
      final side = (n + 8) * cell;
      final (_, raw) = await renderPng(url, side);

      // Read the matrix back from the pixels, at the centre of every module.
      final seen = [
        for (var r = 0; r < n; r++)
          [
            for (var c = 0; c < n; c++)
              pixel(
                    raw,
                    side,
                    (c + 4) * cell + cell ~/ 2,
                    (r + 4) * cell + cell ~/ 2,
                  ) ==
                  black,
          ],
      ];
      expect(seen, ref);

      // Quiet zone: four modules of pure white on every side.
      final q = 4 * cell;
      for (var y = 0; y < side; y++) {
        for (var x = 0; x < side; x++) {
          final inside = x >= q && x < side - q && y >= q && y < side - q;
          if (!inside) {
            expect(pixel(raw, side, x, y), white, reason: 'quiet zone $x,$y');
          }
        }
      }

      // High contrast: only black and white, nothing in between.
      final colours = <int>{};
      for (var y = 0; y < side; y++) {
        for (var x = 0; x < side; x++) {
          colours.add(pixel(raw, side, x, y));
        }
      }
      expect(colours, {black, white});

      // The three finder patterns sit in the corners, 7 modules wide.
      bool dark(int r, int c) => ref[r][c];
      for (final (r0, c0) in [(0, 0), (0, n - 7), (n - 7, 0)]) {
        for (var i = 0; i < 7; i++) {
          expect(dark(r0, c0 + i), isTrue);
          expect(dark(r0 + 6, c0 + i), isTrue);
          expect(dark(r0 + i, c0), isTrue);
          expect(dark(r0 + i, c0 + 6), isTrue);
        }
        expect(dark(r0 + 3, c0 + 3), isTrue);
        expect(dark(r0 + 1, c0 + 1), isFalse);
      }
    });
  });

  testWidgets('a size that is not a multiple still draws whole modules', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final ref = reference(url);
      final n = ref.length;
      const side = 239;
      final (_, raw) = await renderPng(url, side);
      final total = n + 8;
      final cell = side ~/ total;
      expect(cell, greaterThanOrEqualTo(4));
      final off = (side - cell * total) / 2;
      var ok = 0;
      for (var r = 0; r < n; r++) {
        for (var c = 0; c < n; c++) {
          final x = (off + (c + 4) * cell + cell / 2).floor();
          final y = (off + (r + 4) * cell + cell / 2).floor();
          if ((pixel(raw, side, x, y) == black) == ref[r][c]) ok++;
        }
      }
      expect(ok, n * n);
      final colours = <int>{};
      for (var y = 0; y < side; y++) {
        for (var x = 0; x < side; x++) {
          colours.add(pixel(raw, side, x, y));
        }
      }
      expect(colours, {black, white}, reason: 'no grey edges');
    });
  });

  for (final brightness in Brightness.values) {
    testWidgets('the widget is black on white in ${brightness.name} mode', (
      tester,
    ) async {
      final key = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(brightness),
          home: Scaffold(
            body: Center(
              child: RepaintBoundary(
                key: key,
                child: const QrView(data: url, size: 232),
              ),
            ),
          ),
        ),
      );
      expect(
        find.bySemanticsLabel('QR code of the sign-in link'),
        findsOneWidget,
      );
      await tester.runAsync(() async {
        final boundary =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final image = await boundary.toImage();
        final raw = (await image.toByteData())!;
        final side = image.width;
        expect(side, 232);
        final colours = <int>{};
        for (var y = 0; y < side; y++) {
          for (var x = 0; x < side; x++) {
            colours.add(pixel(raw, side, x, y));
          }
        }
        expect(colours, {black, white});
        // Corner pixel is the quiet zone: white, even in dark mode.
        expect(pixel(raw, side, 0, 0), white);
        expect(pixel(raw, side, side - 1, side - 1), white);
        final total = qrMatrix(url).length + 8;
        final cell = side ~/ total;
        final off = ((side - cell * total) / 2).floor();
        // The first finder pattern corner module is black.
        expect(pixel(raw, side, off + 4 * cell + 1, off + 4 * cell + 1), black);
      });
    });
  }

  testWidgets('other strings give the same matrix as the qr package', (
    tester,
  ) async {
    for (final s in [
      'https://demo.invalid/auth/verify?token=demo-abc123',
      'a',
      'é' * 40,
    ]) {
      expect(qrMatrix(s), reference(s), reason: s);
    }
  });
}
