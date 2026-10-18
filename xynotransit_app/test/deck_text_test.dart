import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xynotransit_app/data/memory_repository.dart';
import 'package:xynotransit_app/data/repository.dart';
import 'package:xynotransit_app/data/seed_data.dart';
import 'package:xynotransit_app/domain/deck_text.dart';
import 'package:xynotransit_app/domain/enums.dart';

Matcher fails(String message) => throwsA(
  isA<RepositoryException>().having((e) => e.message, 'message', message),
);

DeckTextField field(String key) => deckTextField(key)!;

void main() {
  group('DeckTexts', () {
    test('render fills every token', () {
      const vars = {
        'org': 'Xyno',
        'title': 'T',
        'period': 'Feb to Apr 2026',
        'name': 'Rova',
        'role': 'Import',
        'team': 'Ops',
        'met': 2,
        'total': 3,
        'count': 4,
        'i': 1,
        'n': 4,
        'k': 5,
        'reports': 'reports',
      };
      final t = DeckTexts.defaults.withValue(
        'footer',
        '{org} {title} {period} {name} {role} {team} {met} {total} {count} {i} {n} {k} {reports}',
      );
      expect(
        t.render('footer', vars),
        'Xyno T Feb to Apr 2026 Rova Import Ops 2 3 4 1 4 5 reports',
      );
    });

    test('unknown or missing tokens stay as written', () {
      expect(DeckTexts.fill('a {x} {name}', {'name': 'B'}), 'a {x} B');
      expect(DeckTexts.fill('{name}', {}), '{name}');
    });

    test('default templates render with their own tokens', () {
      expect(
        DeckTexts.defaults.render('dividerSubtitle', {
          'k': 1,
          'reports': 'report',
          'team': 'Ops',
        }),
        '1 report, two slides each: KPI and results',
      );
      expect(
        DeckTexts.defaults.render('dividerSubtitle', {
          'k': 3,
          'reports': 'reports',
        }),
        '3 reports, two slides each: KPI and results',
      );
    });

    test('check: every message', () {
      expect(
        DeckTexts.check(field('title'), '  '),
        'Meeting title cannot be empty.',
      );
      expect(
        DeckTexts.check(field('title'), 'a' * 81),
        'Meeting title can be at most 80 characters.',
      );
      expect(DeckTexts.check(field('title'), 'a' * 80), isNull);
      expect(
        DeckTexts.check(field('title'), '{name}'),
        '{name} cannot be used in Meeting title. It allows {period}.',
      );
      expect(
        DeckTexts.check(field('orgName'), '{name}'),
        '{name} cannot be used in Organisation name. It allows no placeholders.',
      );
      expect(
        DeckTexts.check(field('kpiBadge'), '{met} {x}'),
        '{x} cannot be used in KPI slide, badge. It allows {met}, {total}.',
      );
      expect(DeckTexts.check(field('dateText'), ''), isNull);
      expect(DeckTexts.check(field('suggestionsBody'), ''), isNull);
    });

    test('length counts characters, not code units', () {
      final f = field('orgName');
      expect(DeckTexts.check(f, '😀' * f.maxLength), isNull);
      expect(DeckTexts.check(f, '😀' * (f.maxLength + 1)), isNotNull);
    });

    test('json round trip, missing keys take defaults, equality', () {
      final t = DeckTexts.defaults.withValue('title', 'Hello');
      expect(DeckTexts.fromJson(t.toJson()), t);
      expect(t, isNot(DeckTexts.defaults));
      expect(t.hashCode, DeckTexts.fromJson(t.toJson()).hashCode);
      final partial = DeckTexts.fromJson({'title': 'X', 'subtitle': 5});
      expect(partial['title'], 'X');
      expect(partial['subtitle'], DeckTexts.defaults['subtitle']);
      expect(DeckTexts.fromJson(null), DeckTexts.defaults);
      expect(DeckTexts.empty, DeckTexts.defaults);
      expect(DeckTexts.defaults.toJson().keys, [
        for (final f in deckTextFields) f.key,
      ]);
    });

    test('every default passes its own check', () {
      for (final f in deckTextFields) {
        expect(DeckTexts.check(f, f.defaultValue), isNull, reason: f.key);
      }
    });

    test('defaults agree with docs/reference/deck_text_defaults.json', () {
      final j = jsonDecode(
        File('docs/reference/deck_text_defaults.json').readAsStringSync(),
      ) as Map<String, dynamic>;
      final fields = (j['fields'] as List).cast<Map<String, dynamic>>();
      expect(fields.map((f) => f['key']), deckTextFields.map((f) => f.key));
      for (var i = 0; i < fields.length; i++) {
        final f = deckTextFields[i];
        expect(fields[i]['default'], f.defaultValue, reason: f.key);
        expect(fields[i]['tokens'], f.tokens, reason: f.key);
        expect(fields[i]['max_length'], f.maxLength, reason: f.key);
        expect(fields[i]['can_be_empty'], f.canBeEmpty, reason: f.key);
        expect(DeckTexts.defaults[f.key], f.defaultValue);
      }
    });
  });

  group('MemoryRepository deck texts', () {
    late MemoryRepository repo;
    var user = DemoAuth.controller;
    final catalog = buildSeedCatalog();

    setUp(() {
      user = DemoAuth.controller;
      repo = MemoryRepository(currentUser: () => user, withDemoReports: true);
    });

    test('a new period starts on the defaults', () async {
      final p = await repo.ensurePeriod(MemoryRepository.demoStart);
      final s = await repo.loadDeckTexts(p.id);
      expect(s.texts, DeckTexts.defaults);
      expect(s.inheritedFrom, 'defaults');
    });

    test('save, then load shows own words (trimmed)', () async {
      final p = await repo.ensurePeriod(MemoryRepository.demoStart);
      final saved = await repo.saveDeckTexts(
        p.id,
        DeckTexts.defaults.withValue('title', '  Board review  '),
      );
      expect(saved.inheritedFrom, isNull);
      expect(saved.texts['title'], 'Board review');
      final s = await repo.loadDeckTexts(p.id);
      expect(s.inheritedFrom, isNull);
      expect(s.texts['title'], 'Board review');
    });

    test('a later period inherits the latest earlier one', () async {
      final p1 = await repo.ensurePeriod(DateTime(2026, 2));
      final p2 = await repo.ensurePeriod(DateTime(2026, 5));
      final p3 = await repo.ensurePeriod(DateTime(2026, 8));
      final p0 = await repo.ensurePeriod(DateTime(2025, 11));
      await repo.saveDeckTexts(
        p1.id,
        DeckTexts.defaults.withValue('title', 'One'),
      );
      var s = await repo.loadDeckTexts(p3.id);
      expect(s.texts['title'], 'One');
      expect(s.inheritedFrom, 'Feb to Apr 2026');
      await repo.saveDeckTexts(
        p2.id,
        DeckTexts.defaults.withValue('title', 'Two'),
      );
      s = await repo.loadDeckTexts(p3.id);
      expect(s.texts['title'], 'Two');
      expect(s.inheritedFrom, 'May to Jul 2026');
      s = await repo.loadDeckTexts(p0.id);
      expect(s.inheritedFrom, 'defaults');
      expect(s.texts, DeckTexts.defaults);
    });

    test('invalid words are refused with the check message', () async {
      final p = await repo.ensurePeriod(MemoryRepository.demoStart);
      await expectLater(
        repo.saveDeckTexts(p.id, DeckTexts.defaults.withValue('title', ' ')),
        fails('Meeting title cannot be empty.'),
      );
      await expectLater(
        repo.saveDeckTexts(
          p.id,
          DeckTexts.defaults.withValue('orgName', '{team}'),
        ),
        fails(
          '{team} cannot be used in Organisation name. It allows no placeholders.',
        ),
      );
      expect((await repo.loadDeckTexts(p.id)).inheritedFrom, 'defaults');
    });

    test('controller only, and the period must exist', () async {
      final p = await repo.ensurePeriod(MemoryRepository.demoStart);
      user = const AppUser(
        personId: 'p-rova',
        role: AppRole.contributor,
        label: 'Rova',
      );
      const only = 'Only the controller can do this.';
      await expectLater(repo.loadDeckTexts(p.id), fails(only));
      await expectLater(
        repo.saveDeckTexts(p.id, DeckTexts.defaults),
        fails(only),
      );
      user = DemoAuth.controller;
      await expectLater(
        repo.loadDeckTexts('nope'),
        fails('That period does not exist.'),
      );
    });

    test(
      'a deck freezes the effective words; an old deck keeps its own',
      () async {
        final p = await repo.ensurePeriod(MemoryRepository.demoStart);
        final first = await repo.generateDeck(p, catalog);
        expect(first.texts, DeckTexts.defaults);

        await repo.saveDeckTexts(
          p.id,
          DeckTexts.defaults.withValue('title', 'New words'),
        );
        // Editing does not touch the existing deck.
        expect((await repo.watchDeck(p.id).first)!.texts, DeckTexts.defaults);

        final second = await repo.generateDeck(p, catalog);
        expect(second.texts['title'], 'New words');
        expect(first.texts['title'], DeckTexts.defaults['title']);

        await repo.saveDeckTexts(
          p.id,
          DeckTexts.defaults.withValue('title', 'Newer'),
        );
        expect((await repo.watchDeck(p.id).first)!.texts['title'], 'New words');
      },
    );

    test('a deck uses inherited words too', () async {
      final p1 = await repo.ensurePeriod(DateTime(2026, 2));
      final p2 = await repo.ensurePeriod(MemoryRepository.demoStart);
      await repo.saveDeckTexts(
        p1.id,
        DeckTexts.defaults.withValue('title', 'Carried'),
      );
      final run = await repo.generateDeck(p2, catalog);
      expect(run.texts['title'], 'Carried');
    });
  });
}
