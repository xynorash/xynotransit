import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_web_plugins/url_strategy.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app/app.dart';
import 'app/bootstrap.dart';
import 'app/config.dart';
import 'app/providers.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  usePathUrlStrategy();
  _ignoreFocusBeforeFirstLayout();
  final prefs = await SharedPreferences.getInstance();
  final backend = await createBackend(prefs);
  runApp(
    ProviderScope(
      overrides: [
        prefsProvider.overrideWithValue(prefs),
        repositoryProvider.overrideWithValue(backend.repository),
        authServiceProvider.overrideWithValue(backend.auth),
        initialStartProvider.overrideWithValue(backend.initialStart),
        demoNoticeAvailableProvider.overrideWithValue(AppConfig.demo),
      ],
      child: const XynotransitApp(),
    ),
  );
}

/// The browser can tell Flutter that the page has focus before the first
/// frame is laid out. Flutter then looks for a first widget to focus, reads
/// the size of a box that has none yet, and logs an error (framework issue,
/// harmless: nothing is lost and the next focus change works). This hides only
/// that one report, so the console of a healthy page stays empty; every other
/// error goes where it went before.
void _ignoreFocusBeforeFirstLayout() {
  final previous = FlutterError.onError;
  FlutterError.onError = (details) {
    final where = details.context?.toString() ?? '';
    if (where.contains('didChangeViewFocus') &&
        details.exception.toString().contains('RenderBox was not laid out')) {
      return;
    }
    (previous ?? FlutterError.presentError)(details);
  };
}
