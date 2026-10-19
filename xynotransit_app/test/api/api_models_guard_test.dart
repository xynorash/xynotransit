// A server that answers with the wrong shape (a proxy page, a new version, a
// bug) must give one readable failure, never a raw TypeError.
import 'package:flutter_test/flutter_test.dart';
import 'package:xynotransit_app/data/api/api_models.dart';
import 'package:xynotransit_app/data/repository.dart';

Matcher readable() => throwsA(
  isA<RepositoryException>().having(
    (e) => e.message,
    'message',
    'The server sent an answer the app cannot read.',
  ),
);

void main() {
  final garbage = <Object?>[
    null,
    5,
    'html',
    <Object?>[],
    <String, Object?>{},
    {'id': 5},
    {'teams': 'x', 'persons': 3, 'assignments': <String, Object?>{}},
  ];

  test('every parser answers garbage with the readable failure', () {
    final parsers = <String, Object? Function(Object?)>{
      'user': parseUser,
      'team': parseTeam,
      'person': parsePerson,
      'assignment': parseAssignment,
      'period': parsePeriod,
      'report': parseReport,
      'deck': parseDeck,
      'deckTexts': parseDeckTextsState,
      'summary': parseSummary,
    };
    for (final e in parsers.entries) {
      for (final g in garbage) {
        // {} and some others are legal for the ones with defaults; what must
        // never happen is an error that is not a RepositoryException.
        try {
          e.value(g);
        } on RepositoryException {
          // fine
        }
      }
    }
    expect(() => parseTeam(5), readable());
    expect(() => parsePeriod({'id': 'x'}), readable());
    expect(
      () => parseReport({'id': 'x', 'values': 5, 'submitted_at': 5}),
      readable(),
    );
    expect(() => parseDeck({'id': 'x'}), readable());
    expect(
      () => parseAssignment({
        'id': 'a',
        'metrics': [5],
      }),
      readable(),
    );
  });

  test('lists survive rows of the wrong kind', () {
    expect(parseReports(null), isEmpty);
    expect(parseReports([5, 'x', null]), isEmpty);
    expect(
      () => parseReports([
        {
          'id': 5,
          'status': 3,
          'period_id': 'p',
          'assignment_id': 'a',
          'submitted_at': 'not a date',
        },
      ]),
      readable(),
    );
    expect(
      parseCatalog({
        'teams': <Object?>[],
        'persons': <Object?>[],
        'assignments': <Object?>[],
      }).teams,
      isEmpty,
    );
    expect(() => parseCatalog('nope'), readable());
  });

  test('a null deck is "no deck yet"', () {
    expect(parseDeckOrNull(null), isNull);
    expect(() => parseDeckOrNull('x'), readable());
  });
}
