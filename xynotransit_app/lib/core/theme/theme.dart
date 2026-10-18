import 'package:flutter/material.dart';

import 'tokens.dart';

ThemeData buildTheme(Brightness brightness) {
  final t = brightness == Brightness.dark ? XynoTokens.dark : XynoTokens.light;
  final scheme = ColorScheme(
    brightness: brightness,
    primary: t.accent,
    onPrimary: t.onAccent,
    secondary: t.soft,
    onSecondary: t.ink,
    error: t.bad,
    onError: t.onBad,
    surface: t.surface,
    onSurface: t.ink,
  );
  final base = ThemeData(
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: t.bg,
    fontFamily: XynoTokens.sans,
    useMaterial3: true,
    splashFactory: NoSplash.splashFactory,
    extensions: [t],
  );
  final text = base.textTheme.apply(
    bodyColor: t.ink,
    displayColor: t.ink,
    fontFamily: XynoTokens.sans,
  );
  return base.copyWith(
    textTheme: text.copyWith(
      bodyLarge: text.bodyLarge!.copyWith(fontSize: 17, height: 1.5),
      bodyMedium: text.bodyMedium!.copyWith(fontSize: 17, height: 1.5),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: t.surface,
      foregroundColor: t.ink,
      elevation: 0,
      scrolledUnderElevation: 0,
      shape: Border(bottom: BorderSide(color: t.line)),
      titleTextStyle: TextStyle(
        fontFamily: XynoTokens.sans,
        fontSize: 18,
        fontWeight: FontWeight.w700,
        color: t.ink,
      ),
    ),
    dividerColor: t.line,
    focusColor: t.accent,
  );
}
