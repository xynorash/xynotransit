const monthShort = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

const monthLong = [
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
];

const _weekdays = [
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
  'Sunday',
];

/// 1234567 -> "1,234,567".
String thousands(int n) {
  final s = n.abs().toString();
  final b = StringBuffer(n < 0 ? '-' : '');
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
    b.write(s[i]);
  }
  return b.toString();
}

String _two(int n) => n.toString().padLeft(2, '0');

/// "Tuesday 09 June 2026".
String longDate(DateTime d) =>
    '${_weekdays[d.weekday - 1]} ${_two(d.day)} ${monthLong[d.month - 1]} ${d.year}';

/// "12 Jun".
String shortDate(DateTime d) => '${d.day} ${monthShort[d.month - 1]}';

/// "12 Jun, 14:05".
String shortDateTime(DateTime d) =>
    '${shortDate(d)}, ${_two(d.hour)}:${_two(d.minute)}';

String truncate(String s, int max) =>
    s.length <= max ? s : '${s.substring(0, max)}…';
