import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/repository.dart';
import '../domain/catalog.dart';
import '../domain/deck.dart';
import '../domain/deck_text.dart';
import '../domain/period.dart';
import '../domain/report.dart';

final repositoryProvider = Provider<Repository>(
  (ref) => throw UnimplementedError('repository'),
);
final authServiceProvider = Provider<AuthService>(
  (ref) => throw UnimplementedError('auth'),
);
final prefsProvider = Provider<SharedPreferences>(
  (ref) => throw UnimplementedError('prefs'),
);

/// Fixed "today", overridden in tests.
final clockProvider = Provider<DateTime Function()>((ref) => DateTime.now);

/// The first and last month a period can start in. The server refuses
/// anything outside the years 2000 to 2100, so the page never asks for it.
final firstPeriodStart = DateTime(2000);
final lastPeriodStart = DateTime(2100, 12);

DateTime clampPeriodStart(DateTime start) {
  final month = DateTime(start.year, start.month);
  if (month.isBefore(firstPeriodStart)) return firstPeriodStart;
  if (month.isAfter(lastPeriodStart)) return lastPeriodStart;
  return month;
}

/// Start month of the period shown on the page.
class PeriodSelection extends Notifier<DateTime> {
  @override
  DateTime build() => clampPeriodStart(
    ref.read(initialStartProvider) ??
        Period.defaultStart(ref.read(clockProvider)()),
  );

  void select(DateTime start) => state = clampPeriodStart(start);
}

/// Where the first open of the app lands. Demo mode opens on the demo period.
final initialStartProvider = Provider<DateTime?>((ref) => null);

final periodSelectionProvider = NotifierProvider<PeriodSelection, DateTime>(
  PeriodSelection.new,
);

/// The active teams, people and seats. Follows every admin write.
final catalogProvider = StreamProvider<Catalog>(
  (ref) => ref.watch(repositoryProvider).watchCatalog(),
);

/// Same, with the inactive people and seats a manager can bring back.
final catalogWithInactiveProvider = StreamProvider<Catalog>(
  (ref) => ref.watch(repositoryProvider).watchCatalog(includeInactive: true),
);

final userProvider = StreamProvider<AppUser?>(
  (ref) => ref.watch(authServiceProvider).userChanges,
);

final isControllerProvider = Provider<bool>(
  (ref) => ref.watch(userProvider).value?.isController ?? false,
);

final periodProvider = FutureProvider<Period>((ref) {
  final start = ref.watch(periodSelectionProvider);
  return ref.watch(repositoryProvider).ensurePeriod(start);
});

/// All reports of the shown period, live.
final reportsProvider = StreamProvider<List<Report>>((ref) async* {
  final period = await ref.watch(periodProvider.future);
  yield* ref.watch(repositoryProvider).watchReports(period.id);
});

/// Latest generated deck of the shown period, live.
final deckProvider = StreamProvider<DeckRun?>((ref) async* {
  final period = await ref.watch(periodProvider.future);
  yield* ref.watch(repositoryProvider).watchDeck(period.id);
});

/// Words of the deck for the shown period (managers only). Invalidate it after
/// a save to read the stored words again.
final deckTextsProvider = FutureProvider<DeckTextsState>((ref) async {
  final period = await ref.watch(periodProvider.future);
  return ref.watch(repositoryProvider).loadDeckTexts(period.id);
});

class ThemeModeController extends Notifier<ThemeMode> {
  @override
  ThemeMode build() => ThemeMode.system;

  void toggle(Brightness current) =>
      state = current == Brightness.dark ? ThemeMode.light : ThemeMode.dark;
}

final themeModeProvider = NotifierProvider<ThemeModeController, ThemeMode>(
  ThemeModeController.new,
);
