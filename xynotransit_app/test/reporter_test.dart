import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:xynotransit_app/data/api/api_models.dart';
import 'package:xynotransit_app/data/api/api_repository.dart';
import 'package:xynotransit_app/data/memory_repository.dart';
import 'package:xynotransit_app/data/repository.dart';
import 'package:xynotransit_app/data/seed_data.dart';
import 'package:xynotransit_app/domain/deck.dart';
import 'package:xynotransit_app/domain/enums.dart';
import 'package:xynotransit_app/domain/period.dart';
import 'package:xynotransit_app/domain/report.dart';
import 'package:xynotransit_app/domain/snapshot.dart';

import 'api/api_client_test.dart' show clientFor, json;
import 'api/api_models_test.dart' show reportJson;

void main() {
  final catalog = buildSeedCatalog();
  final rova = catalog.assignmentByCode('rova')!;
  final period = Period(id: 'p', startMonth: DateTime(2026, 2));
  const who = Reporter(name: 'Rova R.', country: 'Madagascar', role: 'Lead');

  group('Reporter', () {
    test('required, with plain messages in field order', () {
      expect(const Reporter().problems(), [
        'Enter your name.',
        'Enter your country.',
        'Enter your role.',
      ]);
      expect(const Reporter(name: '  ', country: 'x', role: 'y').problems(), [
        'Enter your name.',
      ]);
      expect(who.problems(), isEmpty);
    });

    test('80 characters at most, trimmed first', () {
      expect(
        Reporter(name: ' ${'a' * 80} ', country: 'c', role: 'r').problems(),
        isEmpty,
      );
      expect(Reporter(name: 'a', country: 'c' * 81, role: 'r').problems(), [
        'Your country can be at most 80 characters.',
      ]);
    });

    test('plain text only', () {
      for (final bad in ['a\nb', 'a​b', 'a\tb', 'a b', 'a‮b']) {
        expect(Reporter(name: bad, country: 'c', role: 'r').problems(), [
          'Your name can only use plain text.',
        ], reason: bad.codeUnits.toString());
      }
      expect(
        const Reporter(name: 'Zoë Ñ 中', country: 'c', role: 'r').problems(),
        isEmpty,
      );
    });

    test('draft JSON round trip', () {
      final r = Report(periodId: 'p', assignmentId: 'a', reporter: who);
      final back = Report.fromDraftJson(
        'p',
        'a',
        jsonDecode(jsonEncode(r.toDraftJson())) as Map<String, Object?>,
      );
      expect(back.reporter, who);
      final none = Report.fromDraftJson(
        'p',
        'a',
        jsonDecode(
          jsonEncode(Report(periodId: 'p', assignmentId: 'a').toDraftJson()),
        ) as Map<String, Object?>,
      );
      expect(none.reporter, isNull);
    });
  });

  group('snapshots', () {
    Report full(Reporter? r) => Report(
      periodId: 'p',
      assignmentId: rova.id,
      reporter: r,
      values: {
        for (final m in rova.metrics) m.id: [1, 2, 3],
      },
      kpis: {for (final k in rova.kpis) k.id: const KpiResult(KpiStatus.met)},
    );

    test('use the reporter words over the profile', () {
      final s = ReportSnapshot.build(
        report: full(who),
        assignment: rova,
        catalog: catalog,
        period: period,
      );
      expect((s.name, s.team, s.role), ('Rova R.', 'Madagascar', 'Lead'));
    });

    test('fall back to the profile without a reporter', () {
      final s = ReportSnapshot.build(
        report: full(null),
        assignment: rova,
        catalog: catalog,
        period: period,
      );
      expect(s.name, catalog.personOf(rova).fullName);
      expect(s.team, catalog.teamOf(rova).name);
      expect(s.role, rova.roleTitle);
    });

    test('the draft helper never throws on an empty form', () {
      final s = buildDraftSnapshot(
        Report(periodId: 'p', assignmentId: rova.id),
        rova,
        catalog,
        period,
      );
      expect(s.metrics.every((m) => m.values.every((v) => v == 0)), isTrue);
      expect(s.targets.every((t) => t.status == null), isTrue);
      expect(s.name, catalog.personOf(rova).fullName);
      final part = buildDraftSnapshot(
        Report(
          periodId: 'p',
          assignmentId: rova.id,
          reporter: const Reporter(name: 'Only name'),
          values: {
            rova.metrics.first.id: [5, null],
          },
        ),
        rova,
        catalog,
        period,
      );
      expect(part.name, 'Only name');
      expect(part.team, catalog.teamOf(rova).name);
      expect(part.metrics.first.values, [5, 0, 0]);
    });
  });

  group('MemoryRepository', () {
    late MemoryRepository repo;
    late Period per;
    var user = DemoAuth.controller;
    const rovaUser = AppUser(
      personId: 'p-rova',
      role: AppRole.contributor,
      label: 'Rova',
    );

    setUp(() async {
      user = DemoAuth.controller;
      repo = MemoryRepository(currentUser: () => user);
      per = await repo.ensurePeriod(MemoryRepository.demoStart);
    });

    Report filled({Reporter? reporter}) => Report(
      periodId: per.id,
      assignmentId: rova.id,
      reporter: reporter,
      values: {
        for (final m in rova.metrics) m.id: [1, 2, 3],
      },
      kpis: {for (final k in rova.kpis) k.id: const KpiResult(KpiStatus.met)},
    );

    Future<void> refused(Report r, String message) => expectLater(
      repo.sendReport(r),
      throwsA(
        isA<RepositoryException>().having((e) => e.message, 'm', message),
      ),
    );

    test('send needs the reporter, same messages, 80 characters', () async {
      await refused(filled(), 'Enter your name.');
      await refused(
        filled(
          reporter: const Reporter(name: 'a', country: ' ', role: 'r'),
        ),
        'Enter your country.',
      );
      await refused(
        filled(
          reporter: Reporter(name: 'a', country: 'c', role: 'r' * 81),
        ),
        'Your role can be at most 80 characters.',
      );
    });

    test('stores it trimmed, keeps it on re-send and edit', () async {
      final saved = await repo.sendReport(
        filled(
          reporter: const Reporter(
            name: ' Rova R. ',
            country: 'Madagascar ',
            role: 'Lead',
          ),
        ),
      );
      expect(saved.reporter, who);
      final again = await repo.sendReport(
        saved.copyWith(
          values: {
            for (final m in rova.metrics) m.id: [4, 5, 6],
          },
        ),
      );
      expect(again.reporter, who);
      expect((await repo.getReport(per.id, rova.id))!.reporter, who);
      final edited = await repo.sendReport(
        again.copyWith(reporter: who.copyWith(role: 'Chief')),
      );
      expect(edited.reporter!.role, 'Chief');
    });

    test('deck snapshots use the reporter words', () async {
      await repo.sendReport(filled(reporter: who));
      final run = await repo.generateDeck(per, catalog);
      final s = run.items.single.snapshot;
      expect((s.name, s.team, s.role), ('Rova R.', 'Madagascar', 'Lead'));
    });

    test('a deck with no submitted report is cover + suggestions', () async {
      final run = await repo.generateDeck(per, catalog);
      expect(run.includedCount, 0);
      expect(run.expectedCount, catalog.assignments.length);
      final slides = buildDeck(run, per);
      expect(slides.length, 2);
      expect(slides.first, isA<CoverSpec>());
      expect(slides.last, isA<SuggestionsSpec>());
      expect((slides.first as CoverSpec).periodLabel, per.label);
    });

    test(
      'any signed-in person reads the deck words, only the manager saves',
      () async {
        user = rovaUser;
        final s = await repo.loadDeckTexts(per.id);
        await expectLater(
          repo.saveDeckTexts(per.id, s.texts),
          throwsA(isA<RepositoryException>()),
        );
      },
    );
  });

  group('buildDeck grouping', () {
    ReportSnapshot snap(String code, String country) {
      final a = catalog.assignmentByCode(code)!;
      return ReportSnapshot.build(
        report: Report(
          periodId: 'p',
          assignmentId: a.id,
          reporter: Reporter(name: code, country: country, role: 'r'),
        ),
        assignment: a,
        catalog: catalog,
        period: period,
      );
    }

    test('one country in any spelling is one group, first spelling shown', () {
      final run = DeckRun(
        id: 'd',
        periodId: 'p',
        generatedAt: DateTime(2026),
        expectedCount: 4,
        includedCount: 4,
        items: [
          for (final (i, e) in [
            ('rova', 'Madagascar'),
            ('rado', 'France'),
            ('hanitra', ' madagascar '),
            ('tanjona', 'MADAGASCAR'),
          ].indexed)
            DeckItem(reportId: 'r$i', sort: i, snapshot: snap(e.$1, e.$2)),
        ],
      );
      final slides = buildDeck(run, period);
      final dividers = slides.whereType<DividerSpec>().toList();
      expect(dividers.map((d) => d.team), ['Madagascar', 'France']);
      expect(dividers.map((d) => d.people.length), [3, 1]);
      expect(dividers.map((d) => (d.index, d.total)), [(1, 2), (2, 2)]);
      expect(dividers.every((d) => d.periodLabel == period.label), isTrue);
      expect((slides.first as CoverSpec).teamCounts, [
        ('Madagascar', 3),
        ('France', 1),
      ]);
      expect(slides.length, 1 + 2 + 8 + 1);
    });
  });

  group('API', () {
    test('sendReport sends the reporter and parse reads it back', () async {
      late http.Request seen;
      final repo = ApiRepository(
        await clientFor((r) async {
          seen = r;
          return json({
            ...reportJson(),
            'reporter': {'name': 'A', 'country': 'B', 'role': 'C'},
          });
        }),
        useDefaultSse: false,
      );
      final saved = await repo.sendReport(
        Report(
          periodId: 'per1',
          assignmentId: 'a1',
          reporter: const Reporter(name: ' A ', country: 'B', role: 'C'),
        ),
      );
      expect((jsonDecode(seen.body) as Map)['reporter'], {
        'name': 'A',
        'country': 'B',
        'role': 'C',
      });
      expect(
        saved.reporter,
        const Reporter(name: 'A', country: 'B', role: 'C'),
      );
    });

    test('legacy rows without a reporter stay null', () {
      expect(parseReport(reportJson()).reporter, isNull);
      expect(parseReport({...reportJson(), 'reporter': null}).reporter, isNull);
    });
  });
}
