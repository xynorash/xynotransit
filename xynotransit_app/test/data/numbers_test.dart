// Numbers: the largest values, sums that do not fit 32 bits, how text becomes
// a number, and how numbers are written. Written to pass on the web too
// (flutter test --platform chrome), where every int is a JavaScript number.
import 'package:flutter_test/flutter_test.dart';
import 'package:xynotransit_app/core/format.dart';
import 'package:xynotransit_app/domain/catalog.dart';
import 'package:xynotransit_app/domain/numbers.dart';
import 'package:xynotransit_app/domain/period.dart';
import 'package:xynotransit_app/domain/report.dart';
import 'package:xynotransit_app/domain/snapshot.dart';

Assignment eightCounts() => Assignment(
  id: 'a',
  code: 'a',
  personId: 'p',
  teamId: 't',
  roleTitle: 'r',
  sort: 1,
  metrics: [
    for (var i = 0; i < 8; i++)
      MetricDef(id: 'm$i', key: 'm$i', label: 'Count $i', series: i),
  ],
  kpis: const [],
);

void main() {
  group('parseCount', () {
    test('digits only', () {
      expect(parseCount('0'), 0);
      expect(parseCount('7'), 7);
      expect(parseCount('007'), 7);
      expect(parseCount('1000000000'), 1000000000);
      expect(parseCount('999999999'), 999999999);
    });

    test('refuses what the server refuses', () {
      for (final bad in [
        '',
        ' ',
        ' 5',
        '5 ',
        '5 0',
        '+5',
        '-5',
        '-0',
        '5.0',
        '5,0',
        '1,000',
        '1_000',
        '1e3',
        '0x10',
        '١٢', // Arabic-Indic digits
        '１２', // full width digits
        'five',
        '1000000001',
        '99999999999999999999',
        '999999999999999999999999',
        ' 5',
        '5\n',
      ]) {
        expect(parseCount(bad), isNull, reason: '"$bad"');
      }
    });

    test(
      'differs from int.tryParse exactly where that one is too generous',
      () {
        for (final s in [' 5', '+5', '-5', '0x10']) {
          expect(int.tryParse(s), isNotNull, reason: s);
          expect(parseCount(s), isNull, reason: s);
        }
      },
    );

    test('isCount', () {
      expect(isCount(0), isTrue);
      expect(isCount(countMax), isTrue);
      expect(isCount(-1), isFalse);
      expect(isCount(countMax + 1), isFalse);
      expect(countMax, NoteRules.valueMax);
    });
  });

  group('thousands', () {
    test('groups of three', () {
      expect(thousands(0), '0');
      expect(thousands(7), '7');
      expect(thousands(999), '999');
      expect(thousands(1000), '1,000');
      expect(thousands(12345), '12,345');
      expect(thousands(123456), '123,456');
      expect(thousands(1234567), '1,234,567');
      expect(thousands(1000000000), '1,000,000,000');
      expect(thousands(3000000000), '3,000,000,000');
      expect(thousands(24000000000), '24,000,000,000');
    });

    test('negative numbers keep one sign and the same groups', () {
      expect(thousands(-1), '-1');
      expect(thousands(-999), '-999');
      expect(thousands(-1000), '-1,000');
      expect(thousands(-1234567), '-1,234,567');
      expect(thousands(-3000000000), '-3,000,000,000');
    });

    test('the largest exact number of a JavaScript number', () {
      expect(thousands(jsSafeMax), '9,007,199,254,740,991');
      expect(thousands(-jsSafeMax), '-9,007,199,254,740,991');
    });

    test('a number and its text always agree', () {
      for (final n in [
        0,
        1,
        12,
        123,
        1234,
        12345,
        123456,
        1234567,
        12345678,
        123456789,
        1000000000,
        2999999999,
        3000000000,
        24000000000,
        999999999999,
      ]) {
        expect(thousands(n).replaceAll(',', ''), '$n');
        if (n != 0) expect(thousands(-n).replaceAll(',', ''), '-$n');
      }
    });
  });

  group('sums', () {
    test('three months of one billion, eight counts of that', () {
      const billion = 1000000000;
      final a = eightCounts();
      final r = Report(
        periodId: 'p',
        assignmentId: 'a',
        values: {
          for (final m in a.metrics) m.id: [billion, billion, billion],
        },
        kpis: const {},
        reporter: const Reporter(name: 'n', country: 'c', role: 'r'),
      );
      final p = Period(id: 'p', startMonth: DateTime(2026, 2));
      expect(r.validate(a, p), isEmpty);
      expect(r.totalOf('m0'), 3000000000);
      final seatTotal = a.metrics.fold(0, (n, m) => n + r.totalOf(m.id));
      expect(seatTotal, 24000000000);
      // The snapshot carries the same numbers.
      final snap = ReportSnapshot.build(
        report: r,
        assignment: a,
        catalog: Catalog(
          teams: const [Team(id: 't', code: 't', name: 'T', sort: 1)],
          persons: const [Person(id: 'p', fullName: 'P')],
          assignments: [a],
        ),
        period: p,
      );
      expect(snap.metrics.first.total, 3000000000);
      expect(snap.metrics.fold(0, (n, m) => n + m.total), 24000000000);
      // And it comes back out of JSON unchanged.
      final again = ReportSnapshot.fromJson(snap.toJson());
      expect(again.metrics.first.total, 3000000000);
    });

    test('a company of 1,000 seats at the limit is still exact', () {
      var total = 0;
      for (var i = 0; i < 1000; i++) {
        total += 8 * 3 * countMax;
      }
      expect(total, 24000000000000);
      expect(total, lessThan(jsSafeMax));
      expect(total.toDouble().toInt(), total);
    });

    test('one more than the limit, and below zero, are refused', () {
      final a = eightCounts();
      final p = Period(id: 'p', startMonth: DateTime(2026, 2));
      Report reportWith(int v) => Report(
        periodId: 'p',
        assignmentId: 'a',
        values: {
          for (final m in a.metrics) m.id: [v, 0, 0],
        },
        reporter: const Reporter(name: 'n', country: 'c', role: 'r'),
      );
      expect(reportWith(countMax).validate(a, p), isEmpty);
      expect(
        reportWith(countMax + 1).validate(a, p).first,
        'Enter a number for "Count 0" in February.',
      );
      expect(
        reportWith(countMax + 1).validate(a, p),
        contains('A number can be at most 1000000000.'),
      );
      expect(
        reportWith(-1).validate(a, p).first,
        'Enter a number for "Count 0" in February.',
      );
      expect(reportWith(0).validate(a, p), isEmpty);
    });
  });
}
