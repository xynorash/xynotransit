import '../core/format.dart';
import 'enums.dart';

class MonthRef {
  const MonthRef({
    required this.offset,
    required this.year,
    required this.month,
  });
  final int offset;
  final int year;

  /// 1..12
  final int month;

  String get short => monthShort[month - 1];
  String get long => monthLong[month - 1];

  Map<String, Object?> toJson() => {
    'offset': offset,
    'year': year,
    'month': month,
    'short': short,
  };

  factory MonthRef.fromJson(Map<String, Object?> j) => MonthRef(
    offset: (j['offset']! as num).toInt(),
    year: (j['year']! as num).toInt(),
    month: (j['month']! as num).toInt(),
  );
}

/// Three consecutive months, identified by the first one.
class Period {
  Period({
    required this.id,
    required DateTime startMonth,
    this.meetingDate,
    this.status = PeriodStatus.open,
  }) : startMonth = DateTime(startMonth.year, startMonth.month);

  final String id;
  final DateTime startMonth;
  final DateTime? meetingDate;
  final PeriodStatus status;

  List<MonthRef> get months => List.generate(3, (i) {
    final d = DateTime(startMonth.year, startMonth.month + i);
    return MonthRef(offset: i, year: d.year, month: d.month);
  });

  MonthRef get firstMonth => months.first;
  MonthRef get lastMonth => months.last;

  /// "Feb to Apr 2026", or "Nov 2026 to Jan 2027" across a year end.
  String get label => labelFor(startMonth);

  static String labelFor(DateTime start) {
    final first = DateTime(start.year, start.month);
    final last = DateTime(start.year, start.month + 2);
    final a = monthShort[first.month - 1];
    final b = monthShort[last.month - 1];
    return first.year == last.year
        ? '$a to $b ${last.year}'
        : '$a ${first.year} to $b ${last.year}';
  }

  /// The three months that ended most recently: first month is today minus three months.
  static DateTime defaultStart(DateTime today) =>
      DateTime(today.year, today.month - 3);

  /// Start of the quarter-like window for the given first month and year.
  static DateTime start(int year, int month) => DateTime(year, month);

  static String dateOnly(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}
