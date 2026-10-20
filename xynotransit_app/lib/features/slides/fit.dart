import 'dart:math' as math;

import 'package:flutter/painting.dart';

import '../../core/theme/tokens.dart' show XynoTokens;
import 'measure.dart';

/// How the KPI column of slide A is laid out so every target fits.
class KpiFit {
  const KpiFit({
    required this.width,
    required this.fontSize,
    this.dense = false,
  });

  /// Width of the KPI column.
  final double width;

  final double fontSize;

  /// True when no card layout can show every word in full: the slide then
  /// uses the two column grid, where a text may end with an ellipsis.
  final bool dense;

  @override
  bool operator ==(Object other) =>
      other is KpiFit &&
      other.width == width &&
      other.fontSize == fontSize &&
      other.dense == dense;

  @override
  int get hashCode => Object.hash(width, fontSize, dense);

  @override
  String toString() =>
      'KpiFit(w: $width, fs: $fontSize${dense ? ', dense' : ''})';
}

const kpiGap = 16.0;

/// Height of the target area when the heading is one line high. The slide
/// measures the real height and passes it as `area` when it differs.
const kpiAreaHeight = 620.0;

/// Width of the two-column grid used for seven to ten targets.
const kpiGridWidth = 800.0;

const _sizes = [40.0, 36.0, 32.0, 30.0, 28.0, 26.0, 24.0];

/// Column width and the sizes to try (null: the usual ladder, which depends on
/// how many targets there are). Every card has the status chip on its left.
const _modes = <(double, List<double>?)>[
  // Three or four targets try a narrower column first, which leaves the volumes
  // chart more room (8 counts with long names need it).
  (600.0, null),
  (760.0, null),
  // Long texts: smaller type, then a wider column. Never below 20 px.
  (760.0, [22.0, 20.0]),
  (900.0, [24.0, 22.0, 20.0]),
];
const _fallback = KpiFit(width: 760, fontSize: 24, dense: true);

/// One or two targets are few: their text gets a bigger size so the cards do
/// not look empty.
List<double> kpiSizes(int n) => switch (n) {
  1 => const [56.0, 52.0, 48.0, 44.0, ..._sizes],
  2 => const [48.0, 44.0, ..._sizes],
  _ => _sizes,
};

/// Width of the status chip beside the text of a card, and the padding of
/// that card. The chip may take two lines ("NOT ANSWERED").
const kpiChipWidth = 148.0;
const kpiChipPad = 10.0;

/// A chip never grows taller than this, however tall its card is.
const kpiChipMaxHeight = 124.0;
const kpiChipMinHeight = 2 * kpiChipPad + 58;

TextStyle kpiTextStyle(double size) => TextStyle(
  fontFamily: XynoTokens.sans,
  fontSize: size,
  fontWeight: FontWeight.w700,
  height: 1.2,
  leadingDistribution: TextLeadingDistribution.even,
);

/// Height one card needs for [text], measured with the real font.
double kpiNeed(String text, KpiFit f) {
  // The card has a 1 px border on every side: it takes 2 px of the width the
  // text may use and 2 px of the height.
  const border = 2.0;
  final tw = f.width - 56 - kpiChipWidth - 16 - border;
  final h = measureText(text, kpiTextStyle(f.fontSize), tw).height;
  return border + math.max(2 * kpiChipPad + h, kpiChipMinHeight);
}

/// First layout whose tallest card fits the height each card gets.
KpiFit fitKpis(List<String> texts, {double area = kpiAreaHeight}) {
  final n = texts.length;
  if (n == 0) return _fallback;
  final avail = (area - (n - 1) * kpiGap) / n;
  for (final (w, sizes) in _modes) {
    if (w < 760 && (n < 3 || n > 4)) continue;
    for (final fs in sizes ?? kpiSizes(n)) {
      final fit = KpiFit(width: w, fontSize: fs);
      if (texts.every((t) => kpiNeed(t, fit) <= avail)) return fit;
    }
  }
  return _fallback;
}
