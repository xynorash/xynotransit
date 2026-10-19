import 'package:flutter/material.dart';
import 'package:qr/qr.dart';

/// Error correction used for sign-in links: level M, so a link of about
/// 100 characters is a small, easy to scan code.
const qrErrorLevel = QrErrorCorrectLevel.M;

/// Empty modules around the code, as the QR standard asks (4).
const qrQuietZone = 4;

/// The dark modules of the QR code of [data] (true is dark), row by row.
List<List<bool>> qrMatrix(String data) {
  final image = QrImage(
    QrCode.fromData(data: data, errorCorrectLevel: qrErrorLevel),
  );
  return [
    for (var r = 0; r < image.moduleCount; r++)
      [for (var c = 0; c < image.moduleCount; c++) image.isDark(r, c)],
  ];
}

/// Draws a QR code in pure black on pure white, whatever the app theme is, with
/// the quiet zone included in the drawing. Modules are whole pixels when the
/// space allows it, so the code stays sharp and scannable.
class QrPainter extends CustomPainter {
  QrPainter(this.data) : matrix = qrMatrix(data);

  final String data;
  final List<List<bool>> matrix;

  /// Modules on one side, quiet zone included.
  int get modules => matrix.length + 2 * qrQuietZone;

  @override
  void paint(Canvas canvas, Size size) {
    final side = size.shortestSide;
    canvas.drawRect(
      Rect.fromLTWH(0, 0, side, side),
      Paint()
        ..color = const Color(0xFFFFFFFF)
        ..isAntiAlias = false,
    );
    final whole = (side / modules).floorToDouble();
    final cell = whole >= 1 ? whole : side / modules;
    final origin = (side - cell * modules) / 2 + cell * qrQuietZone;
    final dark = Paint()
      ..color = const Color(0xFF000000)
      ..isAntiAlias = false;
    for (var r = 0; r < matrix.length; r++) {
      for (var c = 0; c < matrix.length; c++) {
        if (matrix[r][c]) {
          canvas.drawRect(
            Rect.fromLTWH(origin + c * cell, origin + r * cell, cell, cell),
            dark,
          );
        }
      }
    }
  }

  @override
  bool shouldRepaint(QrPainter old) => old.data != data;
}

/// The QR code of [data] with a text label for screen readers.
class QrView extends StatelessWidget {
  const QrView({super.key, required this.data, this.size = 240});

  final String data;
  final double size;

  static const label = 'QR code of the sign-in link';

  @override
  Widget build(BuildContext context) => Semantics(
    label: label,
    image: true,
    child: ExcludeSemantics(
      child: RepaintBoundary(
        child: SizedBox.square(
          dimension: size,
          child: CustomPaint(painter: QrPainter(data)),
        ),
      ),
    ),
  );
}
