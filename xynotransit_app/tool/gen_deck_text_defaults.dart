// Writes docs/reference/deck_text_defaults.json from lib/domain/deck_text.dart.
// The API keeps an identical copy; both test suites compare against this file.
// Run: dart run tool/gen_deck_text_defaults.dart
import 'dart:convert';
import 'dart:io';

import 'package:xynotransit_app/domain/deck_text.dart';

void main() {
  final fields = [
    for (final f in deckTextFields)
      {
        'key': f.key,
        'default': f.defaultValue,
        'tokens': f.tokens,
        'max_length': f.maxLength,
        'can_be_empty': f.canBeEmpty,
      },
  ];
  File('docs/reference/deck_text_defaults.json').writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert({'fields': fields})}\n',
  );
  stdout.writeln('Wrote docs/reference/deck_text_defaults.json');
}
