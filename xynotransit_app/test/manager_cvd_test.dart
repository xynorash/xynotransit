import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:xynotransit_app/core/theme/tokens.dart';
import 'package:xynotransit_app/features/slides/palette.dart';

double _lin(double c) =>
    c <= 0.04045 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4).toDouble();

List<double> _lab(List<double> rgb) {
  final r = rgb[0], g = rgb[1], b = rgb[2];
  final x = (0.4124 * r + 0.3576 * g + 0.1805 * b) / 0.95047;
  final y = 0.2126 * r + 0.7152 * g + 0.0722 * b;
  final z = (0.0193 * r + 0.1192 * g + 0.9505 * b) / 1.08883;
  double f(double t) =>
      t > 0.008856 ? math.pow(t, 1 / 3).toDouble() : 7.787 * t + 16 / 116;
  return [116 * f(y) - 16, 500 * (f(x) - f(y)), 200 * (f(y) - f(z))];
}

// Machado et al. 2009, severity 1.0, linear RGB.
const _sims = {
  'protanopia': [
    [0.152286, 1.052583, -0.204868],
    [0.114503, 0.786281, 0.099216],
    [-0.003882, -0.048116, 1.051998],
  ],
  'deuteranopia': [
    [0.367322, 0.860646, -0.227968],
    [0.280085, 0.672501, 0.047413],
    [-0.011820, 0.042940, 0.968881],
  ],
  'tritanopia': [
    [1.255528, -0.076749, -0.178779],
    [-0.078411, 0.930809, 0.147602],
    [0.004733, 0.691367, 0.303900],
  ],
  'normal': [
    [1.0, 0.0, 0.0],
    [0.0, 1.0, 0.0],
    [0.0, 0.0, 1.0],
  ],
};

List<double> _seen(Color c, List<List<double>> m) {
  final v = [_lin(c.r), _lin(c.g), _lin(c.b)];
  return [
    for (final row in m)
      (row[0] * v[0] + row[1] * v[1] + row[2] * v[2]).clamp(0.0, 1.0),
  ];
}

double _dE(List<double> a, List<double> b) => math.sqrt(
  math.pow(a[0] - b[0], 2) +
      math.pow(a[1] - b[1], 2) +
      math.pow(a[2] - b[2], 2),
);

double minDistance(List<Color> colors, String sim) {
  final labs = [for (final c in colors) _lab(_seen(c, _sims[sim]!))];
  var best = 1e9;
  for (var i = 0; i < labs.length; i++) {
    for (var j = i + 1; j < labs.length; j++) {
      best = math.min(best, _dE(labs[i], labs[j]));
    }
  }
  return best;
}

void main() {
  final series = [for (var i = 0; i < 8; i++) seriesColor(i)];
  final status = [SlidePalette.met, SlidePalette.partly, SlidePalette.missed];
  for (final sim in _sims.keys) {
    test('report distances $sim', () {
      // ignore: avoid_print
      print(
        '$sim series=${minDistance(series, sim).toStringAsFixed(1)} '
        'status=${minDistance(status, sim).toStringAsFixed(1)}',
      );
    });
  }
}
