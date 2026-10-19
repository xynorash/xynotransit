// Report scenarios: sending, replacing, validation words, who may do what.
import 'package:flutter_test/flutter_test.dart';
import 'package:xynotransit_app/data/api/api_client.dart';
import 'package:xynotransit_app/domain/enums.dart';
import 'package:xynotransit_app/domain/period.dart';
import 'package:xynotransit_app/domain/report.dart';

import 'arena.dart';
import 'scenarios_admin.dart' show onlyController;

String _month(Period p, int i) => p.months[i].long;

Future<void> reportsSendAndReplace(Arena a) async {
  final boss = a.boss;
  final team = await a.makeTeam('Reports');
  final s = await a.makeSeat('rita', team);
  final seat = s.assignment;
  final p = await boss.ensurePeriod(a.start(0));
  final emp = await a.signInAs(s.email);

  expect(await emp.getReport(p.id, seat.id), isNull, reason: 'nothing yet');

  Report good() => fullReport(seat, p);
  Future<void> bad(Report r, String message, [String? why]) =>
      expectRefused(emp.sendReport(r), message, why: why);

  // The reporter block, in field order.
  await bad(
    Report(periodId: p.id, assignmentId: seat.id),
    'Enter your name.',
    'an empty report',
  );
  await bad(
    good().copyWith(
      reporter: const Reporter(country: 'c', role: 'r'),
    ),
    'Enter your name.',
  );
  await bad(
    good().copyWith(
      reporter: const Reporter(name: 'n', role: 'r'),
    ),
    'Enter your country.',
  );
  await bad(
    good().copyWith(
      reporter: const Reporter(name: 'n', country: 'c'),
    ),
    'Enter your role.',
  );
  await bad(
    good().copyWith(
      reporter: Reporter(name: 'n' * 81, country: 'c', role: 'r'),
    ),
    'Your name can be at most 80 characters.',
  );
  await bad(
    good().copyWith(
      reporter: const Reporter(name: 'n', country: 'c​d', role: 'r'),
    ),
    'Your country must be plain text on one line.',
  );
  await bad(
    good().copyWith(
      reporter: const Reporter(name: 'n', country: 'c', role: 'a\nb'),
    ),
    'Your role must be plain text on one line.',
  );
  // Counts: the first gap of each count, in month order.
  final first = seat.metrics[0].id;
  final second = seat.metrics[1].id;
  await bad(
    good().copyWith(
      values: {
        first: [1, 2, 3],
      },
    ),
    'Enter a number for "Count 2" in ${_month(p, 0)}.',
  );
  await bad(
    good().copyWith(
      values: {
        first: [1, null, 3],
        second: [1, 2, 3],
      },
    ),
    'Enter a number for "Count 1" in ${_month(p, 1)}.',
  );
  await bad(
    good().copyWith(
      values: {
        first: [1, 2, 3],
        second: [1, 2, null],
      },
    ),
    'Enter a number for "Count 2" in ${_month(p, 2)}.',
  );
  await bad(
    good().copyWith(
      values: {
        first: [1, 2, 3],
        second: [-1, 2, 3],
      },
    ),
    'Enter a number for "Count 2" in ${_month(p, 0)}.',
    'a negative number',
  );
  await bad(
    good().copyWith(
      values: {
        first: [1, 2, 3],
        second: [1, 1000000001, 3],
      },
    ),
    'Enter a number for "Count 2" in ${_month(p, 1)}.',
    'a number over the limit',
  );
  await bad(
    good().copyWith(
      values: {
        first: [1, 2, 3],
        second: [1, 2, 3],
        a.unknownId: [1, 2, 3],
      },
    ),
    'One of the numbers does not belong to this report.',
  );
  await bad(
    good().copyWith(
      kpis: {
        for (final k in seat.kpis) k.id: const KpiResult(KpiStatus.met),
        a.unknownId: const KpiResult(KpiStatus.met),
      },
    ),
    'One of the targets does not belong to this report.',
  );

  // Targets and comments.
  await bad(
    good().copyWith(kpis: {seat.kpis[0].id: const KpiResult(KpiStatus.met)}),
    'Answer all targets in step 3 (1 left).',
  );
  await bad(
    good().copyWith(kpis: {}),
    'Answer all targets in step 3 (2 left).',
  );
  await bad(
    good().copyWith(
      kpis: {
        seat.kpis[0].id: KpiResult(KpiStatus.met, comment: 'c' * 201),
        seat.kpis[1].id: const KpiResult(KpiStatus.met),
      },
    ),
    'A comment can be at most 200 characters.',
  );
  await bad(
    good().copyWith(
      kpis: {
        seat.kpis[0].id: const KpiResult(KpiStatus.met, comment: 'a\u0000b'),
        seat.kpis[1].id: const KpiResult(KpiStatus.met),
      },
    ),
    'Text cannot contain control characters.',
  );

  // Notes.
  Report withNotes(NoteKind k, List<String> l) => good().copyWith(
    notes: {
      for (final x in NoteKind.values) x: x == k ? l : <String>['ok'],
    },
  );
  await bad(
    withNotes(NoteKind.well, ['a', 'b', 'c', 'd']),
    'Write at most 3 notes per box.',
  );
  await bad(withNotes(NoteKind.wrong, ['a', '  ']), 'A note cannot be empty.');
  await bad(
    withNotes(NoteKind.next, ['n' * 71]),
    'A note can be at most 70 characters.',
  );
  await bad(
    withNotes(NoteKind.next, ['a\u0000']),
    'Text cannot contain control characters.',
  );
  // Several faults: the first one in the server order wins.
  await bad(
    good().copyWith(
      reporter: const Reporter(),
      values: {
        first: [1],
      },
      kpis: {},
    ),
    'Enter your name.',
    'reporter before counts',
  );
  await bad(
    good().copyWith(
      values: {
        first: [1, 2, 3],
      },
      kpis: {},
    ),
    'Enter a number for "Count 2" in ${_month(p, 0)}.',
    'counts before targets',
  );
  await bad(
    good().copyWith(
      kpis: {},
      notes: {
        NoteKind.well: ['a', 'b', 'c', 'd'],
        NoteKind.wrong: [],
        NoteKind.next: [],
      },
    ),
    'Answer all targets in step 3 (2 left).',
    'targets before notes',
  );
  // A report the app cannot build is also refused by what it names.
  await bad(
    good().copyWith(
      values: {
        first: [1, 2, 3],
        a.unknownId: [1, 2, 3],
      },
    ),
    'One of the numbers does not belong to this report.',
    'foreign id before missing numbers',
  );
  expect(
    await emp.getReport(p.id, seat.id),
    isNull,
    reason: 'refused reports leave nothing behind',
  );

  // A good one. Text is trimmed, comments cleaned, numbers in three slots.
  final sent = await emp.sendReport(
    good().copyWith(
      reporter: const Reporter(
        name: '  Rova R.  ',
        country: ' Madagascar ',
        role: ' Planner ',
      ),
      kpis: {
        seat.kpis[0].id: const KpiResult(KpiStatus.partly, comment: '  late  '),
        seat.kpis[1].id: const KpiResult(KpiStatus.missed, comment: '   '),
      },
      notes: {
        NoteKind.well: ['  one  ', 'two'],
        NoteKind.wrong: [],
        NoteKind.next: ['x' * 70],
      },
    ),
  );
  expect(sent.id, isNotNull);
  expect(sent.isSubmitted, isTrue);
  expect(sent.periodId, p.id);
  expect(sent.assignmentId, seat.id);
  expect(
    sent.reporter,
    const Reporter(name: 'Rova R.', country: 'Madagascar', role: 'Planner'),
  );
  expect(sent.values[first], [5, 6, 7]);
  expect(sent.values[second], [5, 6, 7]);
  expect(sent.kpis[seat.kpis[0].id]!.status, KpiStatus.partly);
  expect(sent.kpis[seat.kpis[0].id]!.comment, 'late');
  expect(sent.kpis[seat.kpis[1].id]!.status, KpiStatus.missed);
  expect(sent.kpis[seat.kpis[1].id]!.comment, isNull);
  expect(sent.notesOf(NoteKind.well), ['one', 'two']);
  expect(sent.notesOf(NoteKind.wrong), isEmpty);
  expect(sent.notesOf(NoteKind.next), ['x' * 70]);
  expect(
    DateTime.now().difference(sent.submittedAt!).abs(),
    lessThan(const Duration(minutes: 2)),
  );

  // What is stored is what was returned.
  final read = (await emp.getReport(p.id, seat.id))!;
  expect(read.id, sent.id);
  expect(read.values, sent.values);
  expect(read.reporter, sent.reporter);
  expect(read.notesOf(NoteKind.well), ['one', 'two']);
  expect(read.kpis[seat.kpis[0].id]!.comment, 'late');

  // Sending again replaces it: same report, new content, no duplicate.
  final again = await emp.sendReport(
    good().copyWith(
      values: {
        first: [9, 9, 9],
        second: [0, 0, 0],
      },
      notes: {for (final k in NoteKind.values) k: <String>[]},
    ),
  );
  expect(again.id, sent.id, reason: 'one report per seat and period');
  expect(again.values[first], [9, 9, 9]);
  expect(again.values[second], [0, 0, 0], reason: 'zero is a number');
  expect(again.noteCount, 0);
  expect(again.submittedAt!.isBefore(sent.submittedAt!), isFalse);
  final all = await boss.watchReports(p.id).first;
  expect(all.where((r) => r.assignmentId == seat.id), hasLength(1));

  // The manager may fix it for the employee.
  final fixed = await boss.sendReport(
    again.copyWith(
      reporter: const Reporter(
        name: 'Fixed',
        country: 'Madagascar',
        role: 'Planner',
      ),
    ),
  );
  expect(fixed.id, sent.id);
  expect(fixed.reporter!.name, 'Fixed');
  expect((await emp.getReport(p.id, seat.id))!.reporter!.name, 'Fixed');

  // Edges that are fine: limits exactly, emoji counted as one character each,
  // one billion and sums that do not fit 32 bits.
  final edge = await emp.sendReport(
    good().copyWith(
      reporter: Reporter(name: 'n' * 80, country: 'c' * 80, role: 'r' * 80),
      values: {
        first: [1000000000, 1000000000, 1000000000],
        second: [0, 0, 1000000000],
      },
      kpis: {
        seat.kpis[0].id: KpiResult(KpiStatus.met, comment: 'c' * 200),
        seat.kpis[1].id: KpiResult(KpiStatus.met, comment: ' ${'c' * 200} '),
      },
      notes: {
        NoteKind.well: ['😀' * 70, 'b', 'c'],
        NoteKind.wrong: [],
        NoteKind.next: [],
      },
    ),
  );
  expect(edge.values[first], [1000000000, 1000000000, 1000000000]);
  expect(edge.totalOf(first), 3000000000);
  expect(edge.notesOf(NoteKind.well).first.runes.length, 70);
  expect(edge.kpis[seat.kpis[1].id]!.comment, 'c' * 200);

  // A paste with a non breaking space is not refused: it becomes a plain space.
  final pasted = await emp.sendReport(
    good().copyWith(
      reporter: const Reporter(
        name: 'Jean\u00A0Paul',
        country: 'a\u3000b',
        role: 'r',
      ),
    ),
  );
  expect(
    pasted.reporter,
    const Reporter(name: 'Jean Paul', country: 'a b', role: 'r'),
  );

  // Someone else's seat.
  final other = await a.makeSeat('sven', team);
  await expectRefused(
    emp.sendReport(fullReport(other.assignment, p)),
    'You can only send your own report.',
  );
  await expectRefused(
    emp.getReport(p.id, other.assignment.id),
    'You can only see your own report.',
  );
  await expectRefused(
    emp.getReport(p.id, a.unknownId),
    'You can only see your own report.',
    why: 'a seat nobody has, asked by an employee',
  );
  expect(await boss.getReport(p.id, a.unknownId), isNull);
  expect(await boss.getReport(p.id, other.assignment.id), isNull);
  // Unknown things.
  await expectRefused(
    emp.sendReport(
      Report(
        periodId: a.unknownId,
        assignmentId: seat.id,
        reporter: good().reporter,
      ),
    ),
    'That period does not exist.',
  );
  await expectRefused(
    emp.sendReport(
      Report(
        periodId: p.id,
        assignmentId: a.unknownId,
        reporter: good().reporter,
      ),
    ),
    'That seat does not exist.',
  );

  // A seat that is switched off cannot be reported on, but can be read.
  await boss.saveAssignment(
    id: seat.id,
    personId: s.person.id,
    teamId: team.id,
    roleTitle: seat.roleTitle,
    active: false,
  );
  await expectRefused(
    emp.sendReport(good()),
    'That seat does not exist.',
    why: 'inactive seat',
  );
  expect(await emp.getReport(p.id, seat.id), isNotNull);
}

Future<void> periods(Arena a) async {
  final boss = a.boss;
  final team = await a.makeTeam('Periods');
  final s = await a.makeSeat('pam', team);
  final emp = await a.signInAs(s.email);

  final start = a.start(0);
  final p = await boss.ensurePeriod(DateTime(start.year, start.month, 17, 13));
  expect(
    p.startMonth,
    DateTime(start.year, start.month),
    reason: 'always the first of the month',
  );
  expect(p.status, PeriodStatus.open);
  expect(p.meetingDate, isNull);
  expect(p.months, hasLength(3));
  final same = await emp.ensurePeriod(start);
  expect(same.id, p.id, reason: 'an employee opens the same period');
  expect(p.label, Period.labelFor(start));

  // Meeting date: date only, no zone shifts, can be cleared.
  await boss.setMeetingDate(
    p.id,
    DateTime(start.year, start.month, 28, 23, 59),
  );
  var again = await boss.ensurePeriod(start);
  expect(again.meetingDate, DateTime(start.year, start.month, 28));
  await boss.setMeetingDate(p.id, DateTime(start.year, start.month, 1));
  again = await boss.ensurePeriod(start);
  expect(again.meetingDate, DateTime(start.year, start.month, 1));
  await boss.setMeetingDate(p.id, null);
  expect((await boss.ensurePeriod(start)).meetingDate, isNull);

  // Words of the refusals.
  const range = 'Enter a date between 2000 and 2100.';
  await expectRefused(boss.ensurePeriod(DateTime(1999, 12)), range);
  await expectRefused(boss.ensurePeriod(DateTime(2101, 1)), range);
  await expectRefused(boss.setMeetingDate(p.id, DateTime(1999, 12, 31)), range);
  await expectRefused(boss.setMeetingDate(p.id, DateTime(2101, 1, 1)), range);
  await expectRefused(
    boss.setMeetingDate(a.unknownId, DateTime(start.year, start.month, 2)),
    'That period does not exist.',
  );
  await expectRefused(
    emp.setMeetingDate(p.id, DateTime(start.year, start.month, 2)),
    onlyController,
  );
  // The edges of the range are fine.
  expect(
    (await boss.ensurePeriod(DateTime(2000, 1))).startMonth,
    DateTime(2000),
  );
  expect(
    (await boss.ensurePeriod(DateTime(2100, 12))).startMonth,
    DateTime(2100, 12),
  );
  // Year boundary.
  final y = a.start(0).year + 1;
  final nov = await boss.ensurePeriod(DateTime(y, 11));
  expect(nov.label, 'Nov $y to Jan ${y + 1}');
  expect(nov.months.map((m) => (m.year, m.month)), [
    (y, 11),
    (y, 12),
    (y + 1, 1),
  ]);
  expect(nov.months.map((m) => m.short), ['Nov', 'Dec', 'Jan']);
  expect(s.person.id, isNotEmpty);
}

Future<void> roles(Arena a) async {
  final boss = a.boss;
  final team = await a.makeTeam('Roles');
  final s = await a.makeSeat('rex', team);
  final p = await boss.ensurePeriod(a.start(0));
  final emp = await a.signInAs(s.email);
  final cat = await emp.loadCatalog();
  final seat = cat.assignmentById(s.assignment.id)!;

  // Controller only, every one of them.
  Future<void> only(Future<Object?> f, String op) =>
      expectRefused(f, onlyController, why: op);
  await only(emp.setMeetingDate(p.id, DateTime(2080, 2, 2)), 'setMeetingDate');
  await only(emp.generateDeck(p, cat), 'generateDeck');
  await only(emp.saveTeam(name: 'CT${a.tag} Nope'), 'saveTeam');
  await only(emp.saveTeam(id: team.id, name: 'CT${a.tag} Nope'), 'rename team');
  await only(emp.deleteTeam(team.id), 'deleteTeam');
  await only(
    emp.savePerson(
      fullName: 'X',
      email: a.email('x'),
      role: AppRole.contributor,
    ),
    'savePerson',
  );
  await only(
    emp.savePerson(
      id: s.person.id,
      fullName: s.person.fullName,
      email: s.email,
      role: AppRole.controller,
    ),
    'promote yourself',
  );
  await only(
    emp.saveAssignment(personId: s.person.id, teamId: team.id, roleTitle: 'X'),
    'saveAssignment',
  );
  await only(
    emp.saveDefinitions(seat.id, metrics: const [], kpis: const []),
    'saveDefinitions',
  );
  await only(emp.loadSummary(p.id), 'loadSummary');
  await only(
    emp.saveDeckTexts(p.id, (await emp.loadDeckTexts(p.id)).texts),
    'saveDeckTexts',
  );
  expect(
    await streamRefusal(emp.watchReports(p.id)),
    onlyController,
    reason: 'watchReports',
  );
  expect(
    await streamRefusal(emp.watchDeck(p.id)),
    onlyController,
    reason: 'watchDeck',
  );
  // The check comes before the arguments are looked at.
  await only(
    emp.generateDeck(Period(id: a.unknownId, startMonth: a.start(0)), cat),
    'unknown period',
  );
  await only(emp.loadSummary(a.unknownId, trend: 99), 'bad trend');

  // Open to every signed in person.
  expect(cat.assignments, isNotEmpty);
  await emp.watchCatalog().first;
  expect((await emp.ensurePeriod(a.start(0))).id, p.id);
  expect((await emp.loadDeckTexts(p.id)).texts, isNotNull);
  await emp.sendReport(fullReport(seat, p));
  expect(await emp.getReport(p.id, seat.id), isNotNull);

  // The manager can do all of it.
  await boss.loadSummary(p.id);
  expect(await boss.watchReports(p.id).first, hasLength(1));
  expect(await boss.watchDeck(p.id).first, isNull);
  await boss.generateDeck(p, await boss.loadCatalog());

  // Promoting an employee gives them the powers at once; demoting takes them.
  final promoted = await boss.savePerson(
    id: s.person.id,
    fullName: s.person.fullName,
    email: s.email,
    role: AppRole.controller,
  );
  expect(promoted.appRole, AppRole.controller);
  await emp.loadSummary(p.id);
  await boss.savePerson(
    id: s.person.id,
    fullName: s.person.fullName,
    email: s.email,
    role: AppRole.contributor,
  );
  await only(emp.loadSummary(p.id), 'after the demotion');
}

Future<void> deactivated(Arena a) async {
  final boss = a.boss;
  final team = await a.makeTeam('Gone');
  final s = await a.makeSeat('dee', team);
  final keep = await a.makeSeat('ken', team);
  final p = await boss.ensurePeriod(a.start(0));
  final emp = await a.signInAs(s.email);
  await emp.sendReport(fullReport(s.assignment, p, n: 7));
  await (await a.signInAs(keep.email))
      .sendReport(fullReport(keep.assignment, p));

  // Switch the person off: their session ends at once, they cannot come back.
  await boss.savePerson(
    id: s.person.id,
    fullName: s.person.fullName,
    email: s.email,
    role: AppRole.contributor,
    active: false,
  );
  Future<void> signedOut(Future<Object?> f, String op) async {
    try {
      await f;
      fail('$op: expected a signed out refusal');
    } on UnauthorizedException catch (e) {
      expect(e.message, 'Please sign in.', reason: op);
    }
  }

  await signedOut(emp.loadCatalog(), 'loadCatalog');
  await signedOut(emp.getReport(p.id, s.assignment.id), 'getReport');
  await signedOut(emp.sendReport(fullReport(s.assignment, p)), 'sendReport');
  await signedOut(emp.ensurePeriod(a.start(0)), 'ensurePeriod');
  await signedOut(emp.loadDeckTexts(p.id), 'loadDeckTexts');
  await expectLater(
    a.signInAs(s.email, fresh: true),
    throwsA(isA<SignInRefused>()),
  );

  // Their seat and report are still there; they are no longer expected, so the
  // default views leave them out and the manager's full view keeps them.
  final cat = await boss.loadCatalog(includeInactive: true);
  expect(cat.assignmentById(s.assignment.id)!.active, isTrue);
  expect(cat.personById(s.person.id)!.active, isFalse);
  expect(cat.isExpected(cat.assignmentById(s.assignment.id)!), isFalse);
  expect(cat.isExpected(cat.assignmentById(keep.assignment.id)!), isTrue);
  final visible = await boss.loadCatalog();
  expect(visible.personById(s.person.id), isNull);
  expect(visible.assignmentById(s.assignment.id), isNull);
  expect(visible.assignmentById(keep.assignment.id), isNotNull);
  for (final seat in visible.assignments) {
    expect(
      visible.personById(seat.personId),
      isNotNull,
      reason: 'seat ${seat.code} must come with its person',
    );
  }
  expect(
    (await boss.getReport(
      p.id,
      s.assignment.id,
    ))!.valueOf(s.assignment.metrics.first.id, 0),
    7,
    reason: 'the old report stays',
  );
  // The deck holds active seats of active people only.
  final deck = await boss.generateDeck(p, cat);
  expect(deck.includedCount, 1);
  expect(deck.expectedCount, cat.expectedCount);
  // The summary still counts what was sent, and still lists the person.
  final sum = await boss.loadSummary(p.id);
  expect(sum.submitted, 2);
  expect(sum.expected, cat.expectedCount);
  expect(sum.people.map((x) => x.assignmentId), contains(s.assignment.id));
  expect(
    sum.people.firstWhere((x) => x.assignmentId == s.assignment.id).submitted,
    isTrue,
  );

  // Back on.
  await boss.savePerson(
    id: s.person.id,
    fullName: s.person.fullName,
    email: s.email,
    role: AppRole.contributor,
  );
  final back = await a.signInAs(s.email, fresh: true);
  expect(await back.getReport(p.id, s.assignment.id), isNotNull);
}

Future<void> closed(Arena a) async {
  final boss = a.boss;
  final team = await a.makeTeam('Closed');
  final s = await a.makeSeat('cleo', team);
  final p = await boss.ensurePeriod(a.start(0));
  final emp = await a.signInAs(s.email);
  final r = await emp.sendReport(fullReport(s.assignment, p));
  if (!await a.closePeriod(p)) {
    markTestSkipped('this backend cannot close a period here (no SQL access)');
    return;
  }
  expect((await boss.ensurePeriod(a.start(0))).status, PeriodStatus.closed);
  await expectRefused(
    emp.sendReport(fullReport(s.assignment, p, n: 9)),
    'This period is closed.',
  );
  // Reading stays open to the owner.
  expect((await emp.getReport(p.id, s.assignment.id))!.id, r.id);
  // The manager still can send and generate.
  final fixed = await boss.sendReport(fullReport(s.assignment, p, n: 9));
  expect(fixed.id, r.id);
  expect(fixed.values.values.first, [9, 10, 11]);
  final deck = await boss.generateDeck(p, await boss.loadCatalog());
  expect(deck.includedCount, 1);
  // The words can still be changed.
  await boss.saveDeckTexts(p.id, (await boss.loadDeckTexts(p.id)).texts);
}

/// Waits until [read] satisfies [ok], for streams that follow writes.
Future<T> eventually<T>(
  Future<T> Function() read,
  bool Function(T) ok,
  String what,
) async {
  final end = DateTime.now().add(const Duration(seconds: 6));
  while (true) {
    final v = await read();
    if (ok(v)) return v;
    if (DateTime.now().isAfter(end)) fail('timed out waiting for $what');
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

Future<void> liveReports(Arena a) async {
  final boss = a.boss;
  final team = await a.makeTeam('Live');
  final s = await a.makeSeat('lia', team);
  final p = await boss.ensurePeriod(a.start(0));
  final seen = <List<Report>>[];
  final sub = boss.watchReports(p.id).listen(seen.add);
  await eventually(() async => seen.length, (n) => n >= 1, 'first list');
  expect(seen.first, isEmpty);
  final emp = await a.signInAs(s.email);
  await emp.sendReport(fullReport(s.assignment, p));
  await eventually(() async => seen.length, (n) => n >= 2, 'the new report');
  expect(seen.last.single.assignmentId, s.assignment.id);
  await sub.cancel();
  // Unknown period.
  expect(
    await streamRefusal(boss.watchReports(a.unknownId)),
    'That period does not exist.',
  );
  expect(
    await streamRefusal(boss.watchDeck(a.unknownId)),
    'That period does not exist.',
  );
}
