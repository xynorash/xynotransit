import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'app_test.dart' show pumpApp;
import 'generate_partial_test.dart' show sendRova;

void main() {
  testWidgets('CSV button is disabled until a report is sent, then enabled', (
    tester,
  ) async {
    final h = await pumpApp(
      tester,
      size: const Size(1500, 900),
      location: '/manager/reports',
    );
    FilledButton button() => tester.widget<FilledButton>(
      find.ancestor(
        of: find.text('Export data (CSV)'),
        matching: find.byType(FilledButton),
      ),
    );
    expect(find.text('Export data (CSV)'), findsOneWidget);
    expect(button().onPressed, isNull);
    await sendRova(tester, h);
    expect(button().onPressed, isNotNull);
  });
}
