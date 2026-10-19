// The ground the contract scenarios play on. One Arena is one backend (the
// in-memory repository, or the real API on the live stack) as seen by a
// manager and by the employees the manager creates. The scenarios only talk
// to this interface, so a scenario that passes on one backend and fails on the
// other has found a real difference.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:xynotransit_app/data/repository.dart';
import 'package:xynotransit_app/domain/admin.dart';
import 'package:xynotransit_app/domain/catalog.dart';
import 'package:xynotransit_app/domain/enums.dart';
import 'package:xynotransit_app/domain/period.dart';
import 'package:xynotransit_app/domain/report.dart';

/// Thrown by [Arena.signInAs] when the backend would not let that person in
/// (no such active person, so no link is ever sent).
class SignInRefused implements Exception {
  const SignInRefused(this.email);
  final String email;
  @override
  String toString() => 'sign in refused for $email';
}

abstract class Arena {
  /// Short unique text for names and emails of this scenario.
  String get tag;

  /// The signed-in manager.
  Repository get boss;

  /// The manager's person row.
  Person get bossPerson;

  /// A repository acting as the active person with this email.
  /// Throws [SignInRefused] when that is not possible. A session is reused
  /// unless [fresh] asks for a new sign in (a person can only ask for 5 links
  /// an hour).
  Future<Repository> signInAs(String email, {bool fresh = false});

  /// A repository acting as the person a one-time sign-in link (made by a
  /// manager) belongs to. Throws a [RepositoryException] when the link is
  /// refused (used already, expired, person switched off).
  Future<Repository> signInWithLink(String url);

  /// The first month of the n-th period of this scenario (n = 0, 1, 2, ...).
  /// Consecutive n are consecutive months, far from real data.
  DateTime start(int n);

  /// An id no backend has.
  String get unknownId;

  /// Closes a period the way an operator does. Returns false when this
  /// backend cannot do it here (no SQL access), and the scenario then skips.
  Future<bool> closePeriod(Period p);

  /// Asks for sign-in links for [email] until the backend says "too many".
  /// Returns what the app would show and the `Retry-After` it got, or null when
  /// this backend has no such limit (the in-memory demo).
  Future<({String message, int? retryAfter})?> provokeSignInLimit(String email);

  /// Whether the "last manager" guard can be provoked without harming
  /// other managers of a shared stack.
  bool get canTestLastManager;

  Future<void> dispose();
}

// ---------------------------------------------------------------------------
// Small helpers for scenarios.
// ---------------------------------------------------------------------------

/// The message of the refusal, failing the test when [f] succeeds or fails in
/// another way (a [NetworkException] is a failure of the test, not a refusal).
Future<String> refusal(Future<Object?> f, {String? why}) async {
  try {
    await f;
  } on NetworkException catch (e) {
    fail('${why ?? 'call'}: expected a refusal, got a network failure: $e');
  } on RepositoryException catch (e) {
    return e.message;
  }
  fail('${why ?? 'call'}: expected a refusal, but it succeeded');
}

/// Fails unless [f] is refused with exactly [message].
Future<void> expectRefused(
  Future<Object?> f,
  String message, {
  String? why,
}) async {
  expect(await refusal(f, why: why), message, reason: why);
}

/// The refusal a stream ends with.
Future<String> streamRefusal(Stream<Object?> s, {String? why}) async {
  try {
    await s.first.timeout(const Duration(seconds: 5));
  } on RepositoryException catch (e) {
    return e.message;
  } on StateError {
    fail('${why ?? 'stream'}: ended without a value or an error');
  } on TimeoutException {
    fail('${why ?? 'stream'}: nothing came in 5 seconds');
  }
  fail('${why ?? 'stream'}: expected a refusal, got a value');
}

/// Makes a person and a seat with counts and targets, as the manager.
class Seat {
  Seat(this.person, this.assignment);
  final Person person;
  Assignment assignment;
  String get email => person.email!;
}

extension ArenaMake on Arena {
  String email(String who) => 'ct$tag-$who@contract.example';

  Future<Team> makeTeam(String name) => boss.saveTeam(name: 'CT$tag $name');

  Future<Person> makePerson(String who, {AppRole role = AppRole.contributor}) =>
      boss.savePerson(
        fullName: 'CT$tag ${who[0].toUpperCase()}${who.substring(1)}',
        email: email(who),
        role: role,
      );

  /// A person with one seat in [team], [counts] counts and [targets] targets.
  Future<Seat> makeSeat(
    String who,
    Team team, {
    int counts = 2,
    int targets = 2,
    String role = 'Planner',
    List<String>? labels,
  }) async {
    final person = await makePerson(who);
    var seat = await boss.saveAssignment(
      personId: person.id,
      teamId: team.id,
      roleTitle: role,
    );
    seat = await boss.saveDefinitions(
      seat.id,
      metrics: [
        for (var i = 0; i < (labels?.length ?? counts); i++)
          MetricInput(label: labels?[i] ?? 'Count ${i + 1}'),
      ],
      kpis: [
        for (var i = 0; i < targets; i++) KpiInput(text: 'Target ${i + 1}'),
      ],
    );
    return Seat(person, seat);
  }
}

/// A complete, valid report for [seat] in [period]: numbers [n], [n]+[step],
/// [n]+2*[step] for every count, every
/// target met, one note per box, a reporter.
Report fullReport(
  Assignment seat,
  Period period, {
  int n = 5,
  int step = 1,
  Reporter? reporter,
  KpiStatus status = KpiStatus.met,
}) => Report(
  periodId: period.id,
  assignmentId: seat.id,
  values: {
    for (final m in seat.metrics) m.id: [n, n + step, n + 2 * step],
  },
  kpis: {for (final k in seat.kpis) k.id: KpiResult(status)},
  notes: {
    NoteKind.well: ['Went well'],
    NoteKind.wrong: ['Went wrong'],
    NoteKind.next: ['Do more'],
  },
  reporter:
      reporter ??
      const Reporter(name: 'Rova R.', country: 'Madagascar', role: 'Planner'),
);

/// The first problem the shared validation finds, as the server words it.
String? firstProblem(Report r, Assignment a, Period p) {
  final problems = r.validate(a, p);
  return problems.isEmpty ? null : problems.first;
}
