import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xynotransit_app/app/providers.dart';

void main() {
  ProviderContainer make(DateTime now) {
    final c = ProviderContainer(
      overrides: [clockProvider.overrideWithValue(() => now)],
    );
    addTearDown(c.dispose);
    return c;
  }

  test('the default is the three months that ended most recently', () {
    expect(
      make(DateTime(2026, 10, 19)).read(periodSelectionProvider),
      DateTime(2026, 7),
    );
    expect(
      make(DateTime(2027, 1, 3)).read(periodSelectionProvider),
      DateTime(2026, 10),
    );
  });

  test('a start month is always the first of a month', () {
    final c = make(DateTime(2026, 10, 19));
    c.read(periodSelectionProvider.notifier).select(DateTime(2026, 2, 17, 13));
    expect(c.read(periodSelectionProvider), DateTime(2026, 2));
  });

  test('the page never asks for a month the server refuses', () {
    final c = make(DateTime(2026, 10, 19));
    final n = c.read(periodSelectionProvider.notifier);
    n.select(DateTime(1999, 12));
    expect(c.read(periodSelectionProvider), DateTime(2000));
    n.select(DateTime(2101));
    expect(c.read(periodSelectionProvider), DateTime(2100, 12));
    n.select(DateTime(2100, 12));
    expect(c.read(periodSelectionProvider), DateTime(2100, 12));
    // And the default, if the clock is absurd.
    expect(
      make(DateTime(2000, 2, 1)).read(periodSelectionProvider),
      DateTime(2000),
    );
    expect(
      make(DateTime(2104, 6, 1)).read(periodSelectionProvider),
      DateTime(2100, 12),
    );
  });
}
