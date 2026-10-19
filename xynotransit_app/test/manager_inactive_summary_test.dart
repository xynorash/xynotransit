import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xynotransit_app/domain/summary.dart';
import 'package:xynotransit_app/features/summary/summary_provider.dart';

import 'helpers.dart';
import 'summary_test.dart' show Ctx, pumpOverview, tileValue;

/// Switches off everybody but the manager and Rova, like the defect report:
/// two seats expected, twelve reports from people who are off.
Future<Ctx> mostSwitchedOff(
  WidgetTester tester, {
  Size size = const Size(1500, 5200),
}) async {
  final c = await pumpOverview(tester, size: size);
  for (final p in c.repo.currentPersons) {
    if (p.id == 'p-shalini' || p.id == 'p-rova') continue;
    await c.repo.savePerson(
      id: p.id,
      fullName: p.fullName,
      email: '',
      role: p.appRole,
      active: false,
    );
  }
  // The summary reloads shortly after the catalog changes.
  await tester.pump(summaryDebounce + const Duration(milliseconds: 100));
  await tester.pumpAndSettle();
  return Ctx(
    c.repo,
    c.container,
    await c.container.read(summaryProvider.future),
  );
}

void main() {
  setUpAll(loadAppFonts);

  testWidgets('submitted never passes expected, in tiles and team rows', (
    tester,
  ) async {
    final c = await mostSwitchedOff(tester);
    final s = c.summary;
    expect(s.expected, 2);
    expect(s.submitted, 2);
    expect(s.submittedInactive, 12);
    expect(tileValue(tester, 'reports'), '2 of 2');
    expect(
      find.text('sent so far, plus 12 from switched-off people'),
      findsOneWidget,
    );
    for (final t in s.teams) {
      expect(t.submitted, lessThanOrEqualTo(t.expected), reason: t.name);
    }
    // The donut says 100 percent, not 600.
    expect(
      find.byWidgetPredicate(
        (w) => w is Text && w.data == '100%' && w.style?.fontSize == 24,
      ),
      findsOneWidget,
      reason: 'donut',
    );
    // Every "N of M" of the team bars has N <= M.
    for (final m in RegExp(r'(\d+) of (\d+)(?= ·|$)').allMatches(
      tester
          .widgetList<Text>(find.byType(Text))
          .map((w) => w.data ?? '')
          .where((t) => RegExp(r'^\d+ of \d+( · \+\d+ inactive)?$').hasMatch(t))
          .join('\n'),
    )) {
      expect(int.parse(m.group(1)!), lessThanOrEqualTo(int.parse(m.group(2)!)));
    }
    expect(find.textContaining('12 more reports are from'), findsWidgets);
  });

  testWidgets('switched-off people are rows tagged Inactive, never missing', (
    tester,
  ) async {
    final c = await mostSwitchedOff(tester);
    final off = c.summary.people.where((p) => !p.active).toList();
    expect(off.length, 12);
    for (final p in off) {
      expect(p.submitted, isTrue);
      final tag = find.byKey(ValueKey('inactive-${p.assignmentId}'));
      await tester.ensureVisible(
        find.byKey(ValueKey('person-row-${p.assignmentId}')),
      );
      expect(tag, findsOneWidget, reason: p.name);
    }
    // Everybody expected has sent: nobody is missing.
    expect(tileValue(tester, 'missing'), '0');
    expect(find.byKey(const ValueKey('missing-card')), findsNothing);
  });

  testWidgets('the missing list names the seat of a two-seat person', (
    tester,
  ) async {
    final c = await pumpOverview(tester, demo: false);
    final people = c.summary.people;
    // No reports at all: everybody is missing, two seats belong to Tahina.
    expect(people.where((p) => p.name == 'Tahina').length, 2);
    final card = find.byKey(const ValueKey('missing-card'));
    expect(card, findsOneWidget);
    final texts = tester
        .widgetList<Text>(
          find.descendant(of: card, matching: find.byType(Text)),
        )
        .map((t) => t.data ?? '')
        .join(' | ');
    final tahinas = people.where((p) => p.name == 'Tahina').toList();
    for (final p in tahinas) {
      expect(texts, contains('Tahina · ${p.role} (${p.team})'));
    }
    // A person with one seat keeps the short form.
    expect(texts, contains('Rova (Tana)'));
    expect(texts, isNot(contains('Rova · ')));
  });

  testWidgets('narrow phone: tiles and rows fit with switched-off people', (
    tester,
  ) async {
    await mostSwitchedOff(tester, size: const Size(390, 6000));
    expect(tester.takeException(), isNull);
  });

  test('PersonSummary of an off person round trips', () {
    final p = PersonSummary.fromJson({
      'assignment_id': 'a',
      'name': 'N',
      'role': 'R',
      'team': 'T',
      'submitted': true,
      'active': false,
      'met': 0,
      'partly': 0,
      'missed': 0,
      'volume_total': 0,
    });
    expect(p.active, isFalse);
    expect(p.toJson()['active'], false);
  });
}
