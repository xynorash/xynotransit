// A draft is typed against the counts and targets a seat had at the time. The
// manager may change them before it is sent. Report.reconcile cuts the draft
// down to what the seat defines now, and keeps the rest.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:xynotransit_app/data/memory_repository.dart';
import 'package:xynotransit_app/data/repository.dart';
import 'package:xynotransit_app/domain/admin.dart';
import 'package:xynotransit_app/domain/catalog.dart';
import 'package:xynotransit_app/domain/enums.dart';
import 'package:xynotransit_app/domain/period.dart';
import 'package:xynotransit_app/domain/report.dart';

Assignment seat({
  List<(String, String)> counts = const [('m1', 'Files'), ('m2', 'Calls')],
  List<(String, String)> targets = const [
    ('k1', 'On time'),
    ('k2', 'No errors'),
  ],
}) => Assignment(
  id: 'a',
  code: 'a',
  personId: 'p',
  teamId: 't',
  roleTitle: 'r',
  sort: 1,
  metrics: [
    for (final (i, c) in counts.indexed)
      MetricDef(id: c.$1, key: c.$1, label: c.$2, series: i),
  ],
  kpis: [
    for (final (i, k) in targets.indexed)
      KpiDef(id: k.$1, sort: i + 1, text: k.$2),
  ],
);

Report draft() => Report(
  periodId: 'p',
  assignmentId: 'a',
  values: {
    'm1': [1, 2, 3],
    'm2': [4, null, 6],
  },
  kpis: {
    'k1': const KpiResult(KpiStatus.met, comment: 'fine'),
    'k2': const KpiResult(KpiStatus.missed),
  },
  notes: {
    NoteKind.well: ['good'],
    NoteKind.wrong: ['bad'],
    NoteKind.next: [],
  },
  reporter: const Reporter(name: 'n', country: 'c', role: 'r'),
);

void main() {
  group('Report.reconcile', () {
    test('nothing changed: the same draft', () {
      final r = draft().reconcile(seat());
      expect(r.values, draft().values);
      expect(r.kpis.keys, ['k1', 'k2']);
      expect(r.kpis['k1']!.comment, 'fine');
      expect(r.notesOf(NoteKind.well), ['good']);
      expect(r.reporter, const Reporter(name: 'n', country: 'c', role: 'r'));
      final c = draft().reconciliation(seat());
      expect(c.lostAnswers, isFalse);
      expect(c.openCounts, 0);
      expect(c.openTargets, 0);
    });

    test('a retired count loses its numbers, the other keeps them', () {
      final r = draft().reconcile(seat(counts: [('m2', 'Calls')]));
      expect(r.values.keys, ['m2']);
      expect(r.values['m2'], [4, null, 6]);
      final c = draft().reconciliation(seat(counts: [('m2', 'Calls')]));
      expect(c.droppedCounts, 1);
      expect(c.lostAnswers, isTrue);
    });

    test('a retired count with nothing typed is not reported as lost', () {
      final d = draft().copyWith(
        values: {
          'm1': [null, null, null],
          'm2': [1, 2, 3],
        },
      );
      final c = d.reconciliation(seat(counts: [('m2', 'Calls')]));
      expect(c.droppedCounts, 0);
      expect(c.lostAnswers, isFalse);
    });

    test('a new count starts empty and is counted as open', () {
      final s = seat(
        counts: [('m1', 'Files'), ('m2', 'Calls'), ('m3', 'Courier')],
      );
      final c = draft().reconciliation(s);
      expect(c.report.values.containsKey('m3'), isFalse);
      expect(c.openCounts, 1);
      expect(
        c.report.validate(s, Period(id: 'p', startMonth: DateTime(2026, 2))),
        [
          'Enter a number for "Calls" in March.', // the draft's own gap
          'Enter a number for "Courier" in February.',
        ],
      );
    });

    test('a renamed count keeps its numbers (same id)', () {
      final s = seat(counts: [('m1', 'Documents'), ('m2', 'Calls')]);
      final r = draft().reconcile(s);
      expect(r.values['m1'], [1, 2, 3]);
    });

    test('a reordered seat keeps everything', () {
      final s = seat(counts: [('m2', 'Calls'), ('m1', 'Files')]);
      final r = draft().reconcile(s);
      expect(r.values, draft().values);
    });

    test('a retired target loses its answer, a new one is open', () {
      final s = seat(targets: [('k2', 'No errors'), ('k3', 'New one')]);
      final c = draft().reconciliation(s);
      expect(c.report.kpis.keys, ['k2']);
      expect(c.droppedTargets, 1);
      expect(c.openTargets, 1);
    });

    test(
      'a target with new words has a new id, so the old answer is dropped',
      () {
        // The server retires the old row and adds a new one when the words change.
        final s = seat(
          targets: [('k1-new', 'On time, in full'), ('k2', 'No errors')],
        );
        final r = draft().reconcile(s);
        expect(r.kpis.keys, ['k2']);
      },
    );

    test('a seat with no counts and no targets keeps only words and notes', () {
      final r = draft().reconcile(seat(counts: [], targets: []));
      expect(r.values, isEmpty);
      expect(r.kpis, isEmpty);
      expect(r.notesOf(NoteKind.well), ['good']);
      expect(r.reporter, isNotNull);
    });

    test('short value lists are padded to three slots, long ones cut', () {
      final d = draft().copyWith(
        values: {
          'm1': [5],
          'm2': [1, 2, 3, 4, 5],
        },
      );
      final r = d.reconcile(seat());
      expect(r.values['m1'], [5, null, null]);
      expect(r.values['m2'], [1, 2, 3]);
    });

    test('the draft itself is not changed', () {
      final d = draft();
      d.reconcile(seat(counts: [], targets: []));
      expect(d.values.keys, ['m1', 'm2']);
      expect(d.kpis.keys, ['k1', 'k2']);
    });

    test('a reconciled draft is accepted when it is complete', () async {
      // The full path against the in-memory server words.
      final repo = MemoryRepository(
        currentUser: () => DemoAuth.controller,
        withDemoReports: false,
      );
      final cat = await repo.loadCatalog();
      final s = cat.assignmentByCode('rova')!;
      final p = await repo.ensurePeriod(DateTime(2026, 2));
      // Draft typed against today's definitions.
      final typed = Report(
        periodId: p.id,
        assignmentId: s.id,
        values: {
          for (final m in s.metrics) m.id: [1, 2, 3],
        },
        kpis: {for (final k in s.kpis) k.id: const KpiResult(KpiStatus.met)},
        reporter: const Reporter(name: 'n', country: 'c', role: 'r'),
      );
      // The manager retires the first count and adds one.
      final changed = await repo.saveDefinitions(
        s.id,
        metrics: [
          MetricInput(id: s.metrics[1].id, label: s.metrics[1].label),
          const MetricInput(label: 'Courier'),
        ],
        kpis: [for (final k in s.kpis) KpiInput(id: k.id, text: k.text)],
      );
      await expectLater(
        repo.sendReport(typed),
        throwsA(
          isA<RepositoryException>().having(
            (e) => e.message,
            'm',
            'One of the numbers does not belong to this report.',
          ),
        ),
      );
      final r = typed.reconcile(changed);
      expect(r.values.keys, [s.metrics[1].id]);
      final withNew = r.copyWith(
        values: {
          ...r.values,
          changed.metrics[1].id: [7, 8, 9],
        },
      );
      final sent = await repo.sendReport(withNew);
      expect(sent.isSubmitted, isTrue);
    });
  });

  group('draft JSON', () {
    test('round trip, with a reconcile in the middle', () {
      final s =
          jsonDecode(jsonEncode(draft().toDraftJson())) as Map<String, Object?>;
      final back = Report.fromDraftJson('p', 'a', s);
      expect(back.values, draft().values);
      expect(back.kpis['k1']!.comment, 'fine');
      expect(back.notesOf(NoteKind.wrong), ['bad']);
      expect(back.reporter, draft().reporter);
    });

    test('a damaged draft gives a smaller draft, never an exception', () {
      final cases = <Map<String, Object?>>[
        {},
        {'values': 5},
        {
          'values': {'m1': 'x'},
        },
        {
          'values': {
            'm1': [1, 'two', null, 3.0, double.nan],
          },
        },
        {
          'kpis': {
            'k1': 5,
            'k2': {'status': 'nonsense'},
            'k3': {'status': 'met', 'comment': 4},
          },
        },
        {
          'notes': {
            'well': 'x',
            'wrong': [1, 'ok', null],
            'next': <String, Object?>{},
          },
        },
        {'reporter': 'nobody'},
        {
          'reporter': {'name': 5, 'country': null, 'role': 'r'},
        },
      ];
      for (final j in cases) {
        final r = Report.fromDraftJson('p', 'a', j);
        expect(r.periodId, 'p');
        // And it can always be reconciled and validated.
        r
            .reconcile(seat())
            .validate(seat(), Period(id: 'p', startMonth: DateTime(2026, 2)));
      }
      final r = Report.fromDraftJson('p', 'a', cases[3]);
      expect(r.values['m1'], [1, null, null, 3, null]);
      final k = Report.fromDraftJson('p', 'a', cases[4]);
      expect(k.kpis.keys, ['k3']);
      expect(k.kpis['k3']!.comment, isNull);
      final n = Report.fromDraftJson('p', 'a', cases[5]);
      expect(n.notesOf(NoteKind.wrong), ['ok']);
      expect(n.notesOf(NoteKind.well), isEmpty);
    });
  });
}
