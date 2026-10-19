import 'text_rules.dart';

/// Where in the deck a text field is used. Groups the editor.
enum DeckTextGroup {
  cover('Cover'),
  personSlides('Slides of each person'),
  dividers('Team dividers'),
  suggestions('Suggestions page');

  const DeckTextGroup(this.title);
  final String title;
}

/// One customizable piece of text: what it is called, where it shows, which
/// {placeholders} it may use and how long it may be.
class DeckTextField {
  const DeckTextField({
    required this.key,
    required this.group,
    required this.label,
    required this.help,
    required this.defaultValue,
    this.tokens = const [],
    this.maxLength = 120,
    this.multiline = false,
    this.canBeEmpty = false,
  });

  final String key;
  final DeckTextGroup group;
  final String label;
  final String help;
  final String defaultValue;

  /// Placeholder names (without braces) this field may contain.
  final List<String> tokens;
  final int maxLength;
  final bool multiline;

  /// Empty is a valid answer (for example "use the meeting date").
  final bool canBeEmpty;
}

const _person = ['org', 'title', 'period', 'name', 'role', 'team'];

/// Every text the manager can change. The order is the order of the editor.
/// The API keeps the same keys and defaults (docs/reference/deck_text_defaults.json).
const deckTextFields = <DeckTextField>[
  DeckTextField(
    key: 'title',
    group: DeckTextGroup.cover,
    label: 'Meeting title',
    help:
        'Big title on the cover. Also used in the footer and on team dividers.',
    defaultValue: 'Xynotransit Regional Logistics Meeting',
    tokens: ['period'],
    maxLength: 80,
  ),
  DeckTextField(
    key: 'subtitle',
    group: DeckTextGroup.cover,
    label: 'Subtitle',
    help: 'Line under the title.',
    defaultValue: 'KPI, volumes and priorities, {period}',
    tokens: ['period'],
  ),
  DeckTextField(
    key: 'dateText',
    group: DeckTextGroup.cover,
    label: 'Date line',
    help: 'Leave empty to show the meeting date of the period. Write your own words to replace it.',
    defaultValue: '',
    maxLength: 60,
    canBeEmpty: true,
  ),
  DeckTextField(
    key: 'orgName',
    group: DeckTextGroup.cover,
    label: 'Organisation name',
    help: 'Used in the small line above each person slide title.',
    defaultValue: 'Xynotransit',
    maxLength: 40,
  ),
  DeckTextField(
    key: 'coverPill',
    group: DeckTextGroup.cover,
    label: 'Team label on the cover',
    help: 'One label per team at the bottom of the cover.',
    defaultValue: '{team} · {count}',
    tokens: ['team', 'count'],
    maxLength: 60,
  ),
  DeckTextField(
    key: 'kpiEyebrow',
    group: DeckTextGroup.personSlides,
    label: 'KPI slide, small line',
    help: 'Small capital line above the title of the KPI and volumes slide.',
    defaultValue: 'KPI · {org} {team} team · {role}',
    tokens: _person,
  ),
  DeckTextField(
    key: 'kpiTitle',
    group: DeckTextGroup.personSlides,
    label: 'KPI slide, title',
    help: 'Title of the first slide of each person.',
    defaultValue: '{name}: KPI and volumes',
    tokens: _person,
  ),
  DeckTextField(
    key: 'kpiBadge',
    group: DeckTextGroup.personSlides,
    label: 'KPI slide, badge',
    help: 'Pill at the top right of the KPI slide.',
    defaultValue: 'KPI · {met} of {total} met',
    tokens: ['met', 'total'],
    maxLength: 40,
  ),
  DeckTextField(
    key: 'resultsEyebrow',
    group: DeckTextGroup.personSlides,
    label: 'Results slide, small line',
    help: 'Small capital line above the title of the results slide.',
    defaultValue: 'Results · {org} {team} team · {role}',
    tokens: _person,
  ),
  DeckTextField(
    key: 'resultsTitle',
    group: DeckTextGroup.personSlides,
    label: 'Results slide, title',
    help: 'Title of the second slide of each person.',
    defaultValue: '{name}: results and next priorities',
    tokens: _person,
  ),
  DeckTextField(
    key: 'highlightsTitle',
    group: DeckTextGroup.personSlides,
    label: 'First column title',
    help: 'Column for what went well.',
    defaultValue: 'Highlights',
    maxLength: 30,
  ),
  DeckTextField(
    key: 'lowlightsTitle',
    group: DeckTextGroup.personSlides,
    label: 'Second column title',
    help: 'Column for what went wrong.',
    defaultValue: 'Lowlights',
    maxLength: 30,
  ),
  DeckTextField(
    key: 'nextTitle',
    group: DeckTextGroup.personSlides,
    label: 'Third column title',
    help: 'Column for the next three months.',
    defaultValue: 'Next 3 months',
    maxLength: 30,
  ),
  DeckTextField(
    key: 'emptyNote',
    group: DeckTextGroup.personSlides,
    label: 'Text for an empty column',
    help: 'Shown when a person wrote nothing in a column.',
    defaultValue: 'Nothing to report',
    maxLength: 40,
  ),
  DeckTextField(
    key: 'footer',
    group: DeckTextGroup.personSlides,
    label: 'Footer',
    help: 'Small line at the bottom left of each person slide.',
    defaultValue: 'Source: {title} · {team} team · {period}',
    tokens: ['title', 'org', 'period', 'team'],
  ),
  DeckTextField(
    key: 'dividerEyebrow',
    group: DeckTextGroup.dividers,
    label: 'Divider, small line',
    help: 'Small capital line at the top of a team divider.',
    defaultValue: '{title} · Team {i} of {n}',
    tokens: ['title', 'period', 'i', 'n'],
  ),
  DeckTextField(
    key: 'dividerTitle',
    group: DeckTextGroup.dividers,
    label: 'Divider, title',
    help: 'Big title of a team divider.',
    defaultValue: '{team} team',
    tokens: ['team'],
    maxLength: 60,
  ),
  DeckTextField(
    key: 'dividerSubtitle',
    group: DeckTextGroup.dividers,
    label: 'Divider, line under the title',
    help: '{reports} becomes "report" or "reports".',
    defaultValue: '{k} {reports}, two slides each: KPI and results',
    tokens: ['k', 'reports', 'team'],
  ),
  DeckTextField(
    key: 'suggestionsTitle',
    group: DeckTextGroup.suggestions,
    label: 'Page title',
    help: 'The last page of the deck.',
    defaultValue: 'Suggestions',
    maxLength: 60,
  ),
  DeckTextField(
    key: 'suggestionsBody',
    group: DeckTextGroup.suggestions,
    label: 'Page text',
    help: 'Placeholder text until real suggestions are added.',
    defaultValue: 'Suggestions will be added here.',
    maxLength: 400,
    multiline: true,
    canBeEmpty: true,
  ),
];

DeckTextField? deckTextField(String key) {
  for (final f in deckTextFields) {
    if (f.key == key) return f;
  }
  return null;
}

/// All the words of a deck that a manager can change, with {placeholders}.
/// Frozen into each generated deck, so the preview and every export read the same words.
class DeckTexts {
  const DeckTexts._(this._values);

  final Map<String, String> _values;

  static final Map<String, String> _defaults = {
    for (final f in deckTextFields) f.key: f.defaultValue,
  };

  static const empty = DeckTexts._({});

  /// The built-in words.
  static final DeckTexts defaults = DeckTexts._(Map.unmodifiable(_defaults));

  /// Missing or unknown keys fall back to the defaults.
  factory DeckTexts.fromJson(Map<String, Object?>? j) {
    final m = {..._defaults};
    if (j != null) {
      for (final f in deckTextFields) {
        final v = j[f.key];
        if (v is String) m[f.key] = v;
      }
    }
    return DeckTexts._(Map.unmodifiable(m));
  }

  Map<String, String> toJson() => {
    for (final f in deckTextFields) f.key: this[f.key],
  };

  /// The raw template of [key].
  String operator [](String key) => _values[key] ?? _defaults[key] ?? '';

  DeckTexts withValue(String key, String value) =>
      DeckTexts._(Map.unmodifiable({..._defaults, ..._values, key: value}));

  /// Fills the {placeholders} of the template of [key] with [vars].
  /// A placeholder that is not in [vars] stays as written.
  String render(String key, Map<String, Object?> vars) => fill(this[key], vars);

  static final _token = RegExp(r'\{([a-zA-Z]+)\}');

  static String fill(String template, Map<String, Object?> vars) =>
      template.replaceAllMapped(_token, (m) {
        final v = vars[m[1]];
        return v == null ? m[0]! : '$v';
      });

  /// Placeholders used in [template].
  static Set<String> tokensIn(String template) => {
    for (final m in _token.allMatches(template)) m[1]!,
  };

  /// The value as it is stored: line breaks as plain line feeds (only where
  /// line breaks are allowed), then trimmed like the server trims.
  static String normalise(DeckTextField field, String value) {
    var v = value;
    if (field.multiline && v.contains('\r')) {
      v = v.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    }
    return trimText(v);
  }

  /// Plain-words problems with [value] for [field], or null when it is fine.
  /// Same order and words as the server.
  static String? check(DeckTextField field, String value) {
    final v = normalise(field, value);
    if (v.isEmpty && !field.canBeEmpty) {
      return '${field.label} cannot be empty.';
    }
    if (charCount(v) > field.maxLength) {
      return '${field.label} can be at most ${field.maxLength} characters.';
    }
    final hidden = v.runes.any(
      (c) =>
          isInvisibleRune(c) ||
          (isControlRune(c) && !(field.multiline && (c == 10 || c == 13))),
    );
    if (hidden) return 'Use plain text in ${field.label}.';
    for (final t in tokensIn(v)) {
      if (!field.tokens.contains(t)) {
        final allowed = field.tokens.isEmpty
            ? 'no placeholders'
            : field.tokens.map((x) => '{$x}').join(', ');
        return '{$t} cannot be used in ${field.label}. It allows $allowed.';
      }
    }
    return null;
  }

  @override
  bool operator ==(Object other) =>
      other is DeckTexts &&
      deckTextFields.every((f) => other[f.key] == this[f.key]);

  @override
  int get hashCode =>
      Object.hashAll([for (final f in deckTextFields) this[f.key]]);
}

/// The words in force for a period, and where they come from.
class DeckTextsState {
  const DeckTextsState({required this.texts, this.inheritedFrom});

  final DeckTexts texts;

  /// Null when this period has its own words. Otherwise the label of the period
  /// they were carried over from, or 'defaults' when nobody changed anything yet.
  final String? inheritedFrom;
}
