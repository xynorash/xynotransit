import 'package:flutter/material.dart';

import '../../core/theme/tokens.dart' show XynoTokens;
import '../../domain/enums.dart';

/// Fixed slide colours. Slides never follow light or dark mode.
abstract final class SlidePalette {
  static const navy = Color(0xFF14213D);
  static const paper = Color(0xFFF4F1EA);
  static const card = Color(0xFFFFFDF8);
  static const cardBorder = Color(0xFFDDD8CA);
  static const ink = Color(0xFF14213D);
  static const blue = Color(0xFF1D5FD1);
  static const orange = Color(0xFFF0933A);
  static const green = Color(0xFF17785F);
  static const rust = Color(0xFFB8400A);
  static const panelText = Color(0xFFD5DBE8);
  static const mutedOnLight = Color(0xFF5F6573);
  static const mutedOnDark = Color(0xFFAEB6C7);
  static const axis = Color(0xFF3A4A6B);
  static const white = Color(0xFFFBFBF8);
  static const noteRule = Color(0xFFD8D3C4);
  static const emptyNote = Color(0xFF6A7185);

  static const series = XynoTokens.series;

  static Color seriesColor(int i) => series[i % series.length];

  static const met = Color(0xFF17785F);
  static const partly = Color(0xFF8A5A00);
  static const missed = Color(0xFFB8400A);
  static const unanswered = Color(0xFF566175);

  static Color statusColor(KpiStatus? s) => switch (s) {
    KpiStatus.met => met,
    KpiStatus.partly => partly,
    KpiStatus.missed => missed,
    null => unanswered,
  };

  static String statusWord(KpiStatus? s) => switch (s) {
    KpiStatus.met => 'MET',
    KpiStatus.partly => 'PARTLY',
    KpiStatus.missed => 'MISSED',
    null => 'NOT ANSWERED',
  };
}
