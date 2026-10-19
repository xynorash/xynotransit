// The slide matrix: every slide type with ordinary, extreme and hostile data.
// Used by test/slide_matrix_test.dart (automatic checks, contact sheets).
//
// Limits behind the extremes (xynotransit-api/src/rules.rs): name 80, role 80,
// team 60 (reporter country 80), count label 60, target text 200, 10 targets,
// 8 counts, notes 70 characters and 3 per box, values up to 1,000,000,000.
import 'package:xynotransit_app/domain/deck.dart';
import 'package:xynotransit_app/domain/deck_text.dart';
import 'package:xynotransit_app/domain/enums.dart';
import 'package:xynotransit_app/domain/period.dart';
import 'package:xynotransit_app/domain/snapshot.dart';

/// One case of the matrix.
class MatrixCase {
  const MatrixCase(this.group, this.name, this.spec, {this.ellipsisOk = false});

  final String group;
  final String name;
  final SlideSpec spec;

  /// True only for inputs no real deck has (every template at its maximum
  /// with 80 wide letters in every name): the heading and footer may then end
  /// with an ellipsis. Every other check still applies.
  final bool ellipsisOk;

  /// True for the person slide that uses the dense two column target layout,
  /// where an ellipsis is part of the design.
  bool get denseTargets =>
      spec is KpiSlideSpec &&
      (spec as KpiSlideSpec).snapshot.targets.length > 6;
}

const _months = [
  MonthRef(offset: 0, year: 2026, month: 2),
  MonthRef(offset: 1, year: 2026, month: 3),
  MonthRef(offset: 2, year: 2026, month: 4),
];

/// [n] characters of [unit], repeated and cut.
String fill(String unit, int n) {
  final b = StringBuffer();
  while (b.length < n) {
    b.write(unit);
  }
  return b.toString().substring(0, n);
}

/// Words with spaces, [n] characters, ordinary Latin text.
String words(int n) => fill('Pallet transfer between hubs ', n).trimRight();

/// Wide letters with a space now and then, [n] characters.
String wide(int n) => fill('WWWWWWWW MMMMMMMM ', n).trimRight();

const _names = <String, String>{
  '1 char': 'R',
  '12 chars': 'Joyce Manoa R',
  'Rakotoarisoa': 'Rakotoarisoa Joyce Manoa',
  'accents': 'Zoé Ñandú',
  'ivoire': "Côte d'Ivoire",
  'CJK': '山田太郎 田中花子 佐藤',
  'Arabic': 'محمد عبد الرحمن الخطيب',
  '40 chars': 'Alexandrina Wolfeschlegelstein Haudenbau',
  '80 chars': 'Maria Guadalupe Hernandez-Rodriguez de la Concepcion Sanchez-Villalobos Ortega',
  'WWW 40': 'WWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWW',
  'WWW 80': 'WWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWW',
  'no spaces 80': 'Averyveryveryverylongsinglewordthatnevergetsabreakpointanywhereatallforsureok',
};

SnapshotMetric _metric(int i, String label, List<int> values) =>
    SnapshotMetric(key: 'm$i', label: label, series: i, values: values);

List<SnapshotMetric> metricsOf(
  int n, {
  String? label,
  List<int> values = const [120, 340, 560],
  List<List<int>>? each,
}) => [
  for (var i = 0; i < n; i++)
    _metric(
      i,
      label ?? 'Count ${i + 1}',
      each != null
          ? each[i % each.length]
          : [for (final v in values) v + i * 17],
    ),
];

List<SnapshotTarget> targetsOf(
  int n, {
  int len = 40,
  String Function(int)? text,
  KpiStatus? Function(int)? status,
}) => [
  for (var i = 0; i < n; i++)
    SnapshotTarget(
      text: text != null ? text(i) : '${i + 1} ${words(len - 2)}',
      status: (status ?? (j) => KpiStatus.values[j % 3])(i),
    ),
];

List<String> notesOf(int n, int len, {bool wideLetters = true}) => [
  for (var i = 0; i < n; i++)
    wideLetters ? wide(len) : '${i + 1} ${words(len - 2)}',
];

ReportSnapshot snap({
  String name = 'Hanitra Rakoto',
  String role = 'Freight coordinator',
  String team = 'Madagascar',
  List<SnapshotMetric>? metrics,
  List<SnapshotTarget>? targets,
  List<String> well = const ['Two new routes opened', 'Delays down by a third'],
  List<String> wrong = const ['One truck lost for a week'],
  List<String> next = const ['Hire two drivers', 'Close the Toamasina gap'],
}) => ReportSnapshot(
  assignmentCode: 'T-1',
  name: name,
  role: role,
  team: team,
  periodLabel: 'Feb to Apr 2026',
  months: _months,
  metrics: metrics ?? metricsOf(3),
  targets: targets ?? targetsOf(4),
  well: well,
  wrong: wrong,
  next: next,
);

/// Both slides of a person.
List<MatrixCase> _pair(
  String group,
  String name,
  ReportSnapshot s, {
  DeckTexts texts = DeckTexts.empty,
}) => [
  MatrixCase(group, '$name / KPI', KpiSlideSpec(s, texts: texts)),
  MatrixCase(group, '$name / results', ResultsSlideSpec(s, texts: texts)),
];

/// A text for [f] that is exactly as long as allowed and uses every
/// placeholder the field may contain.
String maxText(DeckTextField f) {
  if (f.key == 'suggestionsBody') return fill('Wide words need room. ', 400);
  final tokens = [for (final t in f.tokens) '{$t}'];
  final head = tokens.join(' ');
  final pad = f.maxLength - head.runes.length - (head.isEmpty ? 0 : 1);
  if (pad <= 0) return head;
  final sep = head.isEmpty ? '' : ' ';
  return '$head$sep${fill('Wmw ', pad)}'.substring(0, f.maxLength);
}

DeckTexts maxTexts() =>
    DeckTexts.fromJson({for (final f in deckTextFields) f.key: maxText(f)});

List<MatrixCase> slideMatrix() {
  final out = <MatrixCase>[];

  // 1. Names.
  for (final e in _names.entries) {
    out.addAll(_pair('names', e.key, snap(name: e.value)));
  }
  // Role and country at 80 characters, with and without word breaks.
  out.addAll(
    _pair('names', 'role+country 80', snap(role: words(80), team: words(80))),
  );
  out.addAll(
    _pair(
      'names',
      'all 80 wide',
      snap(name: wide(80), role: wide(80), team: wide(80)),
    ),
  );
  out.addAll(
    _pair(
      'names',
      'all 80 words',
      snap(name: words(80), role: words(80), team: words(80)),
    ),
  );
  out.addAll(_pair('names', 'role 80 only', snap(role: wide(80))));

  // 2. Counts with 60 character labels.
  for (final n in [0, 1, 2, 3, 4, 5, 8]) {
    out.add(
      MatrixCase(
        'counts',
        '$n counts label60',
        KpiSlideSpec(snap(metrics: metricsOf(n, label: words(60)))),
      ),
    );
    if (n >= 1 && n <= 3) {
      out.add(
        MatrixCase(
          'counts',
          '$n counts label60 wide letters',
          KpiSlideSpec(snap(metrics: metricsOf(n, label: wide(60)))),
        ),
      );
    }
    out.add(
      MatrixCase(
        'counts',
        '$n counts short',
        KpiSlideSpec(snap(metrics: metricsOf(n))),
      ),
    );
  }

  // 3. Values.
  for (final v in [0, 7, 99, 12345, 999999999, 1000000000]) {
    for (final n in [1, 3, 8]) {
      out.add(
        MatrixCase(
          'values',
          '$n counts all $v',
          KpiSlideSpec(snap(metrics: metricsOf(n, values: [v, v, v]))),
        ),
      );
    }
  }
  const mixed = [
    [0, 7, 1000000000],
    [12345, 3, 99],
    [1000000000, 1000000000, 0],
  ];
  for (final n in [2, 3, 5, 8]) {
    out.add(
      MatrixCase(
        'values',
        '$n counts mixed tiny/huge',
        KpiSlideSpec(snap(metrics: metricsOf(n, each: mixed))),
      ),
    );
  }
  out.add(
    MatrixCase(
      'values',
      '3 counts mixed, targets none',
      KpiSlideSpec(
        snap(
          metrics: metricsOf(3, each: mixed),
          targets: [],
        ),
      ),
    ),
  );

  // 4. Targets.
  for (var n = 0; n <= 10; n++) {
    for (final len in [15, 80, 200]) {
      out.add(
        MatrixCase(
          'targets',
          '$n targets x$len',
          KpiSlideSpec(snap(targets: targetsOf(n, len: len))),
        ),
      );
    }
  }
  for (final n in [1, 3, 6, 7, 10]) {
    out.add(
      MatrixCase(
        'targets',
        '$n all met',
        KpiSlideSpec(snap(targets: targetsOf(n, status: (_) => KpiStatus.met))),
      ),
    );
    out.add(
      MatrixCase(
        'targets',
        '$n all missed',
        KpiSlideSpec(
          snap(targets: targetsOf(n, status: (_) => KpiStatus.missed)),
        ),
      ),
    );
    out.add(
      MatrixCase(
        'targets',
        '$n unanswered',
        KpiSlideSpec(snap(targets: targetsOf(n, status: (_) => null))),
      ),
    );
    out.add(
      MatrixCase(
        'targets',
        '$n partly',
        KpiSlideSpec(
          snap(targets: targetsOf(n, status: (_) => KpiStatus.partly)),
        ),
      ),
    );
  }
  out.add(
    MatrixCase(
      'targets',
      '2 targets one word x200',
      KpiSlideSpec(snap(targets: targetsOf(2, text: (i) => 'Abcdefghij' * 20))),
    ),
  );
  out.add(
    MatrixCase(
      'targets',
      '1 target one word x200',
      KpiSlideSpec(snap(targets: targetsOf(1, text: (i) => 'W' * 200))),
    ),
  );
  out.add(
    MatrixCase(
      'targets',
      '3 targets no counts',
      KpiSlideSpec(snap(metrics: [], targets: targetsOf(3, len: 60))),
    ),
  );
  out.add(
    MatrixCase(
      'targets',
      '0 targets no counts',
      KpiSlideSpec(snap(metrics: [], targets: [])),
    ),
  );
  out.add(
    MatrixCase(
      'targets',
      '10 targets x200 no counts',
      KpiSlideSpec(snap(metrics: [], targets: targetsOf(10, len: 200))),
    ),
  );

  // 5. Notes.
  for (final n in [0, 1, 2, 3]) {
    for (final len in [1, 35, 70]) {
      if (n == 0 && len != 1) continue;
      final notes = notesOf(n, len);
      out.add(
        MatrixCase(
          'notes',
          '$n notes x$len wide',
          ResultsSlideSpec(snap(well: notes, wrong: notes, next: notes)),
        ),
      );
    }
  }
  out.add(
    MatrixCase(
      'notes',
      'uneven 3/0/1',
      ResultsSlideSpec(
        snap(well: notesOf(3, 70), wrong: [], next: notesOf(1, 5)),
      ),
    ),
  );
  out.add(
    MatrixCase(
      'notes',
      '3 notes x70 words',
      ResultsSlideSpec(
        snap(
          well: notesOf(3, 70, wideLetters: false),
          wrong: notesOf(3, 70, wideLetters: false),
          next: notesOf(3, 70, wideLetters: false),
        ),
      ),
    ),
  );
  out.add(
    MatrixCase(
      'notes',
      '3 notes x70 one word',
      ResultsSlideSpec(
        snap(
          well: [for (var i = 0; i < 3; i++) 'A' * 70],
          wrong: [for (var i = 0; i < 3; i++) 'Abcdefghij' * 7],
          next: ['W' * 70],
        ),
      ),
    ),
  );
  out.add(
    MatrixCase(
      'notes',
      '3 notes x70 CJK',
      ResultsSlideSpec(
        snap(
          well: [for (var i = 0; i < 3; i++) fill('配送が遅れました', 70)],
          wrong: [for (var i = 0; i < 3; i++) fill('配送が遅れました', 70)],
          next: [for (var i = 0; i < 3; i++) fill('配送が遅れました', 70)],
        ),
      ),
    ),
  );

  // 6. Deck texts at their maximum length.
  final mt = maxTexts();
  out.addAll(_pair('texts', 'max texts', snap(), texts: mt));
  for (final c in _pair(
    'texts',
    'max texts + 80 wide person',
    snap(name: wide(80), role: wide(80), team: wide(60)),
    texts: mt,
  )) {
    out.add(MatrixCase(c.group, c.name, c.spec, ellipsisOk: true));
  }
  out.add(
    MatrixCase(
      'texts',
      'max texts cover',
      CoverSpec(
        periodLabel: 'Nov 2026 to Jan 2027',
        meetingDate: DateTime(2026, 12, 3),
        teamCounts: [('Madagascar', 3), ('Kenya', 12)],
        texts: mt,
      ),
    ),
  );
  out.add(
    MatrixCase(
      'texts',
      'max texts divider',
      DividerSpec(
        team: 'Madagascar',
        periodLabel: 'Feb to Apr 2026',
        index: 1,
        total: 3,
        people: ['Hanitra Rakoto', 'Rova'],
        texts: mt,
      ),
    ),
  );
  out.add(
    MatrixCase(
      'texts',
      'max texts suggestions',
      SuggestionsSpec(periodLabel: 'Feb to Apr 2026', texts: mt),
    ),
  );

  // 7. Cover.
  final countries = [
    for (var i = 0; i < 12; i++)
      (
        [
              'Madagascar',
              'Kenya',
              'Cote d Ivoire',
              'South Africa',
              'Mozambique',
              'Tanzania',
            ][i % 6] +
            (i >= 6 ? ' East' : ''),
        i + 1,
      ),
  ];
  out.add(
    MatrixCase(
      'cover',
      'cover 1 country',
      CoverSpec(
        periodLabel: 'Feb to Apr 2026',
        meetingDate: DateTime(2026, 6, 9),
        teamCounts: [('Madagascar', 3)],
      ),
    ),
  );
  out.add(
    MatrixCase(
      'cover',
      'cover 12 countries',
      CoverSpec(
        periodLabel: 'Feb to Apr 2026',
        meetingDate: DateTime(2026, 6, 9),
        teamCounts: countries,
      ),
    ),
  );
  out.add(
    MatrixCase(
      'cover',
      'cover 12 countries x60',
      CoverSpec(
        periodLabel: 'Nov 2026 to Jan 2027',
        meetingDate: null,
        teamCounts: [for (var i = 0; i < 12; i++) (words(60), 100 + i)],
      ),
    ),
  );
  out.add(
    MatrixCase(
      'cover',
      'cover no date 0 teams',
      const CoverSpec(
        periodLabel: 'Feb to Apr 2026',
        meetingDate: null,
        teamCounts: [],
      ),
    ),
  );
  out.add(
    MatrixCase(
      'cover',
      'cover long own title',
      CoverSpec(
        periodLabel: 'Feb to Apr 2026',
        meetingDate: DateTime(2026, 6, 9),
        teamCounts: [('Madagascar', 3)],
        texts: DeckTexts.defaults
            .withValue('title', wide(80))
            .withValue('subtitle', words(120)),
      ),
    ),
  );
  out.add(
    MatrixCase(
      'cover',
      'cover default texts',
      CoverSpec(
        periodLabel: 'Feb to Apr 2026',
        meetingDate: DateTime(2026, 6, 9),
        teamCounts: [('Madagascar', 3), ('Kenya', 4)],
        texts: DeckTexts.defaults,
      ),
    ),
  );

  // 8. Dividers.
  for (final k in [1, 3, 8, 30]) {
    out.add(
      MatrixCase(
        'divider',
        'divider $k people',
        DividerSpec(
          team: 'Madagascar',
          periodLabel: 'Feb to Apr 2026',
          index: 1,
          total: 3,
          people: [
            for (var i = 0; i < k; i++)
              'Person number ${i + 1} · Freight coordinator',
          ],
        ),
      ),
    );
  }
  out.add(
    MatrixCase(
      'divider',
      'divider 30 people long',
      DividerSpec(
        team: wide(60),
        periodLabel: 'Feb to Apr 2026',
        index: 12,
        total: 12,
        people: [for (var i = 0; i < 30; i++) '${wide(80)} · ${words(80)}'],
      ),
    ),
  );
  out.add(
    MatrixCase(
      'divider',
      'divider 0 people',
      DividerSpec(
        team: 'Kenya',
        periodLabel: 'Feb to Apr 2026',
        index: 2,
        total: 3,
        people: const [],
      ),
    ),
  );
  out.add(
    MatrixCase(
      'divider',
      'divider team 60 wide',
      DividerSpec(
        team: wide(60),
        periodLabel: 'Feb to Apr 2026',
        index: 2,
        total: 3,
        people: ['Zoé Ñandú · Driver'],
      ),
    ),
  );

  // 9. Suggestions.
  out.add(
    MatrixCase(
      'suggestions',
      'suggestions 400',
      SuggestionsSpec(
        periodLabel: 'Feb to Apr 2026',
        texts: DeckTexts.defaults.withValue(
          'suggestionsBody',
          fill('Wide words need room. ', 400),
        ),
      ),
    ),
  );
  out.add(
    MatrixCase(
      'suggestions',
      'suggestions 400 lines',
      SuggestionsSpec(
        periodLabel: 'Feb to Apr 2026',
        texts: DeckTexts.defaults.withValue(
          'suggestionsBody',
          fill('A line of text with some words.\n', 400),
        ),
      ),
    ),
  );
  out.add(
    MatrixCase(
      'suggestions',
      'suggestions empty',
      SuggestionsSpec(
        periodLabel: 'Feb to Apr 2026',
        texts: DeckTexts.defaults.withValue('suggestionsBody', ''),
      ),
    ),
  );
  out.add(
    MatrixCase(
      'suggestions',
      'suggestions default',
      const SuggestionsSpec(
        periodLabel: 'Feb to Apr 2026',
        texts: DeckTexts.empty,
      ),
    ),
  );
  out.add(
    MatrixCase(
      'suggestions',
      'suggestions title 60',
      SuggestionsSpec(
        periodLabel: 'Nov 2026 to Jan 2027',
        texts: DeckTexts.defaults.withValue('suggestionsTitle', wide(60)),
      ),
    ),
  );

  return out;
}
