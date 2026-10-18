import 'package:flutter/material.dart';

/// Colours and type of the form UI. Slides have their own fixed palette.
@immutable
class XynoTokens extends ThemeExtension<XynoTokens> {
  const XynoTokens({
    required this.bg,
    required this.surface,
    required this.ink,
    required this.muted,
    required this.line,
    required this.accent,
    required this.onAccent,
    required this.soft,
    required this.ok,
    required this.onOk,
    required this.warn,
    required this.onWarn,
    required this.bad,
    required this.onBad,
    required this.flash,
  });

  final Color bg;
  final Color surface;
  final Color ink;
  final Color muted;
  final Color line;
  final Color accent;
  final Color onAccent;
  final Color soft;
  final Color ok;
  final Color onOk;
  final Color warn;
  final Color onWarn;
  final Color bad;
  final Color onBad;
  final Color flash;

  static const light = XynoTokens(
    bg: Color(0xFFF1F4F8),
    surface: Color(0xFFFFFFFF),
    ink: Color(0xFF14213D),
    muted: Color(0xFF566175),
    line: Color(0xFFD3DAE6),
    accent: Color(0xFF1D5FD1),
    onAccent: Color(0xFFFFFFFF),
    soft: Color(0xFFE6EDFA),
    ok: Color(0xFF17785F),
    onOk: Color(0xFFFFFFFF),
    warn: Color(0xFF8A5A00),
    onWarn: Color(0xFFFFFFFF),
    bad: Color(0xFFB8400A),
    onBad: Color(0xFFFFFFFF),
    flash: Color(0xFFDDF3EA),
  );

  static const dark = XynoTokens(
    bg: Color(0xFF0D1526),
    surface: Color(0xFF16213A),
    ink: Color(0xFFE8ECF4),
    muted: Color(0xFFA5B0C5),
    line: Color(0xFF2B3956),
    accent: Color(0xFF7AA9FF),
    onAccent: Color(0xFF0D1526),
    soft: Color(0xFF1D2E50),
    ok: Color(0xFF4CC2A0),
    onOk: Color(0xFF0D1526),
    warn: Color(0xFFE5B84A),
    onWarn: Color(0xFF0D1526),
    bad: Color(0xFFF08A5D),
    onBad: Color(0xFF0D1526),
    flash: Color(0xFF1F4A45),
  );

  /// Series colours: blue, orange, green, then five more. Shared by the form
  /// dots and the slides.
  static const series = [
    Color(0xFF6FB1FF),
    Color(0xFFF0933A),
    Color(0xFF5FD3B0),
    Color(0xFFE879A8),
    Color(0xFFB59CFF),
    Color(0xFFF0C24A),
    Color(0xFF4FC6E0),
    Color(0xFFA3D45B),
  ];

  static const sans = 'DM Sans';
  static const mono = 'IBM Plex Mono';

  Color statusFill(String status) => switch (status) {
    'met' => ok,
    'partly' => warn,
    _ => bad,
  };

  Color statusOn(String status) => switch (status) {
    'met' => onOk,
    'partly' => onWarn,
    _ => onBad,
  };

  @override
  XynoTokens copyWith() => this;

  @override
  XynoTokens lerp(ThemeExtension<XynoTokens>? other, double t) {
    if (other is! XynoTokens) return this;
    Color l(Color a, Color b) => Color.lerp(a, b, t)!;
    return XynoTokens(
      bg: l(bg, other.bg),
      surface: l(surface, other.surface),
      ink: l(ink, other.ink),
      muted: l(muted, other.muted),
      line: l(line, other.line),
      accent: l(accent, other.accent),
      onAccent: l(onAccent, other.onAccent),
      soft: l(soft, other.soft),
      ok: l(ok, other.ok),
      onOk: l(onOk, other.onOk),
      warn: l(warn, other.warn),
      onWarn: l(onWarn, other.onWarn),
      bad: l(bad, other.bad),
      onBad: l(onBad, other.onBad),
      flash: l(flash, other.flash),
    );
  }
}

/// Colour of count number [i]; repeats after eight.
Color seriesColor(int i) => XynoTokens.series[i % XynoTokens.series.length];

extension TokensContext on BuildContext {
  XynoTokens get tokens => Theme.of(this).extension<XynoTokens>()!;
}
