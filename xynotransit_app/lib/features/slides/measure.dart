import 'package:flutter/painting.dart';

/// What a text needs in a given width. Slides measure the same words again
/// and again (the layout picks type sizes by measuring), so results are kept:
/// typing in the form changes numbers, not the target texts.
class TextMeasure {
  const TextMeasure({
    required this.height,
    required this.width,
    required this.lines,
    required this.exceeded,
  });

  /// Height of the laid out text.
  final double height;

  /// Width of the widest line.
  final double width;
  final int lines;

  /// True when [maxLines] cut the text.
  final bool exceeded;
}

final _cache = <(String, TextStyle, double, int?), TextMeasure>{};

/// Lays out [text] in [maxWidth] (infinity: one line as long as it is).
TextMeasure measureText(
  String text,
  TextStyle style,
  double maxWidth, {
  int? maxLines,
}) {
  final key = (text, style, maxWidth, maxLines);
  final hit = _cache[key];
  if (hit != null) return hit;
  final p = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: TextDirection.ltr,
    maxLines: maxLines,
  )..layout(maxWidth: maxWidth);
  var widest = 0.0;
  final metrics = p.computeLineMetrics();
  for (final m in metrics) {
    if (m.width > widest) widest = m.width;
  }
  final r = TextMeasure(
    height: p.height,
    width: widest,
    lines: metrics.length,
    exceeded: p.didExceedMaxLines,
  );
  p.dispose();
  if (_cache.length > 4000) _cache.clear();
  _cache[key] = r;
  return r;
}
