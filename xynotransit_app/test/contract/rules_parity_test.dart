// The API publishes every limit and fixed message it enforces in
// xynotransit-api/tests/fixtures/rules.json. This test holds every Dart
// constant and every Dart message against that file, so the two sides cannot
// drift apart without a red test.
//
// The file is written by the API side. When it is not there yet the test waits
// (up to 20 minutes, checking every 10 seconds) and then skips with a message.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xynotransit_app/domain/admin.dart';
import 'package:xynotransit_app/domain/catalog.dart';
import 'package:xynotransit_app/domain/enums.dart';
import 'package:xynotransit_app/domain/period.dart';
import 'package:xynotransit_app/domain/report.dart';
import 'package:xynotransit_app/features/form/form_controller.dart'
    show kpiCommentMax;

const _path = '../xynotransit-api/tests/fixtures/rules.json';

Future<Map<String, dynamic>?> _load() async {
  final f = File(_path);
  final end = DateTime.now().add(const Duration(minutes: 20));
  while (!f.existsSync()) {
    if (DateTime.now().isAfter(end)) return null;
    await Future<void>.delayed(const Duration(seconds: 10));
  }
  return jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
}

/// Fills `{name}` templates.
String fill(String t, Map<String, Object> v) =>
    t.replaceAllMapped(RegExp(r'\{(\w+)\}'), (m) => '${v[m[1]] ?? m[0]}');

void main() {
  late Map<String, dynamic> rules;
  var found = true;
  setUpAll(() async {
    final r = await _load();
    if (r == null) {
      found = false;
    } else {
      rules = r;
    }
  });

  Map<String, dynamic> section(String k) => rules[k] as Map<String, dynamic>;
  String msg(String k) => section('messages')[k] as String;
  int lim(String k) => section('limits')[k] as int;

  void needsRules() {
    if (!found) {
      markTestSkipped(
        'skipped: $_path did not appear within 20 minutes '
        '(the API side writes it)',
      );
    }
  }

  test('the file is there and is the version this test knows', () {
    needsRules();
    if (!found) return;
    expect(rules['version'], 1);
  }, timeout: const Timeout(Duration(minutes: 21)));

  test('limits equal the Dart constants', () {
    needsRules();
    if (!found) return;
    expect(lim('person_name'), DefinitionRules.maxName);
    expect(lim('role_title'), DefinitionRules.maxRoleTitle);
    expect(lim('reporter_name'), Reporter.maxLength);
    expect(lim('reporter_country'), Reporter.maxLength);
    expect(lim('reporter_role'), Reporter.maxLength);
    expect(lim('team_name'), AdminRules.maxTeamName);
    expect(lim('metric_label'), DefinitionRules.maxMetricLabel);
    expect(lim('kpi_text'), DefinitionRules.maxKpiText);
    expect(lim('max_metrics'), DefinitionRules.maxMetrics);
    expect(lim('max_kpis'), DefinitionRules.maxKpis);
    expect(lim('note_chars'), NoteRules.maxLength);
    expect(lim('notes_per_kind'), NoteRules.maxCount);
    expect(lim('comment_chars'), kpiCommentMax);
    expect(lim('value_min'), 0);
    expect(lim('value_max'), NoteRules.valueMax);
    expect(lim('email_chars'), AdminRules.maxEmail);
    expect(lim('email_local_chars'), AdminRules.maxEmailLocal);
    expect(lim('sort_max'), AdminRules.maxSort);
    expect(
      lim('months_per_period'),
      Period(id: 'p', startMonth: DateTime(2026)).months.length,
    );
    // Years: the edges are in, one outside is out.
    expect(AdminRules.checkDate(DateTime(lim('period_min_year'))).ok, isTrue);
    expect(
      AdminRules.checkDate(DateTime(lim('period_min_year') - 1)).ok,
      isFalse,
    );
    expect(
      AdminRules.checkDate(DateTime(lim('period_max_year'), 12, 31)).ok,
      isTrue,
    );
    expect(
      AdminRules.checkDate(DateTime(lim('period_max_year') + 1)).ok,
      isFalse,
    );
  }, timeout: const Timeout(Duration(minutes: 21)));

  test('enums equal the Dart enums', () {
    needsRules();
    if (!found) return;
    final e = section('enums');
    expect(e['note_kinds'], NoteKind.values.map((k) => k.name).toList());
    expect(e['kpi_statuses'], KpiStatus.values.map((k) => k.name).toList());
    expect(e['app_roles'], AppRole.values.map((k) => k.name).toList());
  }, timeout: const Timeout(Duration(minutes: 21)));

  /// Messages the typed Dart model cannot cause: the shape of a request body,
  /// a number outside what a form can build, the sign-in limit. The API
  /// enforces them; the app never sends them. A new key in the file must be
  /// put in one of the two lists, so nothing is added unseen.
  const serverOnly = {
    'app_role_invalid', // roles are an enum in Dart
    'sort_range', // the app does not send an order number
    'month_outside', // months are 0 to 2 by construction
    'value_twice', // values are keyed by count and month
    'kpi_twice',
    'kpi_status', // statuses are an enum
    'note_box', // boxes are an enum
    'note_number', // positions are the list order
    'note_same_number',
    'date_format', // dates are sent as yyyy-mm-dd by the app
    'choose_period', // the app always names a period
    'too_many_links', // shown from the server answer as is
  };

  test('every message is either produced by Dart or declared server only', () {
    needsRules();
    if (!found) return;
    final seat = Assignment(
      id: 'a',
      code: 'a',
      personId: 'p',
      teamId: 't',
      roleTitle: 'r',
      sort: 1,
      metrics: [
        const MetricDef(id: 'm', key: 'files', label: 'Files', series: 0),
      ],
      kpis: [
        const KpiDef(id: 'k1', sort: 1, text: 'x'),
        const KpiDef(id: 'k2', sort: 2, text: 'y'),
      ],
    );
    final period = Period(id: 'p', startMonth: DateTime(2026, 11));
    const who = Reporter(name: 'n', country: 'c', role: 'r');
    Report full({
      Reporter reporter = who,
      Map<String, List<int?>>? values,
      Map<String, KpiResult>? kpis,
      Map<NoteKind, List<String>>? notes,
    }) => Report(
      periodId: 'p',
      assignmentId: 'a',
      reporter: reporter,
      values:
          values ??
          {
            'm': [1, 2, 3],
          },
      kpis:
          kpis ??
          {
            'k1': const KpiResult(KpiStatus.met),
            'k2': const KpiResult(KpiStatus.met),
          },
      notes: notes,
    );
    String? first(Report r) => r.validate(seat, period).firstOrNull;

    final produced = <String, String?>{
      'team_empty': AdminRules.cleanTeamName('').problem,
      'team_long': AdminRules.cleanTeamName('x' * (lim('team_name') + 1))
          .problem,
      'name_empty': AdminRules.cleanPersonName('').problem,
      'name_long': AdminRules.cleanPersonName('x' * (lim('person_name') + 1))
          .problem,
      'role_title_empty': AdminRules.cleanRoleTitle('').problem,
      'role_title_long': AdminRules.cleanRoleTitle(
        'x' * (lim('role_title') + 1),
      ).problem,
      'plain_line': AdminRules.cleanTeamName('a​b').problem,
      'email_invalid': AdminRules.cleanEmail('nope').problem,
      'metrics_too_many': AdminRules.checkMetrics([
        for (var i = 0; i <= lim('max_metrics'); i++) MetricInput(label: 'c$i'),
      ]),
      'metric_empty': AdminRules.checkMetrics(const [MetricInput(label: ' ')]),
      'metric_long': AdminRules.checkMetrics([
        MetricInput(label: 'x' * (lim('metric_label') + 1)),
      ]),
      'metric_duplicate': AdminRules.checkMetrics(const [
        MetricInput(label: 'a'),
        MetricInput(label: 'A'),
      ]),
      'kpis_too_many': AdminRules.checkKpis([
        for (var i = 0; i <= lim('max_kpis'); i++) KpiInput(text: 't$i'),
      ]),
      'kpi_empty': AdminRules.checkKpis(const [KpiInput(text: ' ')]),
      'kpi_long': AdminRules.checkKpis([
        KpiInput(text: 'x' * (lim('kpi_text') + 1)),
      ]),
      'listed_twice': AdminRules.checkMetrics(const [
        MetricInput(id: 'u', label: 'a'),
        MetricInput(id: 'u', label: 'b'),
      ]),
      'reporter_empty': first(
        full(
          reporter: const Reporter(name: ' ', country: 'c', role: 'r'),
        ),
      ),
      'reporter_long': first(
        full(
          reporter: Reporter(name: 'x' * 81, country: 'c', role: 'r'),
        ),
      ),
      'reporter_plain': first(
        full(
          reporter: const Reporter(name: 'a​b', country: 'c', role: 'r'),
        ),
      ),
      'value_not_yours': first(
        full(
          values: {
            'm': [1, 2, 3],
            'zz': [1, 2, 3],
          },
        ),
      ),
      'kpi_not_yours': first(
        full(
          kpis: {
            'k1': const KpiResult(KpiStatus.met),
            'k2': const KpiResult(KpiStatus.met),
            'zz': const KpiResult(KpiStatus.met),
          },
        ),
      ),
      'value_missing': first(
        full(
          values: {
            'm': [1, null, 3],
          },
        ),
      ),
      // The server names the missing number first and the size second.
      'value_too_big': full(
        values: {
          'm': [1, 1000000001, 3],
        },
      ).validate(seat, period).skip(1).firstOrNull,
      'date_range': AdminRules.checkDate(DateTime(1999)).problem,
      'kpis_left': first(full(kpis: {'k1': const KpiResult(KpiStatus.met)})),
      'comment_long': first(
        full(
          kpis: {
            'k1': KpiResult(
              KpiStatus.met,
              comment: 'c' * (lim('comment_chars') + 1),
            ),
            'k2': const KpiResult(KpiStatus.met),
          },
        ),
      ),
      'nul_text': first(
        full(
          notes: {
            NoteKind.well: ['a\u0000'],
            NoteKind.wrong: [],
            NoteKind.next: [],
          },
        ),
      ),
      'notes_too_many': first(
        full(
          notes: {
            NoteKind.well: ['a', 'b', 'c', 'd'],
            NoteKind.wrong: [],
            NoteKind.next: [],
          },
        ),
      ),
      'note_empty': first(
        full(
          notes: {
            NoteKind.well: [' '],
            NoteKind.wrong: [],
            NoteKind.next: [],
          },
        ),
      ),
      'note_long': first(
        full(
          notes: {
            NoteKind.well: ['x' * (lim('note_chars') + 1)],
            NoteKind.wrong: [],
            NoteKind.next: [],
          },
        ),
      ),
      'trend_range': null, // checked in the contract suite (needs a repository)
    };

    final messages = section('messages').keys.toSet();
    // Every key is known to this test.
    expect(
      messages.difference({...produced.keys, ...serverOnly}),
      isEmpty,
      reason: 'a new message in rules.json: decide if Dart produces it',
    );
    for (final k in produced.keys) {
      if (k == 'trend_range') continue;
      expect(messages, contains(k), reason: 'rules.json lost "$k"');
    }

    // Plain messages are string for string. Templates are filled first.
    const templates = {
      'listed_twice': {'what': 'count'},
      'reporter_empty': {'what': 'name'},
      'reporter_long': {'what': 'name'},
      'reporter_plain': {'what': 'name'},
      'value_missing': {'label': 'Files', 'month': 'November'},
      'kpis_left': {'left': 2},
    };
    // value_missing is for the second month; its month is December.
    for (final e in produced.entries) {
      final k = e.key;
      if (k == 'trend_range') continue;
      var want = msg(k);
      final vars = <String, Object>{...?templates[k]};
      if (k == 'value_missing') vars['month'] = 'December';
      if (k == 'kpis_left') vars['left'] = 1;
      want = fill(want, vars);
      expect(e.value, want, reason: k);
    }

    // The server-only messages are at least well formed plain sentences.
    for (final k in serverOnly) {
      expect(msg(k), isNotEmpty, reason: k);
    }
  }, timeout: const Timeout(Duration(minutes: 21)));

  test('the trend words are the ones the in-memory demo uses', () {
    needsRules();
    if (!found) return;
    expect(msg('trend_range'), 'The trend must be a number from 1 to 24.');
    expect(lim('trend_max'), 24);
    expect(lim('trend_default'), 6);
  }, timeout: const Timeout(Duration(minutes: 21)));

  test('date words', () {
    needsRules();
    if (!found) return;
    expect(msg('date_format'), 'Enter a date like 2026-02-01.');
  }, timeout: const Timeout(Duration(minutes: 21)));

  test('the email shape and the trimming rules agree on the usual cases', () {
    needsRules();
    if (!found) return;
    expect(
      AdminRules.cleanEmail('  Ana@Example.ORG ').value,
      'ana@example.org',
    );
    expect(
      AdminRules.cleanEmail('${'a' * (lim('email_local_chars') + 1)}@x.org').ok,
      isFalse,
    );
    expect(
      AdminRules.cleanEmail('${'a' * lim('email_local_chars')}@x.org').ok,
      isTrue,
    );
  }, timeout: const Timeout(Duration(minutes: 21)));

  test('the deck word defaults are the same file on both sides', () {
    final app = File('docs/reference/deck_text_defaults.json')
        .readAsStringSync();
    for (final other in [
      '../xynotransit-api/tests/fixtures/deck_text_defaults.json',
      '../xynotransit-api/src/deck_text_defaults.json',
    ]) {
      final f = File(other);
      if (!f.existsSync()) {
        markTestSkipped('$other is not there');
        continue;
      }
      expect(jsonDecode(f.readAsStringSync()), jsonDecode(app), reason: other);
    }
  });

  test('the reference schema is the core schema of the database', () {
    final ref = File('docs/reference/schema.sql');
    final db = File('../xynotransit-db/initdb/01-schema.sql');
    if (!db.existsSync()) {
      markTestSkipped('${db.path} is not there');
      return;
    }
    expect(db.readAsStringSync(), ref.readAsStringSync());
  });
}
