import 'dart:math' as math;

/// How the KPI column of slide A is laid out so every target fits.
class KpiFit {
  const KpiFit({
    required this.width,
    required this.label,
    required this.fontSize,
  });

  /// Width of the KPI column.
  final double width;

  /// True: status label above the text. False: status chip beside the text.
  final bool label;
  final double fontSize;

  @override
  bool operator ==(Object other) =>
      other is KpiFit &&
      other.width == width &&
      other.label == label &&
      other.fontSize == fontSize;

  @override
  int get hashCode => Object.hash(width, label, fontSize);

  @override
  String toString() => 'KpiFit(w: $width, label: $label, fs: $fontSize)';
}

const kpiGap = 16.0;
const kpiAreaHeight = 620.0;

/// Width of the two-column grid used for seven to ten targets.
const kpiGridWidth = 800.0;

const _modes = [(600.0, true), (760.0, true), (760.0, false)];
const _sizes = [40.0, 36.0, 32.0, 30.0, 28.0, 26.0, 24.0];
const _fallback = KpiFit(width: 760, label: false, fontSize: 24);

/// Height one card needs for [text].
double kpiNeed(String text, KpiFit f) {
  final tw = f.label ? f.width - 80 : f.width - 56 - 140;
  final lines = (text.length * 0.56 * f.fontSize * 1.06 / tw).ceil();
  return (f.label ? 48 + 34 + 6 : 40) + lines * f.fontSize * 1.2;
}

/// First layout whose tallest card fits the height each card gets.
KpiFit fitKpis(List<String> texts) {
  final n = texts.length;
  if (n == 0) return _fallback;
  final avail = (kpiAreaHeight - (n - 1) * kpiGap) / n;
  for (final (w, lab) in _modes) {
    for (final fs in _sizes) {
      final fit = KpiFit(width: w, label: lab, fontSize: fs);
      final worst = texts.map((t) => kpiNeed(t, fit)).reduce(math.max);
      if (worst <= avail) return fit;
    }
  }
  return _fallback;
}
