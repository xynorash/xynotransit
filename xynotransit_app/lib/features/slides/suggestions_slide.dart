import 'package:flutter/material.dart';

import '../../domain/deck_text.dart';
import 'canvas.dart';
import 'palette.dart';
import 'slide_words.dart';

const _bodySteps = <FitStep>[
  (48, 4),
  (44, 5),
  (40, 6),
  (36, 7),
  (32, 8),
  (28, 10),
  (26, 11),
];
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
    final b = pickFit(body, _bodyWidth, _bodySteps, bodyStyle);
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
      body: CustomPaint(
        painter: const _DashedBox(),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 64, vertical: 32),
            child: Text(
              body,
              textAlign: TextAlign.center,
              maxLines: b.$2,
              overflow: TextOverflow.ellipsis,
              style: bodyStyle(b.$1),
            ),
          ),
        ),
      ),
    );
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
