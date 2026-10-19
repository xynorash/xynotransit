import 'package:flutter_test/flutter_test.dart';
import 'package:xynotransit_app/data/memory_repository.dart';
import 'package:xynotransit_app/data/repository.dart';
import 'package:xynotransit_app/data/seed_data.dart';
import 'package:xynotransit_app/domain/admin.dart';
import 'package:xynotransit_app/domain/catalog.dart';
import 'package:xynotransit_app/domain/enums.dart';
import 'package:xynotransit_app/domain/period.dart';
import 'package:xynotransit_app/domain/report.dart';

Matcher fails(String message) => throwsA(
  isA<RepositoryException>().having((e) => e.message, 'message', message),
);

void main() {
  late MemoryRepository repo;
  var user = DemoAuth.controller;

  setUp(() {
    user = DemoAuth.controller;
    repo = MemoryRepository(currentUser: () => user, withDemoReports: true);
  });

  const contributor = AppUser(
    personId: 'p-rova',
    role: AppRole.contributor,
    label: 'Rova',
  );

  group('who may do what', () {
    test('every admin call is for the controller only', () async {
      user = contributor;
      const only = 'Only the controller can do this.';
      await expectLater(repo.saveTeam(name: 'X'), fails(only));
      await expectLater(repo.deleteTeam('mru'), fails(only));
      await expectLater(
        repo.savePerson(
          fullName: 'A',
          email: 'a@b.co',
          role: AppRole.contributor,
        ),
        fails(only),
      );
      await expectLater(
        repo.saveAssignment(personId: 'p-rova', teamId: 'mru', roleTitle: 'X'),
        fails(only),
      );
      await expectLater(
        repo.saveDefinitions('rova', metrics: const [], kpis: const []),
        fails(only),
      );
      await expectLater(repo.loadSummary('x'), fails(only));
    });

    test(
      'a contributor only sees active seats, a controller can ask for all',
      () async {
        final seat = await repo.saveAssignment(
          id: 'rova',
          personId: 'p-rova',
          teamId: 'tana',
          roleTitle: 'Import',
          active: false,
        );
        expect(seat.active, isFalse);
        expect((await repo.loadCatalog()).assignmentByCode('rova'), isNull);
        expect(
          (await repo.loadCatalog(includeInactive: true))
              .assignmentByCode('rova'),
          isNotNull,
        );
        user = contributor;
        expect(
          (await repo.loadCatalog(includeInactive: true))
              .assignmentByCode('rova'),
          isNull,
        );
      },
    );
  });

  group('teams', () {
    test('create, rename, delete', () async {
      final t = await repo.saveTeam(name: '  Port Louis ');
      expect(t.name, 'Port Louis');
      expect(t.code, 'port-louis');
      expect(t.sort, 5);
      final again = await repo.saveTeam(name: 'Port louis');
      expect(again.code, 'port-louis-2');
      await repo.saveTeam(id: t.id, name: 'Harbour');
      var c = await repo.loadCatalog();
      expect(c.teams.firstWhere((x) => x.id == t.id).name, 'Harbour');
      await repo.deleteTeam(t.id);
      c = await repo.loadCatalog();
      expect(c.teams.any((x) => x.id == t.id), isFalse);
    });

    test('name rules and the delete guard', () async {
      const bad = 'Give the team a name of 1 to 60 characters.';
      await expectLater(repo.saveTeam(name: '   '), fails(bad));
      await expectLater(repo.saveTeam(name: 'x' * 61), fails(bad));
      await expectLater(
        repo.deleteTeam('tana'),
        fails('Move or remove the seats of this team first.'),
      );
    });
  });

  group('people', () {
    test('email is trimmed, lowercased and unique', () async {
      final p = await repo.savePerson(
        fullName: ' Mina ',
        email: '  Mina@Xyno.Example ',
        role: AppRole.contributor,
      );
      expect(p.fullName, 'Mina');
      expect(p.email, 'mina@xyno.example');
      await expectLater(
        repo.savePerson(
          fullName: 'Other',
          email: 'MINA@xyno.example',
          role: AppRole.contributor,
        ),
        fails('That email is already used.'),
      );
      // Saving the same person again is not a clash with itself.
      await repo.savePerson(
        id: p.id,
        fullName: 'Mina R',
        email: 'mina@xyno.example',
        role: AppRole.contributor,
      );
    });

    test('name and email shape', () async {
      await expectLater(
        repo.savePerson(
          fullName: '',
          email: 'a@b.co',
          role: AppRole.contributor,
        ),
        throwsA(isA<RepositoryException>()),
      );
      await expectLater(
        repo.savePerson(
          fullName: 'A',
          email: 'nope',
          role: AppRole.contributor,
        ),
        fails('Enter a valid email address.'),
      );
    });

    test('the last manager cannot be demoted or deactivated', () async {
      final boss = await repo.savePerson(
        fullName: 'Boss',
        email: 'boss@x.example',
        role: AppRole.controller,
      );
      await expectLater(
        repo.savePerson(
          id: boss.id,
          fullName: 'Boss',
          email: 'boss@x.example',
          role: AppRole.contributor,
        ),
        fails('There must be at least one manager.'),
      );
      await expectLater(
        repo.savePerson(
          id: boss.id,
          fullName: 'Boss',
          email: 'boss@x.example',
          role: AppRole.controller,
          active: false,
        ),
        fails('There must be at least one manager.'),
      );
      // With a second manager the first can go.
      await repo.savePerson(
        fullName: 'Deputy',
        email: 'deputy@x.example',
        role: AppRole.controller,
      );
      final off = await repo.savePerson(
        id: boss.id,
        fullName: 'Boss',
        email: 'boss@x.example',
        role: AppRole.controller,
        active: false,
      );
      expect(off.active, isFalse);
    });

    test('a person added in demo mode appears in the Demo menu', () async {
      final catalog = buildSeedCatalog();
      final auth = DemoAuth(catalog);
      final r = MemoryRepository(
        catalog: catalog,
        currentUser: () => DemoAuth.controller,
      );
      final before = auth.choices.length;
      final p = await r.savePerson(
        fullName: 'Mina',
        email: 'mina@x.example',
        role: AppRole.contributor,
      );
      expect(auth.choices.length, before + 1);
      expect(auth.choices.last.label, 'Mina');
      expect(auth.choices.last.personId, p.id);
      await r.savePerson(
        id: p.id,
        fullName: 'Mina',
        email: 'mina@x.example',
        role: AppRole.contributor,
        active: false,
      );
      expect(auth.choices.length, before);
    });
  });

  group('seats', () {
    test('create, move, duplicate guard', () async {
      final p = await repo.savePerson(
        fullName: 'Mina',
        email: 'mina@x.example',
        role: AppRole.contributor,
      );
      final a = await repo.saveAssignment(
        personId: p.id,
        teamId: 'abe',
        roleTitle: ' Planner ',
      );
      expect(a.roleTitle, 'Planner');
      expect(a.sort, 4); // after the 3 seats already in Antsirabe
      expect(a.metrics, isEmpty);
      await expectLater(
        repo.saveAssignment(
          personId: p.id,
          teamId: 'abe',
          roleTitle: 'planner',
        ),
        fails('That person already has this role in this team.'),
      );
      final moved = await repo.saveAssignment(
        id: a.id,
        personId: p.id,
        teamId: 'tmm',
        roleTitle: 'Planner',
      );
      expect(moved.teamId, 'tmm');
      expect(moved.sort, 2);
      final c = await repo.loadCatalog();
      expect(
        c.assignmentsOfTeam(c.teams.firstWhere((t) => t.id == 'tmm')).last.id,
        a.id,
      );
      await expectLater(
        repo.saveAssignment(personId: p.id, teamId: 'nowhere', roleTitle: 'X'),
        fails('That team does not exist.'),
      );
      await expectLater(
        repo.saveAssignment(personId: p.id, teamId: 'abe', roleTitle: ''),
        throwsA(isA<RepositoryException>()),
      );
    });
  });

  group('definitions', () {
    Future<Assignment> seat(String code) async =>
        (await repo.loadCatalog()).assignmentByCode(code)!;

    test(
      'ids are kept, new ones added, missing ones retired, order is series',
      () async {
        final rova = await seat('rova');
        final air = rova.metrics[0];
        final sea = rova.metrics[1];
        final saved = await repo.saveDefinitions(
          rova.id,
          metrics: [
            const MetricInput(label: ' Courier '),
            MetricInput(id: sea.id, label: 'Sea freight'),
          ],
          kpis: [
            KpiInput(id: rova.kpis[0].id, text: rova.kpis[0].text),
            const KpiInput(text: 'A new target'),
          ],
        );
        expect(saved.metrics.map((m) => m.label), ['Courier', 'Sea freight']);
        expect(saved.metrics.map((m) => m.series), [0, 1]);
        expect(saved.metrics[1].id, sea.id);
        expect(saved.metrics[1].key, sea.key);
        expect(saved.metrics.any((m) => m.id == air.id), isFalse);
        expect(saved.kpis.map((k) => k.sort), [1, 2]);
        expect(saved.kpis[0].id, rova.kpis[0].id);
        expect(saved.kpis[1].text, 'A new target');
        // The catalog everyone reads has it too.
        expect((await seat('rova')).metrics.map((m) => m.label), [
          'Courier',
          'Sea freight',
        ]);
      },
    );

    test(
      'a changed target text becomes a new target, the old id is gone',
      () async {
        final rova = await seat('rova');
        final saved = await repo.saveDefinitions(
          rova.id,
          metrics: [
            for (final m in rova.metrics) MetricInput(id: m.id, label: m.label),
          ],
          kpis: [
            KpiInput(id: rova.kpis[0].id, text: 'Reworded'),
            KpiInput(id: rova.kpis[1].id, text: rova.kpis[1].text),
          ],
        );
        expect(saved.kpis[0].id, isNot(rova.kpis[0].id));
        expect(saved.kpis[0].text, 'Reworded');
        expect(saved.kpis[1].id, rova.kpis[1].id);
      },
    );

    test('reordering swaps the series', () async {
      final rova = await seat('rova');
      final saved = await repo.saveDefinitions(
        rova.id,
        metrics: [
          MetricInput(id: rova.metrics[1].id, label: rova.metrics[1].label),
          MetricInput(id: rova.metrics[0].id, label: rova.metrics[0].label),
        ],
        kpis: const [],
      );
      expect(saved.metrics.map((m) => m.id), [
        rova.metrics[1].id,
        rova.metrics[0].id,
      ]);
      expect(saved.kpis, isEmpty);
    });

    test('limits and messages', () async {
      final rova = await seat('rova');
      Future<Assignment> save(
        List<MetricInput> m, [
        List<KpiInput> k = const [],
      ]) => repo.saveDefinitions(rova.id, metrics: m, kpis: k);
      await expectLater(
        save([for (var i = 0; i < 9; i++) MetricInput(label: 'C$i')]),
        fails('A seat can have 8 counts at most.'),
      );
      await expectLater(
        save(const [], [for (var i = 0; i < 11; i++) KpiInput(text: 'T$i')]),
        fails('A seat can have at most 10 targets.'),
      );
      await expectLater(
        save(const [MetricInput(label: '  ')]),
        fails('Each count needs a name of 1 to 60 characters.'),
      );
      await expectLater(
        save([MetricInput(label: 'x' * 61)]),
        fails('Each count needs a name of 1 to 60 characters.'),
      );
      await expectLater(
        save(const [MetricInput(label: 'Sea'), MetricInput(label: ' sea ')]),
        fails('Two counts of this seat have the same name.'),
      );
      await expectLater(
        save(const [], [KpiInput(text: 'x' * 201)]),
        fails('Each target needs a text of 1 to 200 characters.'),
      );
      await expectLater(
        save(const [MetricInput(id: 'not-mine', label: 'A')]),
        fails('Some of the counts or targets do not belong to this seat.'),
      );
      // Nothing was changed by the refused calls.
      expect((await seat('rova')).metrics, hasLength(2));
      // 8 counts are fine.
      final ok = await save([
        for (var i = 0; i < 8; i++) MetricInput(label: 'C$i'),
      ]);
      expect(ok.metrics, hasLength(8));
    });

    test('a seat can end with no counts at all', () async {
      final rova = await seat('rova');
      final saved = await repo.saveDefinitions(
        rova.id,
        metrics: const [],
        kpis: const [],
      );
      expect(saved.hasCounts, isFalse);
    });
  });

  group('reports after the definitions change', () {
    late Period period;
    setUp(() async {
      period = await repo.ensurePeriod(MemoryRepository.demoStart);
    });

    test(
      'values of a retired count are ignored, new counts are required',
      () async {
        final rova = (await repo.loadCatalog()).assignmentByCode('rova')!;
        final old = (await repo.getReport(period.id, rova.id))!;
        final saved = await repo.saveDefinitions(
          rova.id,
          metrics: [
            MetricInput(id: rova.metrics[1].id, label: rova.metrics[1].label),
            const MetricInput(label: 'Courier'),
          ],
          kpis: [for (final k in rova.kpis) KpiInput(id: k.id, text: k.text)],
        );
        // The old report still has its numbers, including the retired count.
        final stored = (await repo.getReport(period.id, rova.id))!;
        expect(stored.values.keys, containsAll(old.values.keys));
        // Sending it again needs the new count.
        await expectLater(
          repo.sendReport(stored),
          fails(
            'Enter a number for "Courier" in Feb.'.replaceAll(
              'Feb',
              period.months[0].long,
            ),
          ),
        );
        final newId = saved.metrics[1].id;
        final fixed = stored.copyWith(
          values: {
            ...stored.values,
            newId: [1, 2, 3],
          },
        );
        final sent = await repo.sendReport(fixed);
        expect(sent.isSubmitted, isTrue);
        // The deck only holds the current counts.
        final cat = await repo.loadCatalog();
        final run = await repo.generateDeck(period, cat);
        final item = run.items.firstWhere((i) => i.reportId == sent.id);
        expect(item.snapshot.metrics.map((m) => m.label), [
          'Sea imports (IM5)',
          'Courier',
        ]);
      },
    );

    test('a retired target is not asked for any more', () async {
      final rova = (await repo.loadCatalog()).assignmentByCode('rova')!;
      final saved = await repo.saveDefinitions(
        rova.id,
        metrics: [
          for (final m in rova.metrics) MetricInput(id: m.id, label: m.label),
        ],
        kpis: [KpiInput(id: rova.kpis[0].id, text: rova.kpis[0].text)],
      );
      final r = Report(
        periodId: period.id,
        assignmentId: rova.id,
        reporter: const Reporter(
          name: 'Rova',
          country: 'Madagascar',
          role: 'Agent',
        ),
        values: {
          for (final m in saved.metrics) m.id: [1, 1, 1],
        },
        kpis: {saved.kpis[0].id: const KpiResult(KpiStatus.met)},
      );
      expect((await repo.sendReport(r)).isSubmitted, isTrue);
    });
  });

  group('catalog stream', () {
    test('replays the latest catalog and emits after every write', () async {
      final seen = <int>[];
      final sub = repo.watchCatalog().listen((c) => seen.add(c.teams.length));
      await Future<void>.delayed(Duration.zero);
      await repo.saveTeam(name: 'New team');
      await Future<void>.delayed(Duration.zero);
      expect(seen, [4, 5]);
      // A late listener gets the latest right away.
      expect((await repo.watchCatalog().first).teams.length, 5);
      await sub.cancel();
    });
  });

  group('summary', () {
    test('matches the demo reports', () async {
      final period = await repo.ensurePeriod(MemoryRepository.demoStart);
      final s = await repo.loadSummary(period.id);
      expect(s.expected, 14);
      expect(s.submitted, 14);
      expect(s.teams.map((t) => t.name), [
        'Mauritius',
        'Tana',
        'Antsirabe',
        'Tamatave',
      ]);
      expect(s.teams.fold(0, (n, t) => n + t.submitted), 14);
      expect(s.people, hasLength(14));
      expect(s.trend.single.periodId, period.id);
      // Totals agree three ways.
      final byTeams = s.teams.fold(
        0,
        (n, t) => n + t.volumeByMonth.fold(0, (a, b) => a + b),
      );
      expect(s.trend.single.volumeTotal, byTeams);
      expect(s.people.fold(0, (n, p) => n + p.volumeTotal), byTeams);
      expect(s.metrics.fold(0, (n, m) => n + m.total), byTeams);
      // 57 targets were answered, every one of them.
      expect(s.answered, 57);
      expect(s.metrics.first.total, greaterThanOrEqualTo(s.metrics.last.total));
    });

    test(
      'follows seat changes and earlier periods show in the trend',
      () async {
        final period = await repo.ensurePeriod(MemoryRepository.demoStart);
        await repo.ensurePeriod(DateTime(2025, 11));
        await repo.saveAssignment(
          id: 'shalini',
          personId: 'p-shalini',
          teamId: 'mru',
          roleTitle: 'Shipping clerk',
          active: false,
        );
        final s = await repo.loadSummary(period.id);
        expect(s.expected, 13);
        expect(s.trend.map((t) => t.label), [
          'Nov 2025 to Jan 2026',
          'Feb to Apr 2026',
        ]);
        expect(s.trend.first.expected, 13);
        expect(s.trend.first.submitted, 0);
        expect(s.people.any((p) => p.assignmentId == 'shalini'), isFalse);
      },
    );

    test('an unknown period is a readable failure', () async {
      await expectLater(
        repo.loadSummary('period-nope'),
        fails('That period does not exist.'),
      );
    });
  });
}
