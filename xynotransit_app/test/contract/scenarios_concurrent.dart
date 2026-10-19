// Things that happen at the same time: a retry that overlaps the first try,
// two managers adding the same name, a double click.
import 'package:flutter_test/flutter_test.dart';
import 'package:xynotransit_app/data/repository.dart';
import 'package:xynotransit_app/domain/enums.dart';

import 'arena.dart';

/// Runs [calls] together. Returns the messages of the refusals and the values
/// of the successes.
Future<({List<T> ok, List<String> refused})> together<T>(
  List<Future<T> Function()> calls,
) async {
  final ok = <T>[];
  final refused = <String>[];
  await Future.wait([
    for (final c in calls)
      () async {
        try {
          ok.add(await c());
        } on NetworkException catch (e) {
          fail('network failure in a parallel call: $e');
        } on RepositoryException catch (e) {
          refused.add(e.message);
        }
      }(),
  ]);
  return (ok: ok, refused: refused);
}

Future<void> sameTime(Arena a) async {
  final boss = a.boss;
  final team = await a.makeTeam('Parallel');
  final s = await a.makeSeat('dora', team);
  final seat = s.assignment;
  final p = await boss.ensurePeriod(a.start(0));
  final emp = await a.signInAs(s.email);

  // The same report sent six times at once: one report, all answers alike.
  final same = fullReport(seat, p, n: 7);
  final r = await together([
    for (var i = 0; i < 6; i++) () => emp.sendReport(same),
  ]);
  expect(r.refused, isEmpty, reason: 'a repeat is not an error');
  expect(r.ok.map((x) => x.id).toSet(), hasLength(1));
  expect(await boss.watchReports(p.id).first, hasLength(1));

  // Different reports at once: the stored one is exactly one of them, never a
  // mix of two (numbers of one, notes of another).
  final many = [for (var n = 10; n < 16; n++) n];
  final w = await together([
    for (final n in many)
      () => emp.sendReport(
        fullReport(seat, p, n: n).copyWith(
          notes: {
            NoteKind.well: ['note $n'],
            NoteKind.wrong: <String>[],
            NoteKind.next: <String>[],
          },
        ),
      ),
  ]);
  expect(w.refused, isEmpty);
  final stored = (await emp.getReport(p.id, seat.id))!;
  final first = stored.values[seat.metrics.first.id]!.first!;
  expect(many, contains(first));
  for (final m in seat.metrics) {
    expect(stored.values[m.id], [first, first + 1, first + 2]);
  }
  expect(stored.notesOf(NoteKind.well), ['note $first']);
  expect(stored.id, r.ok.first.id);

  // Two managers add the same name at once: one wins, the others are told.
  final name = 'CT${a.tag} Twin';
  final t = await together([
    for (var i = 0; i < 5; i++) () => boss.saveTeam(name: name),
  ]);
  expect(t.ok, hasLength(1));
  expect(t.refused, everyElement('That team name is already used.'));
  final mail = a.email('twin');
  final pe = await together([
    for (var i = 0; i < 5; i++)
      () => boss.savePerson(
        fullName: 'CT${a.tag} Twin $i',
        email: mail,
        role: AppRole.contributor,
      ),
  ]);
  expect(pe.ok, hasLength(1));
  expect(pe.refused, everyElement('That email is already used.'));
  final twin = pe.ok.single;
  final se = await together([
    for (var i = 0; i < 5; i++)
      () => boss.saveAssignment(
        personId: twin.id,
        teamId: team.id,
        roleTitle: 'Same role',
      ),
  ]);
  expect(se.ok, hasLength(1));
  expect(
    se.refused,
    everyElement('That person already has this role in this team.'),
  );
}
