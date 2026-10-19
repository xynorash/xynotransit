import 'package:flutter_test/flutter_test.dart';
import 'package:xynotransit_app/data/demo_data.dart';
import 'package:xynotransit_app/domain/catalog.dart';
import 'package:xynotransit_app/domain/enums.dart';
import 'package:xynotransit_app/domain/report.dart';
import 'package:xynotransit_app/features/table/csv_export.dart';

import 'helpers.dart';

/// Minimal RFC 4180 reader, to prove the output round-trips.
List<List<String>> parseCsv(String s) {
  final rows = <List<String>>[];
  var row = <String>[];
  final cell = StringBuffer();
  var quoted = false;
  for (var i = 0; i < s.length; i++) {
    final c = s[i];
    if (quoted) {
      if (c == '"') {
        if (i + 1 < s.length && s[i + 1] == '"') {
          cell.write('"');
          i++;
        } else {
          quoted = false;
        }
      } else {
        cell.write(c);
      }
    } else if (c == '"') {
      quoted = true;
    } else if (c == ',') {
      row.add(cell.toString());
      cell.clear();
    } else if (c == '\r' && i + 1 < s.length && s[i + 1] == '\n') {
      row.add(cell.toString());
      cell.clear();
      rows.add(row);
      row = [];
      i++;
    } else {
      cell.write(c);
    }
  }
  return rows;
}

void main() {
  test('safe text: formula starters get an apostrophe', () {
    for (final s in ['=1+1', '+1', '-2', '@SUM(A1)', '\tx', '\rx']) {
      expect(csvSafeText(s), "'$s");
    }
    expect(csvSafeText('Plain'), 'Plain');
    expect(csvSafeText(''), '');
    expect(csvSafeText('a=b'), 'a=b');
  });

  test('quote: commas, quotes and line breaks', () {
    expect(csvQuote('a,b'), '"a,b"');
    expect(csvQuote('say "hi"'), '"say ""hi"""');
    expect(csvQuote('l1\nl2'), '"l1\nl2"');
    expect(csvQuote('plain'), 'plain');
  });

  test('bytes start with a UTF-8 BOM and keep unicode', () {
    final b = csvBytes('Zoë 日本 €');
    expect(b.sublist(0, 3), [0xEF, 0xBB, 0xBF]);
    expect(String.fromCharCodes(b.sublist(3)).length, greaterThan(9));
  });

  test('file name carries the period label', () {
    expect(csvFileBase(testPeriod), 'Xynotransit_reports_Feb_to_Apr_2026');
  });

  test('demo period: every count, target and note appears once', () {
    final reports = buildDemoReports(testCatalog, testPeriod.id);
    final csv = buildReportsCsv(
      period: testPeriod,
      catalog: testCatalog,
      reports: reports,
    );
    final rows = parseCsv(csv);
    expect(rows.first, csvHeader);
    expect(rows.every((r) => r.length == csvHeader.length), isTrue);
    var counts = 0, targets = 0, notes = 0, sum = 0;
    for (final r in reports) {
      final a = testCatalog.assignmentById(r.assignmentId)!;
      counts += a.metrics.length * 3;
      targets += r.kpis.length;
      notes += r.noteCount;
      sum += [for (final m in a.metrics) r.totalOf(m.id)]
          .fold(0, (x, y) => x + y);
    }
    expect(rows.where((r) => r[5] == 'Count').length, counts);
    expect(rows.where((r) => r[5] == 'Target').length, targets);
    expect(rows.where((r) => r[5] == 'Note').length, notes);
    expect(
      rows
          .where((r) => r[5] == 'Count')
          .fold<int>(0, (s, r) => s + int.parse(r[8])),
      sum,
    );
    expect(rows.where((r) => r[5] == 'Missing'), isEmpty);
    expect(csv.endsWith('\r\n'), isTrue);
  });

  test('partial period lists missing seats', () {
    final reports = buildDemoReports(
      testCatalog,
      testPeriod.id,
    ).take(3).toList();
    final rows = parseCsv(
      buildReportsCsv(
        period: testPeriod,
        catalog: testCatalog,
        reports: reports,
      ),
    );
    expect(
      rows.where((r) => r[5] == 'Missing').length,
      testCatalog.assignments.length - 3,
    );
  });

  test('drafts are left out; hostile text round-trips and is neutralised', () {
    final a = testCatalog.assignments.first;
    final kpi = a.kpis.first;
    final r = Report(
      periodId: testPeriod.id,
      assignmentId: a.id,
      status: ReportStatus.submitted,
      submittedAt: DateTime.utc(2026, 5, 1, 9, 5),
      values: {
        for (final m in a.metrics) m.id: [1, 2, 3],
      },
      kpis: {
        kpi.id: const KpiResult(
          KpiStatus.met,
          comment: '=HYPERLINK("x","y"), "q"\nline2 日本 é',
        ),
      },
      notes: {
        NoteKind.well: ['@cmd, "quoted"', '+1'],
        NoteKind.wrong: [],
        NoteKind.next: ['-5'],
      },
    );
    final draft = Report(
      periodId: testPeriod.id,
      assignmentId: testCatalog.assignments[1].id,
    );
    final rows = parseCsv(
      buildReportsCsv(
        period: testPeriod,
        catalog: testCatalog,
        reports: [r, draft],
      ),
    );
    final t = rows.firstWhere((x) => x[5] == 'Target');
    expect(t[9], 'met');
    expect(t[10], '\'=HYPERLINK("x","y"), "q"\nline2 日本 é');
    expect(t[11], '2026-05-01 09:05 UTC');
    final n = rows.where((x) => x[5] == 'Note').map((x) => x[10]).toList();
    expect(n, ['\'@cmd, "quoted"', "'+1", "'-5"]);
    expect(
      rows.where(
        (x) =>
            x[2] == testCatalog.personOf(testCatalog.assignments[1]).fullName &&
            x[5] == 'Missing',
      ),
      isNotEmpty,
    );
  });

  test('month column is year-month', () {
    final reports = buildDemoReports(testCatalog, testPeriod.id);
    final rows = parseCsv(
      buildReportsCsv(
        period: testPeriod,
        catalog: testCatalog,
        reports: reports,
      ),
    );
    expect(rows.where((r) => r[5] == 'Count').map((r) => r[7]).toSet(), {
      '2026-02',
      '2026-03',
      '2026-04',
    });
  });

  group('typed words and switched-off people', () {
    Report sent(Assignment a, {Reporter? reporter}) => Report(
      periodId: testPeriod.id,
      assignmentId: a.id,
      status: ReportStatus.submitted,
      submittedAt: DateTime.utc(2026, 5, 1, 9, 5),
      values: {
        for (final m in a.metrics) m.id: [1, 2, 3],
      },
      reporter: reporter,
    );

    test('the last three columns hold the typed name, country and role', () {
      expect(csvHeader.sublist(12), [
        'Reported name',
        'Reported country',
        'Reported role',
      ]);
      // The first twelve keep their place for old consumers.
      expect(csvHeader.sublist(0, 4), ['Period', 'Team', 'Person', 'Role']);
      final a = testCatalog.assignments.firstWhere((x) => x.hasCounts);
      final rows = parseCsv(
        buildReportsCsv(
          period: testPeriod,
          catalog: testCatalog,
          reports: [
            sent(
              a,
              reporter: const Reporter(
                name: 'R. Rakoto, "Rosa"',
                country: 'Kenya',
                role: '=Lead',
              ),
            ),
          ],
        ),
      );
      final counts = rows.where((r) => r[5] == 'Count').toList();
      expect(counts, isNotEmpty);
      for (final r in counts) {
        expect(r[12], 'R. Rakoto, "Rosa"');
        expect(r[13], 'Kenya');
        expect(r[14], "'=Lead", reason: 'formula starters stay text');
        // The profile columns still say what the profile says.
        expect(r[2], testCatalog.personOf(a).fullName);
      }
      // A missing seat has no typed words.
      final missing = rows.firstWhere((r) => r[5] == 'Missing');
      expect(missing.sublist(12), ['', '', '']);
    });

    test('a report sent before the typed words existed has empty cells', () {
      final a = testCatalog.assignments.firstWhere((x) => x.hasCounts);
      final rows = parseCsv(
        buildReportsCsv(
          period: testPeriod,
          catalog: testCatalog,
          reports: [sent(a)],
        ),
      );
      expect(rows.firstWhere((r) => r[5] == 'Count').sublist(12), ['', '', '']);
    });

    test('a switched-off person keeps their report and is never missing', () {
      final off = testCatalog.assignments.firstWhere((x) => x.hasCounts);
      final people = [
        for (final p in testCatalog.persons)
          p.id == off.personId
              ? Person(id: p.id, fullName: p.fullName, active: false)
              : p,
      ];
      final cat = Catalog(
        teams: testCatalog.teams,
        persons: people,
        assignments: testCatalog.assignments,
      );
      final withReport = parseCsv(
        buildReportsCsv(period: testPeriod, catalog: cat, reports: [sent(off)]),
      );
      expect(
        withReport.where((r) => r[4] == off.code && r[5] == 'Count'),
        isNotEmpty,
        reason: 'their sent report is still exported',
      );
      final without = parseCsv(
        buildReportsCsv(period: testPeriod, catalog: cat, reports: const []),
      );
      expect(
        without.where((r) => r[4] == off.code),
        isEmpty,
        reason: 'a switched-off seat is nobody to wait for',
      );
      expect(without.where((r) => r[5] == 'Missing').length, cat.expectedCount);
    });
  });
}
