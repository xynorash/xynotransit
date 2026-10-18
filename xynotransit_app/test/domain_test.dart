import 'package:flutter_test/flutter_test.dart';
import 'package:xynotransit_app/data/memory_repository.dart';
import 'package:xynotransit_app/data/repository.dart';
import 'package:xynotransit_app/data/seed_data.dart';
import 'package:xynotransit_app/domain/deck.dart';
import 'package:xynotransit_app/domain/enums.dart';
import 'package:xynotransit_app/domain/period.dart';
import 'package:xynotransit_app/domain/report.dart';
import 'package:xynotransit_app/domain/snapshot.dart';

void main() {
  final catalog = buildSeedCatalog();

  group('catalog', () {
    test('matches the agreed counts', () {
      expect(catalog.teams.length, 4);
      expect(catalog.assignments.length, 14);
      expect(catalog.peopleCount, 13);
      expect(catalog.assignments.fold(0, (n, a) => n + a.metrics.length), 33);
      expect(catalog.assignments.fold(0, (n, a) => n + a.kpis.length), 57);
    });

    test('Tahina is one person with two assignments', () {
      final tahina = catalog.persons.singleWhere((p) => p.fullName == 'Tahina');
      expect(catalog.assignmentsOfPerson(tahina.id).map((a) => a.code), [
        'tahina-exp',
        'tahina-bsc',
      ]);
    });

    test('deck order is team order then running order', () {
      expect(catalog.assignments.first.code, 'shalini');
      expect(catalog.assignments.last.code, 'andry');
    });
  });

  group('Period', () {
    test('label inside one year', () {
      expect(
        Period(id: 'p', startMonth: DateTime(2026, 2)).label,
        'Feb to Apr 2026',
      );
    });
    test('label across a year end', () {
      expect(
        Period(id: 'p', startMonth: DateTime(2026, 11)).label,
        'Nov 2026 to Jan 2027',
      );
      expect(
        Period(id: 'p', startMonth: DateTime(2026, 12)).label,
        'Dec 2026 to Feb 2027',
      );
    });
    test('default start is three months back', () {
      expect(Period.defaultStart(DateTime(2026, 10, 18)), DateTime(2026, 7));
      expect(Period.defaultStart(DateTime(2026, 2, 3)), DateTime(2025, 11));
    });
    test('months wrap the year', () {
      final m = Period(id: 'p', startMonth: DateTime(2026, 12)).months;
      expect(
        [for (final x in m) '${x.year}-${x.month}'],
        ['2026-12', '2027-1', '2027-2'],
      );
    });
  });

  group('Report.validate', () {
    final rova = catalog.assignmentByCode('rova')!;
    final period = Period(id: 'p', startMonth: DateTime(2026, 2));

    test(
      'names the first missing month of each metric, then the open targets',
      () {
        final r = Report(
          periodId: 'p',
          assignmentId: rova.id,
          values: {
            rova.metrics[0].id: [1, null, 3],
            rova.metrics[1].id: [null, null, null],
          },
          kpis: {rova.kpis[0].id: const KpiResult(KpiStatus.met)},
        );
        expect(r.validate(rova, period), [
          'Enter a number for "Air imports (IM5)" in March.',
          'Enter a number for "Sea imports (IM5)" in February.',
          'Answer all targets in step 3 (2 left).',
        ]);
      },
    );

    test('roles without counts only need targets', () {
      final shalini = catalog.assignmentByCode('shalini')!;
      final r = Report(periodId: 'p', assignmentId: shalini.id);
      expect(r.validate(shalini, period), [
        'Answer all targets in step 3 (4 left).',
      ]);
    });
  });

  group('NoteRules', () {
    test('trims, caps at 3, ignores duplicates and long text', () {
      var l = <String>[];
      l = NoteRules.add(l, '  a  ');
      l = NoteRules.add(l, 'a');
      expect(l, ['a']);
      l = NoteRules.add(l, 'b');
      l = NoteRules.add(l, 'c');
      l = NoteRules.add(l, 'd');
      expect(l, ['a', 'b', 'c']);
      expect(NoteRules.add(<String>[], 'x' * 71), isEmpty);
      expect(NoteRules.add(<String>[], 'x' * 70), hasLength(1));
      expect(NoteRules.add(<String>[], '   '), isEmpty);
    });
  });

  group('snapshot', () {
    test('JSON round trip keeps everything', () {
      final period = Period(id: 'p', startMonth: DateTime(2026, 2));
      final rova = catalog.assignmentByCode('rova')!;
      final report = Report(
        periodId: 'p',
        assignmentId: rova.id,
        values: {
          rova.metrics[0].id: [30, 28, 34],
          rova.metrics[1].id: [2, 3, 4],
        },
        kpis: {
          rova.kpis[0].id: const KpiResult(KpiStatus.met),
          rova.kpis[1].id: const KpiResult(KpiStatus.partly),
        },
        notes: {
          NoteKind.well: ['one'],
          NoteKind.wrong: [],
          NoteKind.next: ['two', 'three'],
        },
      );
      final s = ReportSnapshot.build(
        report: report,
        assignment: rova,
        catalog: catalog,
        period: period,
      );
      final back = ReportSnapshot.fromJson(s.toJson());
      expect(back.toJson(), s.toJson());
      expect(back.metrics.first.values, [30, 28, 34]);
      expect(back.targets[2].status, isNull);
      expect(s.toJson()['assignmentCode'], 'rova');
      expect(s.toJson()['periodLabel'], 'Feb to Apr 2026');
    });
  });

  group('MemoryRepository', () {
    late MemoryRepository repo;
    late Period period;
    var user = DemoAuth.controller;

    setUp(() async {
      user = DemoAuth.controller;
      repo = MemoryRepository(currentUser: () => user, withDemoReports: true);
      period = await repo.ensurePeriod(MemoryRepository.demoStart);
    });

    test('demo seed holds 14 submitted reports', () async {
      final all = await repo.watchReports(period.id).first;
      expect(all.length, 14);
      expect(all.every((r) => r.isSubmitted), isTrue);
    });

    test('sending again replaces, never duplicates', () async {
      final rova = catalog.assignmentByCode('rova')!;
      final before = (await repo.getReport(period.id, rova.id))!;
      final edited = before.copyWith(
        values: {
          for (final e in before.values.entries) e.key: [9, 9, 9],
        },
      );
      await repo.sendReport(edited);
      final all = await repo.watchReports(period.id).first;
      expect(all.where((r) => r.assignmentId == rova.id), hasLength(1));
      expect(all.length, 14);
      expect(
        all
            .firstWhere((r) => r.assignmentId == rova.id)
            .valueOf(rova.metrics[0].id, 0),
        9,
      );
    });

    test('refuses an incomplete report with a readable message', () async {
      final rado = catalog.assignmentByCode('rado')!;
      final r = Report(periodId: period.id, assignmentId: rado.id);
      expect(
        repo.sendReport(r),
        throwsA(
          isA<RepositoryException>().having(
            (e) => e.message,
            'message',
            contains('Enter a number'),
          ),
        ),
      );
    });

    test('a contributor can only send their own report', () async {
      user = const AppUser(
        personId: 'p-rova',
        role: AppRole.contributor,
        label: 'Rova',
      );
      final rado = (await repo.getReport(period.id, 'rado'))!;
      expect(repo.sendReport(rado), throwsA(isA<RepositoryException>()));
    });

    test(
      'only the controller generates slides, and the deck freezes the snapshot',
      () async {
        user = const AppUser(
          personId: 'p-rova',
          role: AppRole.contributor,
          label: 'Rova',
        );
        expect(
          repo.generateDeck(period, catalog),
          throwsA(isA<RepositoryException>()),
        );

        user = DemoAuth.controller;
        final run = await repo.generateDeck(period, catalog);
        expect(run.includedCount, 14);
        expect(run.expectedCount, 14);

        // Change a live report afterwards; the frozen deck must not move.
        final rova = (await repo.getReport(period.id, 'rova'))!;
        await repo.sendReport(
          rova.copyWith(
            values: {
              for (final e in rova.values.entries) e.key: [0, 0, 0],
            },
          ),
        );
        final deck = await repo.watchDeck(period.id).first;
        final frozen = deck!.items
            .firstWhere((i) => i.snapshot.assignmentCode == 'rova')
            .snapshot;
        expect(frozen.metrics.first.total, isNot(0));
      },
    );

    test('a full deck has 1 + 4 + 28 + 1 = 34 slides', () async {
      final run = await repo.generateDeck(period, catalog);
      final slides = buildDeck(run, period);
      expect(slides.length, 34);
      expect(slides.last, isA<SuggestionsSpec>());
      expect(slides.first, isA<CoverSpec>());
      expect(slides.whereType<DividerSpec>().length, 4);
    });
  });
}
