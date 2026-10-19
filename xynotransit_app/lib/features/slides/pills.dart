import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'canvas.dart';
import 'measure.dart';

/// The rounded labels at the bottom of the cover and the dividers.
///
/// The row of pills has a fixed amount of room. The plan picks the biggest
/// type (never below 20 px) in which every pill fits; when even that is too
/// much it keeps the first ones and ends with a "+N more" pill, so the count
/// is never hidden and nothing runs off the slide.
class PillPlan {
  const PillPlan({
    required this.texts,
    required this.hidden,
    required this.size,
    required this.height,
    required this.lines,
  });

  /// The labels to draw, including the "+N more" one when [hidden] > 0.
  final List<String> texts;
  final int hidden;
  final double size;
  final double height;

  /// Lines of each pill (2 only for a label wider than the slide).
  final List<int> lines;
}

const _sizes = [32.0, 28.0, 26.0, 24.0, 22.0, 20.0];

TextStyle pillStyle(double size, Color ink) =>
    st(size, weight: FontWeight.w500, color: ink);

double pillSpacing(double size) => size >= 28 ? 16 : 12;
double pillPadV(double size) => size >= 28 ? 12 : 8;
double pillPadH(double size) => size >= 28 ? 28 : 20;

String moreWord(int n) => '+$n more';

({double width, double height, int lines}) _pill(
  String text,
  double size,
  double maxWidth,
) {
  final padH = pillPadH(size);
  final m = measureText(
    text,
    pillStyle(size, Colors.black),
    maxWidth - 2 * padH,
    maxLines: 2,
  );
  final w = math.min(maxWidth, m.width + 2 * padH);
  final h = m.height + 2 * pillPadV(size);
  return (width: w, height: h, lines: math.max(1, m.lines));
}

/// Height of [texts] laid out like a Wrap with the given size.
({double height, List<int> lines}) _flow(
  List<String> texts,
  double size,
  double maxWidth,
) {
  final gap = pillSpacing(size);
  var rows = 0;
  var rowW = 0.0;
  var rowH = 0.0;
  var total = 0.0;
  final lines = <int>[];
  for (final t in texts) {
    final m = _pill(t, size, maxWidth);
    lines.add(m.lines);
    if (rowW > 0 && rowW + gap + m.width > maxWidth + 0.001) {
      total += rowH;
      rows++;
      rowW = 0;
      rowH = 0;
    }
    rowW += (rowW > 0 ? gap : 0) + m.width;
    rowH = math.max(rowH, m.height);
  }
  if (texts.isNotEmpty) {
    total += rowH;
    rows++;
  }
  return (height: total + math.max(0, rows - 1) * gap, lines: lines);
}

PillPlan planPills(
  List<String> all, {
  required double maxHeight,
  double maxWidth = slideTextWidth,
}) {
  if (all.isEmpty) {
    return const PillPlan(texts: [], hidden: 0, size: 32, height: 0, lines: []);
  }
  for (final size in _sizes) {
    final f = _flow(all, size, maxWidth);
    if (f.height <= maxHeight) {
      return PillPlan(
        texts: all,
        hidden: 0,
        size: size,
        height: f.height,
        lines: f.lines,
      );
    }
  }
  // Too many for the room: the first ones and a "+N more" pill, at 20 px.
  const size = 20.0;
  for (var k = all.length - 1; k >= 1; k--) {
    final shown = [...all.take(k), moreWord(all.length - k)];
    final f = _flow(shown, size, maxWidth);
    if (f.height <= maxHeight) {
      return PillPlan(
        texts: shown,
        hidden: all.length - k,
        size: size,
        height: f.height,
        lines: f.lines,
      );
    }
  }
  final shown = [moreWord(all.length)];
  final f = _flow(shown, size, maxWidth);
  return PillPlan(
    texts: shown,
    hidden: all.length,
    size: size,
    height: f.height,
    lines: f.lines,
  );
}

/// Draws a [PillPlan].
class PillWrap extends StatelessWidget {
  const PillWrap({
    super.key,
    required this.plan,
    required this.fill,
    required this.ink,
    this.maxWidth = slideTextWidth,
  });

  final PillPlan plan;
  final Color fill;
  final Color ink;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final gap = pillSpacing(plan.size);
    return Wrap(
      spacing: gap,
      runSpacing: gap,
      children: [
        for (var i = 0; i < plan.texts.length; i++)
          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxWidth),
            child: Container(
              padding: EdgeInsets.symmetric(
                vertical: pillPadV(plan.size),
                horizontal: pillPadH(plan.size),
              ),
              decoration: BoxDecoration(
                color: fill,
                borderRadius: BorderRadius.circular(
                  plan.lines[i] == 1 ? 999 : 28,
                ),
              ),
              child: Text(
                plan.texts[i],
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: pillStyle(plan.size, ink),
              ),
            ),
          ),
      ],
    );
  }
}
