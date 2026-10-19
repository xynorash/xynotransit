import 'package:flutter/material.dart';

import '../../domain/enums.dart';

enum NoteIcon { check, warning, bulb }

/// Stroke icons drawn on a 24 unit grid and scaled to [size].
class NoteIconPainter extends CustomPainter {
  const NoteIconPainter(this.icon, this.color);

  final NoteIcon icon;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final k = size.width / 24;
    canvas.scale(k);
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    switch (icon) {
      case NoteIcon.check:
        canvas.drawCircle(const Offset(12, 12), 9.5, stroke);
        canvas.drawPath(
          Path()
            ..moveTo(7.5, 12.5)
            ..relativeLineTo(3, 3)
            ..relativeLineTo(6, -6.5),
          stroke,
        );
      case NoteIcon.warning:
        canvas.drawPath(
          Path()
            ..moveTo(12, 3.5)
            ..relativeLineTo(9.5, 16.5)
            ..relativeLineTo(-19, 0)
            ..close(),
          stroke,
        );
        canvas.drawPath(
          Path()
            ..moveTo(12, 10)
            ..relativeLineTo(0, 5),
          stroke,
        );
        canvas.drawCircle(const Offset(12, 17.6), 1, Paint()..color = color);
      case NoteIcon.bulb:
        canvas.drawPath(
          Path()
            ..moveTo(9, 18)
            ..relativeLineTo(6, 0)
            ..moveTo(10, 21)
            ..relativeLineTo(4, 0),
          stroke,
        );
        canvas.drawPath(
          Path()
            ..moveTo(12, 3)
            ..arcToPoint(
              const Offset(8.4, 13.8),
              radius: const Radius.circular(6),
              clockwise: false,
            )
            ..relativeCubicTo(0.7, 0.6, 1.1, 1.4, 1.1, 2.2)
            ..relativeLineTo(5, 0)
            ..relativeCubicTo(0, -0.8, 0.4, -1.6, 1.1, -2.2)
            ..arcToPoint(
              const Offset(12, 3),
              radius: const Radius.circular(6),
              clockwise: false,
            )
            ..close(),
          stroke,
        );
    }
  }

  @override
  bool shouldRepaint(NoteIconPainter old) =>
      old.icon != icon || old.color != color;
}

/// A shape for each answer, so Met, Partly and Missed differ without colour:
/// a tick, a half-filled circle and a cross. Null (not answered) has none.
class StatusGlyph extends StatelessWidget {
  const StatusGlyph(this.status, this.color, {super.key, this.size = 20});

  final KpiStatus? status;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    final s = status;
    if (s == null) return const SizedBox.shrink();
    return ExcludeSemantics(
      child: SizedBox(
        width: size,
        height: size,
        child: CustomPaint(painter: StatusGlyphPainter(s, color)),
      ),
    );
  }
}

class StatusGlyphPainter extends CustomPainter {
  const StatusGlyphPainter(this.status, this.color);

  final KpiStatus status;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 24);
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    switch (status) {
      case KpiStatus.met:
        canvas.drawPath(
          Path()
            ..moveTo(4, 12.5)
            ..lineTo(9.5, 18)
            ..lineTo(20, 6),
          stroke,
        );
      case KpiStatus.partly:
        canvas.drawCircle(const Offset(12, 12), 9, stroke..strokeWidth = 2.6);
        canvas.drawPath(
          Path()
            ..moveTo(12, 3)
            ..arcToPoint(
              const Offset(12, 21),
              radius: const Radius.circular(9),
              clockwise: false,
            )
            ..close(),
          Paint()..color = color,
        );
      case KpiStatus.missed:
        canvas.drawPath(
          Path()
            ..moveTo(5, 5)
            ..lineTo(19, 19)
            ..moveTo(19, 5)
            ..lineTo(5, 19),
          stroke,
        );
    }
  }

  @override
  bool shouldRepaint(StatusGlyphPainter old) =>
      old.status != status || old.color != color;
}
