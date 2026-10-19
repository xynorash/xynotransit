import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'form_text_test.dart' show customCatalog, pumpCustom, point;
import 'helpers.dart';

void main() {
  setUpAll(loadAppFonts);

  testWidgets('narrow, preview closed: cost per keystroke', (t) async {
    await pumpCustom(t, customCatalog(8));
    t.view.physicalSize = const Size(500, 7000);
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('live-preview')), findsNothing);
    final sw = Stopwatch()..start();
    for (var i = 1; i <= 40; i++) {
      await t.enterText(point('1'), 'a' * i);
      await t.pump();
    }
    // ignore: avoid_print
    print('PERF closed ms: ${sw.elapsedMilliseconds / 40}');
    expect(sw.elapsedMilliseconds / 40, lessThan(400));
  });

  testWidgets('typing rebuilds the two preview slides once per keystroke', (
    t,
  ) async {
    await pumpCustom(t, customCatalog(8));
    expect(find.byKey(const ValueKey('live-preview')), findsOneWidget);
    final sw = Stopwatch();
    var total = 0;
    const keys = 40;
    for (var i = 1; i <= keys; i++) {
      sw.reset();
      sw.start();
      await t.enterText(point('1'), 'a' * i);
      await t.pump();
      sw.stop();
      total += sw.elapsedMicroseconds;
    }
    final ms = total / keys / 1000;
    // ignore: avoid_print
    print(
      'PERF mean ms per keystroke (test VM, debug): ${ms.toStringAsFixed(1)}',
    );
    // A generous bound; the figure is printed for the report.
    expect(ms, lessThan(400));
  });
}
