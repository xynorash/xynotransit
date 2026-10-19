import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xynotransit_app/data/api/api_models.dart';
import 'package:xynotransit_app/domain/catalog.dart';
import 'package:xynotransit_app/domain/enums.dart';
import 'package:xynotransit_app/domain/period.dart';
import 'package:xynotransit_app/domain/snapshot.dart';

/// The same case the Rust snapshot builder test reads: the employee's live
/// preview must produce exactly the data the server freezes into the deck.
void main() {
  final file = File('../xynotransit-api/tests/fixtures/snapshot_case.json');
  final missing = !file.existsSync();

  test(
    'the live preview snapshot equals the shared expected_snapshot',
    () {
      final j = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
      final cat = j['catalog']! as Map<String, Object?>;
      final a = cat['assignment']! as Map<String, Object?>;

      final metrics = [
        for (final m in cat['metrics']! as List<Object?>)
          (m! as Map<String, Object?>),
      ]..sort((x, y) => (x['series']! as int).compareTo(y['series']! as int));
      final kpis = [
        for (final k in cat['kpis']! as List<Object?>)
          (k! as Map<String, Object?>),
      ]..sort((x, y) => (x['sort']! as int).compareTo(y['sort']! as int));

      final assignment = Assignment(
        id: 'a-1',
        code: a['code']! as String,
        personId: 'p-1',
        teamId: 't-1',
        roleTitle: a['role_title']! as String,
        sort: 1,
        metrics: [
          for (final m in metrics)
            MetricDef(
              id: m['id']! as String,
              key: m['key']! as String,
              label: m['label']! as String,
              series: m['series']! as int,
            ),
        ],
        kpis: [
          for (final k in kpis)
            KpiDef(
              id: k['id']! as String,
              sort: k['sort']! as int,
              text: k['text']! as String,
            ),
        ],
      );
      final catalog = Catalog(
        teams: [
          Team(id: 't-1', code: 't', name: a['team_name']! as String, sort: 1),
        ],
        persons: [Person(id: 'p-1', fullName: a['person_name']! as String)],
        assignments: [assignment],
      );
      final start = DateTime.parse(
        (j['period']! as Map<String, Object?>)['start_month']! as String,
      );
      final period = Period(id: 'per', startMonth: start);

      final raw = Map<String, Object?>.from(j['report']! as Map);
      final report = parseReport({
        'id': 'r-1',
        'period_id': 'per',
        'assignment_id': 'a-1',
        'status': 'submitted',
        'submitted_at': '2026-11-01T00:00:00Z',
        ...raw,
      });
      expect(report.reporter, isNotNull);

      final snap = buildDraftSnapshot(report, assignment, catalog, period);
      // Round trip through JSON like the deck does.
      final got = jsonDecode(jsonEncode(snap.toJson()));
      expect(got, j['expected_snapshot']);
      expect(snap.targets[2].status, isNull);
      expect(snap.team, 'Madagascar');
      expect(snap.notesOf(NoteKind.well).first, 'First good thing');
    },
    skip: missing
        ? 'xynotransit-api/tests/fixtures/snapshot_case.json does not exist yet'
        : false,
  );
}
