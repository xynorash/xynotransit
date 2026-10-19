/// Pure JSON to model mapping for the API. No network, no Flutter: every
/// function takes decoded JSON, so it is testable alone.
library;

import '../../domain/admin.dart';
import '../../domain/catalog.dart';
import '../../domain/deck.dart';
import '../../domain/deck_text.dart';
import '../../domain/enums.dart';
import '../../domain/period.dart';
import '../../domain/report.dart';
import '../../domain/snapshot.dart';
import '../../domain/summary.dart';
import '../repository.dart';

typedef Json = Map<String, dynamic>;

RepositoryException _unreadable() =>
    const RepositoryException('The server sent an answer the app cannot read.');

/// A JSON object, or a readable failure.
Json asJson(Object? data) {
  if (data is Map) return data.cast<String, dynamic>();
  throw _unreadable();
}

/// A JSON list of objects. A missing or null list is empty.
List<Json> rowsOf(Object? data) => [
  if (data is List<dynamic>)
    for (final r in data)
      if (r is Map) r.cast<String, dynamic>(),
];

/// A timestamp as local time. Offsets such as +03:00 or Z are honoured.
DateTime parseTime(Object? s) => DateTime.parse(s! as String).toLocal();

DateTime? _dateOrNull(Object? s) {
  if (s is! String || s.isEmpty) return null;
  final d = DateTime.parse(s);
  // A date only value has no zone; a full timestamp keeps its calendar day.
  return DateTime(d.year, d.month, d.day);
}

AppRole parseRole(Object? s) =>
    s == 'controller' ? AppRole.controller : AppRole.contributor;

AppUser parseUser(Object? data) {
  final j = asJson(data);
  return AppUser(
    personId: j['person_id'] as String?,
    role: parseRole(j['role']),
    label: (j['label'] as String?) ?? 'Signed in',
  );
}

Map<String, Object?> userToJson(AppUser u) => {
  'person_id': u.personId,
  'role': u.role.name,
  'label': u.label,
};

Team parseTeam(Object? data) {
  final t = asJson(data);
  return Team(
    id: '${t['id']}',
    code: t['code'] as String,
    name: t['name'] as String,
    sort: (t['sort'] as num).toInt(),
  );
}

Person parsePerson(Object? data) {
  final p = asJson(data);
  return Person(
    id: '${p['id']}',
    fullName: p['full_name'] as String,
    email: p['email'] as String?,
    appRole: parseRole(p['app_role']),
    active: p['active'] as bool? ?? true,
  );
}

Assignment parseAssignment(Object? data) {
  final a = asJson(data);
  return Assignment(
    id: '${a['id']}',
    code: a['code'] as String,
    personId: '${a['person_id']}',
    teamId: '${a['team_id']}',
    roleTitle: a['role_title'] as String,
    sort: (a['sort'] as num).toInt(),
    active: a['active'] as bool? ?? true,
    metrics: [
      for (final m in rowsOf(a['metrics']))
        MetricDef(
          id: '${m['id']}',
          key: m['key'] as String,
          label: m['label'] as String,
          series: (m['series'] as num).toInt(),
        ),
    ]..sort((a, b) => a.series.compareTo(b.series)),
    kpis: [
      for (final k in rowsOf(a['kpis']))
        KpiDef(
          id: '${k['id']}',
          sort: (k['sort'] as num).toInt(),
          text: k['text'] as String,
        ),
    ]..sort((a, b) => a.sort.compareTo(b.sort)),
  );
}

Catalog parseCatalog(Object? data) {
  final j = asJson(data);
  return Catalog(
    teams: [for (final t in rowsOf(j['teams'])) parseTeam(t)],
    persons: [for (final p in rowsOf(j['persons'])) parsePerson(p)],
    assignments: [for (final a in rowsOf(j['assignments'])) parseAssignment(a)],
  );
}

/// Body of POST /teams and PATCH /teams/{id}.
Map<String, Object?> teamToJson(String name) => {'name': name.trim()};

/// Body of POST /persons and PATCH /persons/{id}. The email is lowercased here
/// too, the server does it as well.
Map<String, Object?> personToJson({
  required String fullName,
  required String email,
  required AppRole role,
  required bool active,
}) => {
  'full_name': fullName.trim(),
  'email': email.trim().toLowerCase(),
  'app_role': role.name,
  'active': active,
};

/// Body of POST /assignments.
Map<String, Object?> assignmentToJson({
  required String personId,
  required String teamId,
  required String roleTitle,
}) => {
  'person_id': personId,
  'team_id': teamId,
  'role_title': roleTitle.trim(),
};

/// Body of PUT /assignments/{id}/definitions. Entries without an id are new.
Map<String, Object?> definitionsToJson({
  required List<MetricInput> metrics,
  required List<KpiInput> kpis,
}) => {
  'metrics': [
    for (final m in metrics)
      {if (m.id != null) 'id': m.id, 'label': m.label.trim()},
  ],
  'kpis': [
    for (final k in kpis) {if (k.id != null) 'id': k.id, 'text': k.text.trim()},
  ],
};

Summary parseSummary(Object? data) {
  try {
    return Summary.fromJson(asJson(data).cast<String, Object?>());
  } on RepositoryException {
    rethrow;
  } on Object {
    throw _unreadable();
  }
}

NoteKind? _noteKind(Object? s) {
  for (final k in NoteKind.values) {
    if (k.name == s) return k;
  }
  return null;
}

Period parsePeriod(Object? data) {
  final j = asJson(data);
  return Period(
    id: '${j['id']}',
    startMonth: _dateOrNull(j['start_month'])!,
    meetingDate: _dateOrNull(j['meeting_date']),
    status: j['status'] == 'closed' ? PeriodStatus.closed : PeriodStatus.open,
  );
}

Report parseReport(Object? data) {
  final j = asJson(data);
  final values = <String, List<int?>>{};
  for (final v in rowsOf(j['values'])) {
    final offset = (v['month_offset'] as num).toInt();
    if (offset < 0 || offset > 2 || v['value'] == null) continue;
    final slots = values.putIfAbsent(
      '${v['metric_def_id']}',
      () => List.filled(3, null),
    );
    slots[offset] = (v['value'] as num).toInt();
  }
  final kpis = <String, KpiResult>{};
  for (final k in rowsOf(j['kpis'])) {
    final status = KpiStatus.tryParse(k['status'] as String?);
    if (status == null) continue;
    final comment = k['comment'] as String?;
    kpis['${k['kpi_def_id']}'] = KpiResult(
      status,
      comment: (comment == null || comment.isEmpty) ? null : comment,
    );
  }
  final byKind = {for (final k in NoteKind.values) k: <(int, String)>[]};
  for (final n in rowsOf(j['notes'])) {
    final kind = _noteKind(n['kind']);
    if (kind == null) continue;
    byKind[kind]!.add((
      (n['position'] as num?)?.toInt() ?? 0,
      n['text'] as String,
    ));
  }
  final notes = {
    for (final e in byKind.entries)
      e.key: [
        for (final n in (e.value..sort((a, b) => a.$1.compareTo(b.$1)))) n.$2,
      ],
  };
  return Report(
    id: j['id'] as String?,
    periodId: '${j['period_id']}',
    assignmentId: '${j['assignment_id']}',
    status: j['status'] == 'submitted'
        ? ReportStatus.submitted
        : ReportStatus.draft,
    submittedAt: j['submitted_at'] == null
        ? null
        : parseTime(j['submitted_at']),
    values: values,
    kpis: kpis,
    notes: notes,
    reporter: Reporter.fromJson(j['reporter']),
  );
}

List<Report> parseReports(Object? data) => [
  for (final r in rowsOf(data)) parseReport(r),
];

/// The body of PUT /periods/{id}/reports/{assignment_id}. Only typed numbers
/// are sent; the server decides whether the report is complete.
Map<String, Object?> reportToJson(Report r) => {
  'values': [
    for (final e in r.values.entries)
      for (var i = 0; i < 3 && i < e.value.length; i++)
        if (e.value[i] != null)
          {'metric_def_id': e.key, 'month_offset': i, 'value': e.value[i]},
  ],
  'kpis': [
    for (final e in r.kpis.entries)
      {
        'kpi_def_id': e.key,
        'status': e.value.status.name,
        'comment': _commentOrNull(e.value.comment),
      },
  ],
  'notes': [
    for (final kind in NoteKind.values)
      for (final (i, text) in r.notesOf(kind).indexed)
        {'kind': kind.name, 'position': i + 1, 'text': text},
  ],
  if (r.reporter != null) 'reporter': r.reporter!.toJson(),
};

String? _commentOrNull(String? c) {
  final t = c?.trim();
  return (t == null || t.isEmpty) ? null : t;
}

/// Null for JSON `null` (no deck generated yet).
DeckRun? parseDeckOrNull(Object? data) => data == null ? null : parseDeck(data);

DeckRun parseDeck(Object? data) {
  final j = asJson(data);
  return DeckRun(
    id: '${j['id']}',
    periodId: '${j['period_id']}',
    generatedAt: parseTime(j['generated_at']),
    expectedCount: (j['expected_count'] as num).toInt(),
    includedCount: (j['included_count'] as num).toInt(),
    items: [
      for (final it in rowsOf(j['items']))
        DeckItem(
          reportId: '${it['report_id']}',
          sort: (it['sort'] as num).toInt(),
          snapshot: ReportSnapshot.fromJson(asJson(it['snapshot'])),
        ),
    ],
    texts: DeckTexts.fromJson(j['texts'] is Map ? asJson(j['texts']) : null),
  );
}

/// Answer of GET and PUT /periods/{id}/deck-text.
DeckTextsState parseDeckTextsState(Object? data) {
  final j = asJson(data);
  return DeckTextsState(
    texts: DeckTexts.fromJson(
      j['settings'] is Map ? asJson(j['settings']) : null,
    ),
    inheritedFrom: j['inherited_from'] as String?,
  );
}
