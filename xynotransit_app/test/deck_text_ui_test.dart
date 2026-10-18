import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xynotransit_app/app/providers.dart';
import 'package:xynotransit_app/domain/deck_text.dart';
import 'package:xynotransit_app/domain/period.dart';
import 'package:xynotransit_app/features/deck_text/draft_preview.dart';
import 'package:xynotransit_app/features/preview/preview_pane.dart';
import 'package:xynotransit_app/features/slides/slide_view.dart';

import 'app_test.dart' show Harness, pumpApp;
import 'helpers.dart';
import 'roles_test.dart' show rova, where, go;

Finder fieldOf(String key) => find.byKey(ValueKey('field-$key'));

Future<void> type(WidgetTester tester, String key, String text) async {
  final f = fieldOf(key);
  await tester.ensureVisible(f);
  await tester.enterText(f, text);
  await tester.pump();
}

Future<void> tapButton(WidgetTester tester, Finder f) async {
  await tester.ensureVisible(f);
  await tester.pumpAndSettle();
  await tester.tap(f);
  await tester.pumpAndSettle();
}

String textOf(WidgetTester tester, String key) =>
    tester.widget<TextField>(fieldOf(key)).controller!.text;

Finder inDraft(Finder f) =>
    find.descendant(of: find.byType(DraftPreview), matching: f);

Future<Harness> open(
  WidgetTester tester, {
  Size size = const Size(1500, 5200),
  bool demo = true,
}) => pumpApp(tester, demo: demo, size: size, location: '/manager/deck');

Finder saveButton() => find.widgetWithText(FilledButton, 'Save');

bool saveEnabled(WidgetTester tester) =>
    tester.widget<FilledButton>(saveButton()).onPressed != null;

void main() {
  setUpAll(loadAppFonts);

  testWidgets('shows every field grouped in cards', (tester) async {
    await open(tester);
    expect(find.text('Slide text'), findsWidgets);
    for (final g in DeckTextGroup.values) {
      expect(find.text(g.title), findsWidgets, reason: g.title);
    }
    for (final f in deckTextFields) {
      expect(fieldOf(f.key), findsOneWidget, reason: f.key);
      expect(find.text(f.label), findsOneWidget, reason: f.key);
      expect(find.byKey(ValueKey('counter-${f.key}')), findsOneWidget);
      expect(textOf(tester, f.key), f.defaultValue);
    }
    expect(find.text('Empty shows the meeting date'), findsOneWidget);
    expect(
      find.text('Built-in words. Nobody has changed them yet.'),
      findsOneWidget,
    );
    expect(saveEnabled(tester), isFalse);
  });

  testWidgets('nav has Deck text between Reports and People', (tester) async {
    final h = await open(tester);
    final x = [
      for (final l in ['Reports', 'Deck text', 'People'])
        tester.getTopLeft(find.text(l).first).dx,
    ];
    expect(x[0], lessThan(x[1]));
    expect(x[1], lessThan(x[2]));
    await tester.tap(find.text('People'));
    await tester.pumpAndSettle();
    expect(where(h), '/manager/people');
  });

  testWidgets('a chip inserts the placeholder at the cursor', (tester) async {
    await open(tester);
    await type(tester, 'title', 'Review ');
    await tapButton(tester, find.byKey(const ValueKey('chip-title-period')));
    expect(textOf(tester, 'title'), 'Review {period}');
    await type(tester, 'subtitle', 'AB');
    final c = tester.widget<TextField>(fieldOf('subtitle')).controller!;
    c.selection = const TextSelection.collapsed(offset: 1);
    await tapButton(tester, find.byKey(const ValueKey('chip-subtitle-period')));
    expect(textOf(tester, 'subtitle'), 'A{period}B');
  });

  testWidgets('plain-words validation and a live counter', (tester) async {
    await open(tester);
    await type(tester, 'title', '');
    expect(find.text('Meeting title cannot be empty.'), findsOneWidget);
    expect(saveEnabled(tester), isFalse);

    await type(tester, 'title', 'x' * 81);
    expect(
      find.text('Meeting title can be at most 80 characters.'),
      findsOneWidget,
    );
    expect(find.text('81 / 80'), findsOneWidget);

    await type(tester, 'title', 'Hello {name}');
    expect(
      find.text('{name} cannot be used in Meeting title. It allows {period}.'),
      findsOneWidget,
    );
    expect(saveEnabled(tester), isFalse);

    await type(tester, 'dividerTitle', 'A {k}');
    expect(
      find.text('{k} cannot be used in Divider, title. It allows {team}.'),
      findsOneWidget,
    );
    await type(tester, 'highlightsTitle', 'Good {team}');
    expect(
      find.textContaining(
        'cannot be used in First column title. It allows no placeholders.',
      ),
      findsOneWidget,
    );

    await type(tester, 'title', 'Fine');
    await type(tester, 'dividerTitle', '{team}');
    await type(tester, 'highlightsTitle', 'Good');
    expect(find.textContaining('cannot be'), findsNothing);
    expect(saveEnabled(tester), isTrue);
  });

  testWidgets('reset one and reset all', (tester) async {
    await open(tester);
    await type(tester, 'title', 'Mine');
    await type(tester, 'suggestionsTitle', 'Ideas');
    await tapButton(tester, find.byKey(const ValueKey('reset-title')));
    expect(textOf(tester, 'title'), DeckTexts.defaults['title']);
    expect(textOf(tester, 'suggestionsTitle'), 'Ideas');
    await tapButton(tester, find.text('Reset all to defaults'));
    expect(textOf(tester, 'suggestionsTitle'), 'Suggestions');
    expect(saveEnabled(tester), isFalse);
  });

  testWidgets('save, then reopen shows the saved words', (tester) async {
    final h = await open(tester);
    await type(tester, 'title', 'Quarter review {period}');
    await type(tester, 'suggestionsBody', 'Line one\nLine two');
    expect(saveEnabled(tester), isTrue);
    await tapButton(tester, saveButton());
    expect(
      find.text('Saved. Regenerate the slides to use these words.'),
      findsOneWidget,
    );
    expect(saveEnabled(tester), isFalse);
    expect(find.text('These words are saved for this period.'), findsOneWidget);

    await go(tester, h, '/manager');
    await go(tester, h, '/manager/deck');
    expect(textOf(tester, 'title'), 'Quarter review {period}');
    expect(textOf(tester, 'suggestionsBody'), 'Line one\nLine two');
  });

  testWidgets('a new period says where its words came from', (tester) async {
    final h = await open(tester);
    await type(tester, 'title', 'Carried title');
    await tapButton(tester, saveButton());
    h.container
        .read(periodSelectionProvider.notifier)
        .select(Period.start(2026, 5));
    await tester.pumpAndSettle();
    expect(
      find.text('These words were carried over from Feb to Apr 2026.'),
      findsOneWidget,
    );
    expect(textOf(tester, 'title'), 'Carried title');
  });

  testWidgets('draft preview follows the typing, sample data without a deck', (
    tester,
  ) async {
    await open(tester, demo: false);
    expect(find.text('Draft preview'), findsOneWidget);
    expect(find.byKey(const ValueKey('sample-data')), findsOneWidget);
    expect(
      find.text(
        'This is how the next deck will look. The deck you generated before keeps its old words.',
      ),
      findsOneWidget,
    );
    expect(inDraft(find.byType(SlideStage)), findsNWidgets(5));
    await type(tester, 'title', 'Typed Meeting Title');
    expect(inDraft(find.text('Typed Meeting Title')), findsWidgets);
    await type(tester, 'suggestionsTitle', 'Ideas Page');
    expect(inDraft(find.text('Ideas Page')), findsWidgets);
    // A field with a problem keeps its saved words in the preview.
    await type(tester, 'title', '');
    expect(inDraft(find.text(DeckTexts.defaults['title'])), findsWidgets);
  });

  testWidgets('draft preview uses a real person of the latest deck', (
    tester,
  ) async {
    final h = await open(tester);
    final period = await h.container.read(periodProvider.future);
    final catalog = await h.container.read(catalogProvider.future);
    await h.repo.generateDeck(period, catalog);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('sample-data')), findsNothing);
    await type(tester, 'kpiTitle', 'KPI of {name}');
    expect(inDraft(find.textContaining('KPI of ')), findsWidgets);
  });

  testWidgets(
    'stale notice after save, gone after Regenerate; stream follows',
    (tester) async {
      final h = await pumpApp(tester, demo: true, location: '/manager/reports');
      await tester.tap(find.text('Generate slides'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('stale-notice')), findsNothing);
      expect(find.byKey(const ValueKey('deck-title')), findsOneWidget);
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('deck-title'))).data,
        'Xynotransit Regional Logistics Meeting',
      );

      await go(tester, h, '/manager/deck');
      await type(tester, 'title', 'Brand New Title');
      await tapButton(tester, saveButton());

      await go(tester, h, '/manager/reports');
      expect(find.text(staleTextNotice), findsOneWidget);
      expect(
        find.text(
          'Slide text changed after this deck was generated. Regenerate to apply it.',
        ),
        findsOneWidget,
      );
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('deck-title'))).data,
        'Xynotransit Regional Logistics Meeting',
      );
      await tester.tap(find.text('Regenerate slides'));
      await tester.pumpAndSettle();
      expect(find.text(staleTextNotice), findsNothing);
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('deck-title'))).data,
        'Brand New Title',
      );
      expect(find.text('Brand New Title'), findsWidgets);
    },
  );

  testWidgets('a contributor is sent away from /manager/deck', (tester) async {
    final h = await pumpApp(tester, demo: true, user: rova, location: '/');
    await go(tester, h, '/manager/deck');
    expect(where(h), '/report');
    expect(find.text('Slide text'), findsNothing);
  });

  for (final s in {
    '360x800': const Size(360, 800),
    '800x1100': const Size(800, 1100),
    '1500x900': const Size(1500, 900),
  }.entries) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('no overflow at ${s.key}, text scale $scale', (tester) async {
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        await open(tester, size: s.value);
        expect(tester.takeException(), isNull);
        await type(tester, 'title', 'x' * 90);
        await type(tester, 'dividerTitle', '{reports}');
        expect(tester.takeException(), isNull);
        await tester.drag(
          find.byType(SingleChildScrollView).first,
          const Offset(0, -3000),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      });
    }
  }
}
