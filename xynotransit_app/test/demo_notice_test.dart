import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xynotransit_app/app/app.dart';
import 'package:xynotransit_app/app/providers.dart';
import 'package:xynotransit_app/core/theme/theme.dart';

Widget host({required bool demo}) => ProviderScope(
  overrides: [demoNoticeAvailableProvider.overrideWithValue(demo)],
  child: MaterialApp(
    theme: buildTheme(Brightness.light),
    builder: (context, child) => DemoNoticeShell(child: child),
    home: const Scaffold(body: Center(child: Text('page'))),
  ),
);

void main() {
  testWidgets('no notice on a real deployment', (tester) async {
    await tester.pumpWidget(host(demo: false));
    expect(find.text('page'), findsOneWidget);
    expect(find.textContaining('made up'), findsNothing);
  });

  testWidgets('demo build shows the notice and it can be closed', (
    tester,
  ) async {
    await tester.pumpWidget(host(demo: true));
    expect(find.text('page'), findsOneWidget);
    expect(find.textContaining('made up'), findsOneWidget);
    await tester.tap(find.text('Close'));
    await tester.pump();
    expect(find.textContaining('made up'), findsNothing);
    expect(find.text('page'), findsOneWidget);
  });
}
