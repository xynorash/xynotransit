import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart' show Colors;

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

double _contrast(Color a, Color b) {
  final la = a.computeLuminance(), lb = b.computeLuminance();
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

void main() {
  final series = [for (var i = 0; i < 8; i++) seriesColor(i)];
  final status = [SlidePalette.met, SlidePalette.partly, SlidePalette.missed];
  final onNavy = [
    SlidePalette.metOnNavy,
    SlidePalette.partlyOnNavy,
    SlidePalette.missedOnNavy,
  ];
  for (final sim in _sims.keys) {
    test('series colours stay apart under $sim (Lab distance >= 12)', () {
      expect(minDistance(series, sim), greaterThanOrEqualTo(12));
    });
    test('status colours on slide cards stay apart under $sim', () {
      expect(minDistance(status, sim), greaterThanOrEqualTo(12));
    });
    test('status colours on the navy panel stay apart under $sim', () {
      expect(minDistance(onNavy, sim), greaterThanOrEqualTo(12));
    });
  }

  test('series 1 to 3 keep the blue, orange and green look', () {
    expect(series[0], const Color(0xFF6FB1FF));
    expect(series[1], const Color(0xFFF0933A));
    expect(series[2], const Color(0xFF5FD3B0));
  });

  test('every series colour reads on navy (text 4.5, bars 3)', () {
    for (final c in series) {
      expect(_contrast(c, SlidePalette.navy), greaterThanOrEqualTo(4.5));
      expect(_contrast(c, const Color(0xFF0D1526)), greaterThanOrEqualTo(4.5));
    }
  });

  test('status chips: white text reads on each colour', () {
    for (final c in status) {
      expect(_contrast(Colors.white, c), greaterThanOrEqualTo(4.5));
      expect(_contrast(c, SlidePalette.card), greaterThanOrEqualTo(4.5));
    }
  });
}
