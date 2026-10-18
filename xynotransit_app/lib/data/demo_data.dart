import '../domain/catalog.dart';
import '../domain/enums.dart';
import '../domain/report.dart';

const _customWell = [
  'New checklist cut down document errors',
  'All shipments cleared inside lead time',
  'Quick fix of a customs query',
];
const _customWrong = [
  'Two containers delayed at the port',
  'Supplier sent documents late',
  'Power cut slowed the declarations',
];
const _customNext = [
  'Train a back-up for peak weeks',
  'Agree one document format with forwarders',
  'Review lead times with the factory',
];

const _samples = {
  NoteKind.well: [
    'Declarations on time',
    'No issues raised by customs',
    'Good communication with the team',
  ],
  NoteKind.wrong: [
    'Errors in documents',
    'Demurrage charges',
    'Late or missed vessel',
  ],
  NoteKind.next: [
    'Be proactive on procedure changes',
    'Monitor every shipment closely',
    'Be faster on clearance',
  ],
};

const _comments = [
  'Two cases slipped because documents came late',
  'Better than last period, still not every time',
  'Waiting for the new procedure from head office',
  'One customer changed the plan at the last minute',
  'Covered by a colleague during leave',
];

/// A fixed, readable generator: same catalog gives the same numbers every run.
class _Rng {
  _Rng(this._s);
  int _s;
  int next(int max) {
    _s = (_s * 1103515245 + 12345) & 0x7fffffff;
    return _s % max;
  }
}

/// One submitted report for every assignment, for the given period.
List<Report> buildDemoReports(
  Catalog catalog,
  String periodId, {
  DateTime? now,
}) {
  final stamp = now ?? DateTime(2026, 5, 6, 9);
  final out = <Report>[];
  for (var i = 0; i < catalog.assignments.length; i++) {
    final a = catalog.assignments[i];
    final rng = _Rng(97 * (i + 3));
    final values = <String, List<int?>>{
      for (final m in a.metrics)
        m.id: [
          for (var month = 0; month < 3; month++)
            6 + rng.next(m.series == 2 ? 40 : 90) + month * 2,
        ],
    };
    final kpis = <String, KpiResult>{
      for (final k in a.kpis)
        k.id: KpiResult(switch (rng.next(10)) {
          < 6 => KpiStatus.met,
          < 9 => KpiStatus.partly,
          _ => KpiStatus.missed,
        }),
    };
    final side = _Rng(31 * (i + 5));
    final withComments = <String, KpiResult>{
      for (final e in kpis.entries)
        e.key: e.value.status != KpiStatus.met && side.next(2) == 0
            ? KpiResult(e.value.status, comment: _comments[side.next(5)])
            : e.value,
    };

    List<String> pick(NoteKind kind, List<String> custom) {
      final chips = _samples[kind]!;
      final n = 1 + rng.next(3);
      var list = <String>[];
      for (var j = 0; j < n; j++) {
        final text = j == n - 1 && n > 1
            ? custom[rng.next(custom.length)]
            : chips[rng.next(chips.length)];
        list = NoteRules.add(list, text);
      }
      return list;
    }

    out.add(
      Report(
        id: 'demo-${a.code}',
        periodId: periodId,
        assignmentId: a.id,
        status: ReportStatus.submitted,
        submittedAt: stamp.add(Duration(hours: i * 3)),
        values: values,
        kpis: withComments,
        notes: {
          NoteKind.well: pick(NoteKind.well, _customWell),
          NoteKind.wrong: pick(NoteKind.wrong, _customWrong),
          NoteKind.next: pick(NoteKind.next, _customNext),
        },
      ),
    );
  }
  return out;
}
