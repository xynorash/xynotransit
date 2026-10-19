// Every date a person sees is a calendar date, computed from date only values
// or converted to local time on purpose. These tests run under any time zone;
// run them under the extreme ones too:
//
//   for z in Pacific/Kiritimati America/Los_Angeles Indian/Antananarivo UTC; do
//     TZ=$z flutter test test/data/time_test.dart; done
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_test/flutter_test.dart';
import 'package:xynotransit_app/core/format.dart';
import 'package:xynotransit_app/data/api/api_models.dart';
import 'package:xynotransit_app/data/memory_repository.dart';
import 'package:xynotransit_app/data/repository.dart';
import 'package:xynotransit_app/domain/enums.dart';
import 'package:xynotransit_app/domain/period.dart';
import 'package:xynotransit_app/domain/summary.dart';

/// Months by plain arithmetic, no DateTime.
(int, int) monthAt(int year, int month, int offset) {
  final i = year * 12 + (month - 1) + offset;
  return (i ~/ 12, i % 12 + 1);
}

void main() {
  test('the test run honours TZ when it is set', () {
    // On the web the browser owns the zone.
    if (kIsWeb) {
      markTestSkipped('the browser decides the time zone');
      return;
    }
    final tz = Platform.environment['TZ'];
    if (tz == null) {
      markTestSkipped('TZ is not set: running in the machine time zone');
      return;
    }
    // Offsets in October 2026 (US daylight time ends on 1 November).
    final want = {
      'Pacific/Kiritimati': 14,
      'America/Los_Angeles': -7,
      'Indian/Antananarivo': 3,
      'UTC': 0,
    }[tz];
    if (want == null) return;
    expect(
      DateTime(2026, 10, 15, 12).timeZoneOffset,
      Duration(hours: want),
      reason: 'TZ=$tz',
    );
  });

  group('periods across every month', () {
    test('three months from every start, year 2000 to 2100', () {
      for (var y = 2000; y <= 2100; y++) {
        for (var m = 1; m <= 12; m++) {
          final p = Period(id: 'p', startMonth: DateTime(y, m, 28, 23, 59));
          expect(p.startMonth, DateTime(y, m), reason: '$y-$m');
          for (var i = 0; i < 3; i++) {
            final (ey, em) = monthAt(y, m, i);
            expect(p.months[i].year, ey, reason: '$y-$m +$i');
            expect(p.months[i].month, em, reason: '$y-$m +$i');
            expect(p.months[i].offset, i);
          }
          final (ly, lm) = monthAt(y, m, 2);
          final a = monthShort[m - 1];
          final b = monthShort[lm - 1];
          expect(
            p.label,
            ly == y ? '$a to $b $ly' : '$a $y to $b $ly',
            reason: '$y-$m',
          );
          expect(
            Period.dateOnly(p.startMonth),
            '${y.toString().padLeft(4, '0')}-${m.toString().padLeft(2, '0')}-01',
          );
        }
      }
    });

    test('the year boundary reads right', () {
      expect(
        Period(id: 'p', startMonth: DateTime(2026, 11)).label,
        'Nov 2026 to Jan 2027',
      );
      expect(
        Period(id: 'p', startMonth: DateTime(2026, 12)).label,
        'Dec 2026 to Feb 2027',
      );
      expect(
        Period(id: 'p', startMonth: DateTime(2026, 10)).label,
        'Oct to Dec 2026',
      );
      final p = Period(id: 'p', startMonth: DateTime(2026, 12));
      expect(p.months.map((m) => m.short), ['Dec', 'Jan', 'Feb']);
      expect(p.months.map((m) => m.year), [2026, 2027, 2027]);
      expect(p.lastMonth.long, 'February');
    });

    test('the default period is the three months that ended most recently', () {
      // (today, expected start month)
      final cases = <(DateTime, DateTime)>[
        (DateTime(2026, 10, 19), DateTime(2026, 7)),
        (DateTime(2026, 1, 1), DateTime(2025, 10)),
        (DateTime(2026, 1, 31, 23, 59, 59), DateTime(2025, 10)),
        (DateTime(2026, 3, 31, 23, 59, 59), DateTime(2025, 12)),
        (DateTime(2026, 2, 28, 12), DateTime(2025, 11)),
        (DateTime(2024, 2, 29, 12), DateTime(2023, 11)),
        (DateTime(2026, 12, 31, 23, 59, 59), DateTime(2026, 9)),
        // The nights daylight saving time starts and ends.
        (DateTime(2026, 3, 8, 3), DateTime(2025, 12)),
        (DateTime(2026, 3, 29, 3, 30), DateTime(2025, 12)),
        (DateTime(2026, 11, 1, 0, 30), DateTime(2026, 8)),
        (DateTime(2026, 10, 25, 2, 30), DateTime(2026, 7)),
      ];
      for (final (today, want) in cases) {
        expect(Period.defaultStart(today), want, reason: '$today');
      }
    });

    test(
      'a month in a zone with a clock change on day 1 still starts on day 1',
      () {
        for (var y = 2020; y <= 2030; y++) {
          for (var m = 1; m <= 12; m++) {
            expect(DateTime(y, m).day, 1);
            expect(
              Period(id: 'p', startMonth: DateTime(y, m)).startMonth.day,
              1,
            );
          }
        }
      },
    );
  });

  group('dates from the server are calendar dates', () {
    test('a date only value keeps its day', () {
      for (final s in [
        '2026-02-01',
        '2026-12-31',
        '2026-01-01',
        '2026-03-08',
        '2026-03-29',
        '2026-10-25',
        '2026-11-01',
        '2000-01-01',
        '2100-12-31',
      ]) {
        final p = parsePeriod({
          'id': 'x',
          'start_month': s,
          'meeting_date': s,
          'status': 'open',
        });
        final d = DateTime.parse(s);
        expect(p.meetingDate, DateTime(d.year, d.month, d.day), reason: s);
        expect(p.startMonth, DateTime(d.year, d.month), reason: s);
        expect(Period.dateOnly(p.meetingDate!), s);
      }
    });

    test('a timestamp keeps the calendar day it was written with', () {
      // The sender wrote 1 February, whatever the zone of this machine is.
      final p = parsePeriod({
        'id': 'x',
        'start_month': '2026-02-01T00:00:00+14:00',
        'meeting_date': '2026-12-31T23:30:00-11:00',
        'status': 'open',
      });
      expect(p.startMonth, DateTime(2026, 2));
      expect(p.meetingDate, DateTime(2026, 12, 31));
      final z = parsePeriod({
        'id': 'x',
        'start_month': '2026-02-01T00:00:00Z',
        'meeting_date': '2026-02-28T23:59:59Z',
        'status': 'open',
      });
      expect(z.startMonth, DateTime(2026, 2));
      expect(z.meetingDate, DateTime(2026, 2, 28));
    });

    test('summary trend start months are calendar months', () {
      for (final s in ['2026-11-01', '2027-01-01', '2026-03-01']) {
        final t = TrendPoint.fromJson({
          'period_id': 'p',
          'label': 'l',
          'start_month': s,
          'expected': 1,
          'submitted': 1,
          'met': 0,
          'partly': 0,
          'missed': 0,
          'volume_total': 0,
        });
        expect(Period.dateOnly(t.startMonth), s);
      }
    });

    test('a moment is shown in local time, on purpose', () {
      // 31 October 23:30 UTC is already 1 November in Kiritimati and still the
      // 31st in Los Angeles. The app shows the viewer's own clock.
      final t = parseTime('2026-10-31T23:30:00Z');
      expect(t.isUtc, isFalse);
      final utc = DateTime.utc(2026, 10, 31, 23, 30);
      expect(t.toUtc(), utc);
      final local = utc.toLocal();
      expect(shortDateTime(t), shortDateTime(local));
      expect(
        shortDateTime(t),
        '${local.day} ${monthShort[local.month - 1]}, '
        '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}',
      );
      // An offset in the text is honoured, not dropped.
      expect(
        parseTime('2026-10-31T23:30:00+03:00').toUtc(),
        DateTime.utc(2026, 10, 31, 20, 30),
      );
    });

    test('long and short dates are built from the calendar fields', () {
      expect(longDate(DateTime(2026, 6, 9)), 'Tuesday 09 June 2026');
      expect(longDate(DateTime(2026, 12, 31)), 'Thursday 31 December 2026');
      expect(longDate(DateTime(2027, 1, 1)), 'Friday 01 January 2027');
      expect(longDate(DateTime(2024, 2, 29)), 'Thursday 29 February 2024');
      expect(shortDate(DateTime(2026, 3, 8)), '8 Mar');
      // The nights the clock jumps.
      for (final d in [
        DateTime(2026, 3, 8, 2, 30),
        DateTime(2026, 3, 29, 2, 30),
        DateTime(2026, 11, 1, 1, 30),
        DateTime(2026, 10, 25, 2, 30),
      ]) {
        expect(
          longDate(DateTime(d.year, d.month, d.day)),
          startsWith(
            longDate(DateTime(d.year, d.month, d.day)).split(' ').first,
          ),
        );
        expect(
          shortDate(DateTime(d.year, d.month, d.day)),
          '${d.day} ${monthShort[d.month - 1]}',
        );
      }
    });
  });

  group('the in-memory backend keeps calendar dates', () {
    Future<void> check(MemoryRepository repo, DateTime start) async {
      final p = await repo.ensurePeriod(
        DateTime(start.year, start.month, 29, 23, 59),
      );
      expect(p.startMonth, DateTime(start.year, start.month));
      expect(
        p.id,
        'period-${Period.dateOnly(DateTime(start.year, start.month))}',
      );
      final again = await repo.ensurePeriod(
        DateTime(start.year, start.month, 2),
      );
      expect(again.id, p.id);
      await repo.setMeetingDate(
        p.id,
        DateTime(start.year, start.month, 28, 23, 59),
      );
      final q = await repo.ensurePeriod(start);
      expect(q.meetingDate, DateTime(start.year, start.month, 28));
      expect(
        Period.dateOnly(q.meetingDate!),
        '${start.year}-${start.month.toString().padLeft(2, '0')}-28',
      );
    }

    test('around the year end and the clock changes', () async {
      final repo = MemoryRepository(
        currentUser: () =>
            const AppUser(personId: null, role: AppRole.controller, label: 'c'),
      );
      for (final s in [
        DateTime(2026, 11),
        DateTime(2026, 12),
        DateTime(2027, 1),
        DateTime(2026, 3),
        DateTime(2026, 10),
        DateTime(2024, 2),
      ]) {
        await check(repo, s);
      }
    });
  });
}
