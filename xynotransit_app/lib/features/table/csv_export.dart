import 'dart:convert';
import 'dart:typed_data';

import '../../domain/catalog.dart';
import '../../domain/enums.dart';
import '../../domain/period.dart';
import '../../domain/report.dart';

/// Header of the export. One long table, so it opens and pivots in Excel.
const csvHeader = [
  'Period',
  'Team',
  'Person',
  'Role',
  'Seat',
  'Type',
  'Item',
  'Month',
  'Value',
  'Status',
  'Text',
  'Sent at',
  // The words the person typed on the form, the ones the slides use. They come
  // after the first twelve columns, so a file reader built for those still works.
  'Reported name',
  'Reported country',
  'Reported role',
];

/// A text cell that a spreadsheet could read as a formula gets a leading
/// apostrophe, so it stays text (CSV injection).
String csvSafeText(String s) {
  if (s.isEmpty) return s;
  final c = s.codeUnitAt(0);
  const risky = {0x3D, 0x2B, 0x2D, 0x40, 0x09, 0x0D}; // = + - @ tab CR
  return risky.contains(c) ? "'$s" : s;
}

/// RFC 4180 quoting: quote when the cell holds a comma, quote or line break.
String csvQuote(String s) {
  if (s.contains(RegExp(r'[",\r\n]'))) {
    return '"${s.replaceAll('"', '""')}"';
  }
  return s;
}

String _cell(Object? v) {
  if (v == null) return '';
  if (v is int) return v.toString();
  return csvQuote(csvSafeText(v as String));
}

String _stamp(DateTime? d) {
  if (d == null) return '';
  final u = d.toUtc();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${u.year}-${two(u.month)}-${two(u.day)} ${two(u.hour)}:${two(u.minute)} UTC';
}

/// The period's submitted reports as CSV text (CRLF lines, no BOM).
///
/// A switched-off seat is listed when it has a sent report (those reports are
/// real) and never as Missing. The last three columns hold the name, country
/// and role as the person typed them (empty on reports sent before those
/// fields existed).
///
/// Types: Count (one row per count and month), Target (status and comment),
/// Note (one row per note) and Missing (a seat with no sent report).
String buildReportsCsv({
  required Period period,
  required Catalog catalog,
  required List<Report> reports,
}) {
  final byAssignment = {
    for (final r in reports)
      if (r.isSubmitted) r.assignmentId: r,
  };
  final rows = <List<Object?>>[csvHeader];
  final months = period.months;
  for (final a in catalog.assignments) {
    final typed = byAssignment[a.id]?.reporter;
    // Nobody is waiting for a switched-off seat.
    if (byAssignment[a.id] == null && !catalog.isExpected(a)) continue;
    final person = catalog.personOf(a).fullName;
    final team = catalog.teamOf(a).name;
    List<Object?> row({
      required String type,
      String item = '',
      String month = '',
      int? value,
      String status = '',
      String text = '',
      DateTime? sent,
    }) => [
      period.label,
      team,
      person,
      a.roleTitle,
      a.code,
      type,
      item,
      month,
      value,
      status,
      text,
      _stamp(sent),
      typed?.name.trim() ?? '',
      typed?.country.trim() ?? '',
      typed?.role.trim() ?? '',
    ];
    final r = byAssignment[a.id];
    if (r == null) {
      rows.add(row(type: 'Missing'));
      continue;
    }
    final known = {for (final m in a.metrics) m.id};
    final countIds = [
      ...a.metrics.map((m) => m.id),
      ...r.values.keys.where((k) => !known.contains(k)),
    ];
    for (final id in countIds) {
      final label = a.metrics.where((m) => m.id == id).firstOrNull?.label;
      for (final m in months) {
        rows.add(
          row(
            type: 'Count',
            item: label ?? '(retired count)',
            month: '${m.year}-${m.month.toString().padLeft(2, '0')}',
            value: r.valueOf(id, m.offset),
            sent: r.submittedAt,
          ),
        );
      }
    }
    final knownKpi = {for (final k in a.kpis) k.id};
    final kpiIds = [
      ...a.kpis.map((k) => k.id),
      ...r.kpis.keys.where((k) => !knownKpi.contains(k)),
    ];
    for (final id in kpiIds) {
      final res = r.kpis[id];
      if (res == null) continue;
      final text = a.kpis.where((k) => k.id == id).firstOrNull?.text;
      rows.add(
        row(
          type: 'Target',
          item: text ?? '(retired target)',
          status: res.status.name,
          text: res.comment ?? '',
          sent: r.submittedAt,
        ),
      );
    }
    for (final k in NoteKind.values) {
      for (final n in r.notesOf(k)) {
        rows.add(
          row(type: 'Note', item: k.slideTitle, text: n, sent: r.submittedAt),
        );
      }
    }
  }
  return '${rows.map((r) => r.map(_cell).join(',')).join('\r\n')}\r\n';
}

/// UTF-8 with a byte order mark, so Excel reads accents and symbols right.
Uint8List csvBytes(String csv) =>
    Uint8List.fromList([0xEF, 0xBB, 0xBF, ...utf8.encode(csv)]);

/// "Xynotransit_reports_Feb_to_Apr_2026" (ASCII, safe for any file system).
String csvFileBase(Period period) {
  final slug = period.label
      .replaceAll(RegExp(r'[^A-Za-z0-9]+'), '_')
      .replaceAll(RegExp(r'^_+|_+$'), '');
  return 'Xynotransit_reports_$slug';
}
