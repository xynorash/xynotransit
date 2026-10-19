// One suite of scenarios, two backends. It always runs against the in-memory
// repository (the demo and the tests). Against the real API and the live
// stack it runs only when started as
//
//   flutter test test/contract \
//     --dart-define=CONTRACT_API=http://127.0.0.1:8080
//
// (Mailpit is expected at http://127.0.0.1:8025, or --dart-define=CONTRACT_MAIL=...).
// The API run signs in through real magic links, creates everything under a
// unique tag, and removes it at the end (with docker access it deletes the
// rows, otherwise it switches the people and seats off).
//
// A scenario that passes on one backend and fails on the other is a real
// difference between the demo and the product. Fix the wrong side.
@Timeout(Duration(minutes: 6))
library;

import 'package:flutter_test/flutter_test.dart';

import 'api_arena.dart';
import 'arena.dart';
import 'memory_arena.dart';
import 'scenarios_admin.dart' as admin;
import 'scenarios_concurrent.dart' as concurrent;
import 'scenarios_deck.dart' as deck;
import 'scenarios_reports.dart' as reports;
import 'scenarios_passwords.dart' as passwords;
import 'scenarios_signin.dart' as signin;

typedef Scenario = Future<void> Function(Arena a);

/// Every scenario, by name. `needsLastManager` ones only run where the guard
/// can be provoked without harming other managers.
final scenarios = <(String, Scenario, {bool lastManager})>[
  ('teams', admin.teams, lastManager: false),
  ('people', admin.people, lastManager: false),
  ('the last manager cannot be removed', admin.lastManager, lastManager: true),
  ('seats', admin.seats, lastManager: false),
  ('counts and targets', admin.definitions, lastManager: false),
  ('catalog as employee and manager', admin.catalogViews, lastManager: false),
  (
    'send, replace and edit a report',
    reports.reportsSendAndReplace,
    lastManager: false,
  ),
  ('periods and meeting dates', reports.periods, lastManager: false),
  ('who may do what', reports.roles, lastManager: false),
  ('a deactivated person', reports.deactivated, lastManager: false),
  ('a closed period', reports.closed, lastManager: false),
  ('live reports', reports.liveReports, lastManager: false),
  ('deck with 0, 1 and N reports', deck.deck, lastManager: false),
  ('deck words: inherit and freeze', deck.deckTexts, lastManager: false),
  ('summary equals the pure compute', deck.summary, lastManager: false),
  (
    'person without email, internal address, one-time sign-in link',
    signin.internalSignIn,
    lastManager: false,
  ),
  (
    'too many sign-in requests say when to retry',
    signin.signInLimit,
    lastManager: false,
  ),
  (
    'usernames and the life of a password',
    passwords.passwordLifecycle,
    lastManager: false,
  ),
  (
    'five wrong tries lock a username for a while',
    passwords.loginLimit,
    lastManager: false,
  ),
  ('things at the same time', concurrent.sameTime, lastManager: false),
];

void main() {
  group('MemoryRepository', () {
    for (final (name, run, lastManager: _) in scenarios) {
      test(name, () async {
        final a = await MemoryArena.create('m${name.hashCode.abs() % 99999}');
        await run(a);
      });
    }
  });

  final live = contractApi.isNotEmpty;
  group(
    'ApiRepository on the live stack',
    skip: live
        ? false
        : 'skipped: start with --dart-define=CONTRACT_API=http://127.0.0.1:8080 '
              'to run the same scenarios against the real API',
    () {
      late ApiRun run;
      setUpAll(() async => run = await ApiRun.start());
      tearDownAll(() async => run.cleanUp());
      var n = 0;
      for (final (name, scenario, :lastManager) in scenarios) {
        final index = n++;
        test(
          name,
          () async {
            await scenario(ApiArena(run, index));
          },
          skip: lastManager
              ? 'the API guard is proven by its own Rust tests: it cannot be '
                    'provoked here without switching off the real managers'
              : null,
        );
      }
    },
  );
}
