import 'package:flutter/material.dart';

import '../../domain/deck_text.dart';
import 'canvas.dart';
import 'measure.dart';
import 'palette.dart';
import 'slide_words.dart';

/// Biggest size first; the text takes as many lines as the box allows.
const _bodySizes = [48.0, 44.0, 40.0, 36.0, 32.0, 28.0, 26.0, 24.0, 22.0, 20.0];
const _bodyWidth = slideTextWidth - 2 * 64;

/// The last page of the deck: a placeholder until real suggestions exist.
/// The body sits in a dashed box so nobody takes it for finished content.
class SlideSuggestions extends StatelessWidget {
  const SlideSuggestions({
    super.key,
    required this.periodLabel,
    this.texts = DeckTexts.empty,
  });

  final String periodLabel;
  final DeckTexts texts;

  @override
  Widget build(BuildContext context) {
    final w = SlideWords(texts);
    final body = w.suggestionsBody;
    TextStyle bodyStyle(double size) =>
        st(size, color: SlidePalette.panelText, height: 1.35);
    return PersonSlideFrame(
      background: SlidePalette.navy,
      footerColor: SlidePalette.mutedOnDark,
      source: _footer(w),
      heading: SlideHeading(
        eyebrow: periodLabel,
        title: w.suggestionsTitle,
        eyebrowColor: SlidePalette.orange,
        titleColor: SlidePalette.paper,
      ),
      body: LayoutBuilder(
        builder: (context, box) {
          final size = _pickSize(body, box.maxHeight - 64, bodyStyle);
          return CustomPaint(
            painter: const _DashedBox(),
            child: Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 64,
                  vertical: 32,
                ),
                child: Text(
                  body,
                  textAlign: TextAlign.center,
                  style: bodyStyle(size),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  /// The biggest size in which the whole text fits the box, down to 20 px.
  double _pickSize(
    String body,
    double height,
    TextStyle Function(double) style,
  ) {
    for (final z in _bodySizes) {
      final m = measureText(body, style(z), _bodyWidth);
      if (m.height <= height && m.width <= _bodyWidth + 0.5) return z;
    }
    return _bodySizes.last;
  }

  // The footer of the other pages says "{team} team"; this page has no team,
  // so it only names the meeting and the period.
  String _footer(SlideWords w) => '${w.title(periodLabel)} · $periodLabel';
}

class _DashedBox extends CustomPainter {
  const _DashedBox();

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = SlidePalette.mutedOnDark
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;
    final rrect = RRect.fromRectAndRadius(
      Offset.zero & size,
      const Radius.circular(24),
    ).deflate(1.5);
    final path = Path()..addRRect(rrect);
    for (final m in path.computeMetrics()) {
      var d = 0.0;
      while (d < m.length) {
        canvas.drawPath(m.extractPath(d, d + 18), paint);
        d += 18 + 14;
      }
    }
  }

  @override
  bool shouldRepaint(_DashedBox old) => false;
}
