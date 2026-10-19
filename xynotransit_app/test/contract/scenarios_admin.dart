// Catalog scenarios: teams, people, seats, counts and targets.
import 'package:flutter_test/flutter_test.dart';
import 'package:xynotransit_app/domain/admin.dart';
import 'package:xynotransit_app/domain/catalog.dart';
import 'package:xynotransit_app/domain/enums.dart';
import 'package:xynotransit_app/domain/text_rules.dart';

import 'arena.dart';

const onlyController = 'Only the controller can do this.';

/// A name of exactly [n] characters that starts with [prefix].
String padded(String prefix, int n, [String fill = 'x']) =>
    prefix + fill * (n - charCount(prefix));

Future<void> teams(Arena a) async {
  final boss = a.boss;
  final t1 = await boss.saveTeam(name: '  CT${a.tag} Alpha  ');
  expect(t1.name, 'CT${a.tag} Alpha', reason: 'the name is trimmed');
  expect(t1.code, slugOf('CT${a.tag} Alpha'));
  expect(t1.id, isNotEmpty);
  final t2 = await boss.saveTeam(name: 'CT${a.tag} Beta');
  expect(t2.sort, greaterThan(t1.sort), reason: 'a new team goes last');

  // Same name ignoring case, on create and on rename.
  await expectRefused(
    boss.saveTeam(name: 'ct${a.tag} ALPHA'),
    'That team name is already used.',
    why: 'create, same name other case',
  );
  await expectRefused(
    boss.saveTeam(id: t2.id, name: 'CT${a.tag} alpha'),
    'That team name is already used.',
    why: 'rename onto another team',
  );
  // Renaming to its own name (or its own name in other case) is fine.
  final same = await boss.saveTeam(id: t2.id, name: 'CT${a.tag} BETA');
  expect(same.name, 'CT${a.tag} BETA');
  expect(same.code, t2.code, reason: 'the code does not follow a rename');
  expect(same.sort, t2.sort);

  // Words of every refusal.
  await expectRefused(boss.saveTeam(name: ''), 'Enter a team name.');
  await expectRefused(boss.saveTeam(name: '  \t '), 'Enter a team name.');
  await expectRefused(
    boss.saveTeam(name: padded('CT${a.tag} ', 61)),
    'A team name can have at most 60 characters.',
  );
  await expectRefused(
    boss.saveTeam(name: 'CT${a.tag} a​b'),
    'Use plain text on one line.',
    why: 'zero width space',
  );
  await expectRefused(
    boss.saveTeam(name: 'CT${a.tag} a\nb'),
    'Use plain text on one line.',
    why: 'line break',
  );
  await expectRefused(
    boss.saveTeam(name: 'CT${a.tag} a\u202Eb'),
    'Use plain text on one line.',
    why: 'right to left override',
  );
  await expectRefused(
    boss.saveTeam(id: a.unknownId, name: 'CT${a.tag} Ghost'),
    'That team does not exist.',
  );

  // Exactly 60 characters is fine, counted in characters not bytes.
  final sixty = await boss.saveTeam(name: padded('CT${a.tag} ', 60, 'é'));
  expect(charCount(sixty.name), 60);

  // The catalog lists them, in order.
  final cat = await boss.loadCatalog();
  expect(cat.teams.map((t) => t.id), containsAll([t1.id, t2.id, sixty.id]));
  final order = cat.teams.map((t) => t.id).toList();
  expect(order.indexOf(t1.id), lessThan(order.indexOf(t2.id)));

  // A team with a seat cannot go, an empty one can.
  final p = await a.makePerson('tess');
  final seat = await boss.saveAssignment(
    personId: p.id,
    teamId: t1.id,
    roleTitle: 'Clerk',
  );
  await expectRefused(
    boss.deleteTeam(t1.id),
    'Move or remove the seats of this team first.',
  );
  // Even a deactivated seat keeps its team.
  await boss.saveAssignment(
    id: seat.id,
    personId: p.id,
    teamId: t1.id,
    roleTitle: 'Clerk',
    active: false,
  );
  await expectRefused(
    boss.deleteTeam(t1.id),
    'Move or remove the seats of this team first.',
    why: 'inactive seat',
  );
  await boss.deleteTeam(sixty.id);
  expect(
    (await boss.loadCatalog()).teams.any((t) => t.id == sixty.id),
    isFalse,
  );
  await expectRefused(
    boss.deleteTeam(sixty.id),
    'That team does not exist.',
    why: 'delete twice',
  );
  await expectRefused(
    boss.deleteTeam(a.unknownId),
    'That team does not exist.',
  );
}

Future<void> people(Arena a) async {
  final boss = a.boss;
  final mixed = 'CT${a.tag}.Mixed@Contract.Example';
  final p = await boss.savePerson(
    fullName: '  CT${a.tag} Mina  ',
    email: '  $mixed ',
    role: AppRole.contributor,
  );
  expect(p.fullName, 'CT${a.tag} Mina');
  expect(p.email, mixed.toLowerCase());
  expect(p.appRole, AppRole.contributor);
  expect(p.active, isTrue);

  await expectRefused(
    boss.savePerson(
      fullName: 'CT${a.tag} Other',
      email: mixed.toUpperCase(),
      role: AppRole.contributor,
    ),
    'That email is already used.',
    why: 'duplicate email in other case',
  );

  // Created inactive.
  final off = await boss.savePerson(
    fullName: 'CT${a.tag} Off',
    email: a.email('off'),
    role: AppRole.contributor,
    active: false,
  );
  expect(off.active, isFalse);

  // Words of every refusal, name first.
  Future<void> bad(String name, String email, String message, [String? why]) =>
      expectRefused(
        boss.savePerson(
          fullName: name,
          email: email,
          role: AppRole.contributor,
        ),
        message,
        why: why ?? '"$name" / "$email"',
      );
  const mail = 'Enter a valid email address.';
  await bad('', a.email('z'), 'Enter a name.');
  await bad(' ', a.email('z'), 'Enter a name.');
  await bad('x' * 81, a.email('z'), 'A name can have at most 80 characters.');
  await bad('a​b', a.email('z'), 'Use plain text on one line.');
  await bad('', 'not an email', 'Enter a name.', 'the name is judged first');
  for (final e in [
    '',
    'ana',
    '@x.org',
    'ana@',
    'ana@x',
    'ana@.org',
    'ana@x..org',
    'ana@x.org.',
    'a b@x.org',
    'a@b@x.org',
    '<a@x.org>',
    'a,b@x.org',
    'a;b@x.org',
    'a(b)@x.org',
    r'a\b@x.org',
    'a"b@x.org',
    'a[b]@x.org',
    'a​@x.org',
    'a\tb@x.org',
    '${'a' * 65}@x.org',
  ]) {
    await bad('CT${a.tag} Z', e, mail);
  }
  // Edges that are fine: an 80 character name, a 64 character local part.
  final edge = await boss.savePerson(
    fullName: 'x' * 80,
    email: '${'ct${a.tag}'.padRight(64, 'a')}@contract.example',
    role: AppRole.contributor,
  );
  expect(edge.fullName, 'x' * 80);
  expect(edge.email!.split('@').first, hasLength(64));

  // Update: unknown, and changes.
  await expectRefused(
    boss.savePerson(
      id: a.unknownId,
      fullName: 'Nobody',
      email: a.email('nobody'),
      role: AppRole.contributor,
    ),
    'That person does not exist.',
  );
  final renamed = await boss.savePerson(
    id: p.id,
    fullName: 'CT${a.tag} Mina B',
    email: p.email!, // its own email is not a duplicate
    role: AppRole.contributor,
  );
  expect(renamed.fullName, 'CT${a.tag} Mina B');
  expect(renamed.email, p.email);
  await expectRefused(
    boss.savePerson(
      id: p.id,
      fullName: 'CT${a.tag} Mina B',
      email: off.email!,
      role: AppRole.contributor,
    ),
    'That email is already used.',
    why: 'update onto another email',
  );

  // Role and activity round trip through the catalog.
  final m2 = await boss.savePerson(
    fullName: 'CT${a.tag} Second',
    email: a.email('second'),
    role: AppRole.controller,
  );
  expect(m2.appRole, AppRole.controller);
  var cat = await boss.loadCatalog(includeInactive: true);
  expect(cat.personById(m2.id)!.appRole, AppRole.controller);
  expect(cat.personById(off.id)!.active, isFalse);
  cat = await boss.loadCatalog();
  expect(cat.personById(off.id), isNull, reason: 'inactive people are hidden');

  // A manager can be demoted or switched off while another one stays.
  final demoted = await boss.savePerson(
    id: m2.id,
    fullName: m2.fullName,
    email: m2.email!,
    role: AppRole.contributor,
  );
  expect(demoted.appRole, AppRole.contributor);
  await boss.savePerson(
    id: m2.id,
    fullName: m2.fullName,
    email: m2.email!,
    role: AppRole.controller,
    active: false,
  );
}

Future<void> lastManager(Arena a) async {
  final boss = a.boss;
  final me = a.bossPerson;
  Future<Person> save({AppRole? role, bool? active}) => boss.savePerson(
    id: me.id,
    fullName: me.fullName,
    email: me.email!,
    role: role ?? AppRole.controller,
    active: active ?? true,
  );
  await expectRefused(
    save(role: AppRole.contributor),
    'There must be at least one manager.',
    why: 'demote the only manager',
  );
  await expectRefused(
    save(active: false),
    'There must be at least one manager.',
    why: 'deactivate the only manager',
  );
  // With a second manager the first may step down; then the second is last.
  final m2 = await a.makePerson('second', role: AppRole.controller);
  final down = await save(role: AppRole.contributor);
  expect(down.appRole, AppRole.contributor);
  // The boss is an employee now: the boss session is refused.
  await expectRefused(
    boss.saveTeam(name: 'CT${a.tag} Nope'),
    onlyController,
    why: 'the role is read on every call',
  );
  final second = await a.signInAs(m2.email!);
  await expectRefused(
    second.savePerson(
      id: m2.id,
      fullName: m2.fullName,
      email: m2.email!,
      role: AppRole.contributor,
    ),
    'There must be at least one manager.',
  );
  // Promote the first again.
  await second.savePerson(
    id: me.id,
    fullName: me.fullName,
    email: me.email!,
    role: AppRole.controller,
  );
}

Future<void> seats(Arena a) async {
  final boss = a.boss;
  final t1 = await a.makeTeam('One');
  final t2 = await a.makeTeam('Two');
  final p = await a.makePerson('sam');
  final q = await a.makePerson('tia');

  final s1 = await boss.saveAssignment(
    personId: p.id,
    teamId: t1.id,
    roleTitle: ' Planner ',
  );
  expect(s1.roleTitle, 'Planner');
  expect(s1.personId, p.id);
  expect(s1.teamId, t1.id);
  expect(s1.active, isTrue);
  expect(s1.metrics, isEmpty);
  expect(s1.kpis, isEmpty);
  expect(s1.code, slugOf('${p.fullName} Planner'));
  final s2 = await boss.saveAssignment(
    personId: q.id,
    teamId: t1.id,
    roleTitle: 'Planner',
  );
  expect(s2.sort, greaterThan(s1.sort), reason: 'a new seat goes last');

  // Same person, team and title is refused. The same title in another team,
  // or another title in the same team, is fine.
  await expectRefused(
    boss.saveAssignment(personId: p.id, teamId: t1.id, roleTitle: 'Planner'),
    'That person already has this role in this team.',
  );
  final s3 = await boss.saveAssignment(
    personId: p.id,
    teamId: t2.id,
    roleTitle: 'Planner',
  );
  final s4 = await boss.saveAssignment(
    personId: p.id,
    teamId: t1.id,
    roleTitle: 'Driver',
  );
  expect(s3.code, isNot(s1.code));
  expect(s4.code, isNot(s1.code));

  // Words of every refusal.
  await expectRefused(
    boss.saveAssignment(personId: p.id, teamId: t1.id, roleTitle: ''),
    'Enter a role title.',
  );
  await expectRefused(
    boss.saveAssignment(personId: p.id, teamId: t1.id, roleTitle: 'x' * 81),
    'A role title can have at most 80 characters.',
  );
  await expectRefused(
    boss.saveAssignment(personId: p.id, teamId: t1.id, roleTitle: 'a​b'),
    'Use plain text on one line.',
  );
  await expectRefused(
    boss.saveAssignment(
      personId: a.unknownId,
      teamId: t1.id,
      roleTitle: 'Ghost',
    ),
    'Choose a person.',
  );
  await expectRefused(
    boss.saveAssignment(personId: p.id, teamId: '31999', roleTitle: 'Ghost'),
    'Choose a team.',
  );

  // Move to another team: it keeps its person, and goes last in the new team.
  final moved = await boss.saveAssignment(
    id: s2.id,
    personId: q.id,
    teamId: t2.id,
    roleTitle: 'Planner',
  );
  expect(moved.teamId, t2.id);
  expect(moved.personId, q.id);
  expect(moved.code, s2.code);
  expect(moved.sort, greaterThan(s3.sort), reason: 'last in the new team');
  await expectRefused(
    boss.saveAssignment(
      id: s2.id,
      personId: q.id,
      teamId: '31999',
      roleTitle: 'Planner',
    ),
    'Choose a team.',
    why: 'move to a team that is not there',
  );
  await expectRefused(
    boss.saveAssignment(
      id: s4.id,
      personId: p.id,
      teamId: t1.id,
      roleTitle: 'Planner',
    ),
    'That person already has this role in this team.',
    why: 'rename onto an existing seat',
  );
  await expectRefused(
    boss.saveAssignment(
      id: a.unknownId,
      personId: p.id,
      teamId: t1.id,
      roleTitle: 'Planner',
    ),
    'That seat does not exist.',
  );

  // The catalog is in deck order: team order, then seat order.
  var cat = await boss.loadCatalog();
  final ids = cat.assignments.map((x) => x.id).toList();
  expect(ids.indexOf(s1.id), lessThan(ids.indexOf(s4.id)));
  expect(
    ids.indexOf(s4.id),
    lessThan(ids.indexOf(s3.id)),
    reason: 'team One comes before team Two',
  );
  expect(ids.indexOf(s3.id), lessThan(ids.indexOf(moved.id)));

  // Inactive seats leave the catalog and come back for a manager that asks.
  await boss.saveAssignment(
    id: s4.id,
    personId: p.id,
    teamId: t1.id,
    roleTitle: 'Driver',
    active: false,
  );
  cat = await boss.loadCatalog();
  expect(cat.assignmentById(s4.id), isNull);
  cat = await boss.loadCatalog(includeInactive: true);
  expect(cat.assignmentById(s4.id)!.active, isFalse);
  expect(
    cat.assignmentsOfPerson(p.id).map((x) => x.id),
    containsAll([s1.id, s3.id, s4.id]),
  );
  // Switch it back on.
  final back = await boss.saveAssignment(
    id: s4.id,
    personId: p.id,
    teamId: t1.id,
    roleTitle: 'Driver',
  );
  expect(back.active, isTrue);
}

Future<void> definitions(Arena a) async {
  final boss = a.boss;
  final team = await a.makeTeam('Defs');
  final p = await a.makePerson('dana');
  final other = await a.makePerson('eli');
  final seat = await boss.saveAssignment(
    personId: p.id,
    teamId: team.id,
    roleTitle: 'Planner',
  );
  final foreign = await boss.saveAssignment(
    personId: other.id,
    teamId: team.id,
    roleTitle: 'Planner',
  );
  final foreignDefs = await boss.saveDefinitions(
    foreign.id,
    metrics: const [MetricInput(label: 'Theirs')],
    kpis: const [KpiInput(text: 'Their target')],
  );

  Future<Assignment> save(List<MetricInput> m, [List<KpiInput> k = const []]) =>
      boss.saveDefinitions(seat.id, metrics: m, kpis: k);

  // One count and one target.
  var s = await save(
    const [MetricInput(label: '  Files  ')],
    const [KpiInput(text: ' Answer fast ')],
  );
  expect(s.metrics.single.label, 'Files');
  expect(s.metrics.single.series, 0);
  expect(s.metrics.single.key, 'files');
  expect(s.kpis.single.text, 'Answer fast');
  expect(s.kpis.single.sort, 1);
  final filesId = s.metrics.single.id;
  final answerId = s.kpis.single.id;

  // Eight counts: the first stays, seven are added, the order is the series.
  s = await save([
    MetricInput(id: filesId, label: 'Files'),
    for (var i = 2; i <= 8; i++) MetricInput(label: 'Count $i'),
  ]);
  expect(s.metrics, hasLength(8));
  expect(s.metrics.map((m) => m.series), [0, 1, 2, 3, 4, 5, 6, 7]);
  expect(s.metrics.first.id, filesId);
  expect(s.kpis, isEmpty, reason: 'no targets listed means none kept');

  // A ninth is refused, and nothing changes.
  await expectRefused(
    save([
      for (final m in s.metrics) MetricInput(id: m.id, label: m.label),
      const MetricInput(label: 'Ninth'),
    ]),
    'A seat can have at most 8 counts.',
  );
  expect((await seatOf(a, seat.id)).metrics, hasLength(8));

  // Reorder and rename keep the id.
  final rev = s.metrics.reversed.toList();
  s = await save([
    for (final m in rev) MetricInput(id: m.id, label: '${m.label}!'),
  ]);
  expect(s.metrics.map((m) => m.id), rev.map((m) => m.id));
  expect(s.metrics.map((m) => m.series), [0, 1, 2, 3, 4, 5, 6, 7]);
  expect(s.metrics.first.label, 'Count 8!');
  expect(s.metrics.last.key, 'files', reason: 'the key never changes');

  // Retire down to two, then add a count with a retired name: new id, new key.
  final keep = s.metrics.sublist(0, 2);
  final retiredFiles = s.metrics.last;
  s = await save([for (final m in keep) MetricInput(id: m.id, label: m.label)]);
  expect(s.metrics.map((m) => m.id), keep.map((m) => m.id));
  s = await save([
    for (final m in keep) MetricInput(id: m.id, label: m.label),
    const MetricInput(label: 'Files'),
  ]);
  final again = s.metrics.last;
  expect(again.id, isNot(retiredFiles.id));
  expect(again.key, 'files-2', reason: 'old keys are never reused');

  // Targets: ten are fine, eleven are not. Same wording keeps the id, other
  // wording is a new target with a new id.
  s = await save(
    [for (final m in s.metrics) MetricInput(id: m.id, label: m.label)],
    [
      KpiInput(id: null, text: 'Answer fast'),
      for (var i = 2; i <= 10; i++) KpiInput(text: 'Target $i'),
    ],
  );
  expect(s.kpis, hasLength(10));
  expect(s.kpis.map((k) => k.sort), [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]);
  final kept = s.kpis[1];
  await expectRefused(
    save(const [], [for (var i = 0; i < 11; i++) KpiInput(text: 'T$i')]),
    'A seat can have at most 10 targets.',
  );
  s = await save(
    [for (final m in s.metrics) MetricInput(id: m.id, label: m.label)],
    [
      KpiInput(id: kept.id, text: kept.text),
      KpiInput(id: s.kpis[2].id, text: 'Changed wording'),
      KpiInput(text: kept.text), // two targets may share wording
    ],
  );
  expect(s.kpis, hasLength(3));
  expect(s.kpis[0].id, kept.id);
  expect(s.kpis[1].id, isNot(answerId));
  expect(s.kpis[1].text, 'Changed wording');
  expect(s.kpis[2].text, kept.text);
  expect(s.kpis.map((k) => k.sort), [1, 2, 3]);

  // Words of every refusal. Counts first, then targets, then the seat.
  Future<void> bad(
    List<MetricInput> m,
    List<KpiInput> k,
    String message, [
    String? why,
  ]) => expectRefused(save(m, k), message, why: why);
  await bad(
    const [MetricInput(label: ' ')],
    const [],
    'Give every count a name.',
  );
  await bad(
    [MetricInput(label: 'x' * 61)],
    const [],
    'A count name can have at most 60 characters.',
  );
  await bad(
    const [MetricInput(label: 'a​b')],
    const [],
    'Use plain text on one line.',
  );
  await bad(
    const [MetricInput(label: 'Sea'), MetricInput(label: ' sea ')],
    const [],
    'Two counts have the same name. Give each count its own name.',
  );
  await bad(const [], const [
    KpiInput(text: ''),
  ], 'Write every target in words.');
  await bad(const [], [
    KpiInput(text: 'x' * 201),
  ], 'A target can have at most 200 characters.');
  await bad(const [], const [
    KpiInput(text: 'a\nb'),
  ], 'Use plain text on one line.');
  await bad(
    [
      MetricInput(id: a.unknownId, label: 'A'),
      MetricInput(id: a.unknownId, label: 'B'),
    ],
    const [],
    'The same count is listed twice.',
  );
  await bad(const [], [
    KpiInput(id: a.unknownId, text: 'A'),
    KpiInput(id: a.unknownId, text: 'B'),
  ], 'The same target is listed twice.');
  await bad(
    [MetricInput(id: a.unknownId, label: 'A')],
    const [],
    'One of the counts or targets does not belong to this seat.',
    'a count id nobody has',
  );
  await bad(
    [MetricInput(id: foreignDefs.metrics.single.id, label: 'A')],
    const [],
    'One of the counts or targets does not belong to this seat.',
    'a count of another seat',
  );
  await bad(
    const [],
    [KpiInput(id: foreignDefs.kpis.single.id, text: 'A')],
    'One of the counts or targets does not belong to this seat.',
    'a target of another seat',
  );
  await bad(
    [MetricInput(id: retiredFiles.id, label: 'Old')],
    const [],
    'One of the counts or targets does not belong to this seat.',
    'a retired count cannot come back by id',
  );
  // Rules are judged before the seat is looked up.
  await expectRefused(
    boss.saveDefinitions(
      a.unknownId,
      metrics: [for (var i = 0; i < 9; i++) MetricInput(label: 'C$i')],
      kpis: const [],
    ),
    'A seat can have at most 8 counts.',
  );
  await expectRefused(
    boss.saveDefinitions(a.unknownId, metrics: const [], kpis: const []),
    'That seat does not exist.',
  );
  // Exact edges are fine: 60 characters, 200 characters.
  s = await save(
    [MetricInput(label: padded('', 60, 'é'))],
    [KpiInput(text: padded('', 200, 'é'))],
  );
  expect(charCount(s.metrics.single.label), 60);
  expect(charCount(s.kpis.single.text), 200);
  // And a seat can end with nothing at all.
  s = await save(const []);
  expect(s.hasCounts, isFalse);
  expect(s.kpis, isEmpty);
}

Future<Assignment> seatOf(Arena a, String id) async =>
    (await a.boss.loadCatalog(includeInactive: true)).assignmentById(id)!;

/// What an employee sees of the catalog.
Future<void> catalogViews(Arena a) async {
  final boss = a.boss;
  final team = await a.makeTeam('Views');
  final eve = await a.makeSeat('eve', team);
  final fay = await a.makeSeat('fay', team);
  final gus = await a.makeSeat('gus', team);
  await boss.saveAssignment(
    id: gus.assignment.id,
    personId: gus.person.id,
    teamId: team.id,
    roleTitle: 'Planner',
    active: false,
  );

  final emp = await a.signInAs(eve.email);
  final mine = await emp.loadCatalog();
  expect(
    mine.personById(eve.person.id)!.email,
    eve.email,
    reason: 'an employee sees their own email',
  );
  expect(
    mine.personById(fay.person.id)!.email,
    isNull,
    reason: 'and nobody else\'s',
  );
  expect(
    mine.assignmentById(gus.assignment.id),
    isNull,
    reason: 'inactive seats are hidden',
  );
  final asked = await emp.loadCatalog(includeInactive: true);
  expect(
    asked.assignmentById(gus.assignment.id),
    isNull,
    reason: 'an employee cannot ask for the inactive ones',
  );

  final all = await boss.loadCatalog(includeInactive: true);
  expect(all.personById(fay.person.id)!.email, fay.email);
  expect(all.assignmentById(gus.assignment.id)!.active, isFalse);
  // Counts and targets travel with the seat.
  final seat = mine.assignmentById(eve.assignment.id)!;
  expect(seat.metrics.map((m) => m.label), ['Count 1', 'Count 2']);
  expect(seat.kpis.map((k) => k.text), ['Target 1', 'Target 2']);

  // The catalog stream gives the catalog, then follows a write.
  final seen = <Catalog>[];
  final sub = boss.watchCatalog().listen(seen.add);
  await _until(() => seen.isNotEmpty, 'first catalog');
  final before = seen.length;
  await a.makeTeam('Streamed');
  await _until(() => seen.length > before, 'catalog after a write');
  expect(seen.last.teams.any((t) => t.name == 'CT${a.tag} Streamed'), isTrue);
  await sub.cancel();
}

Future<void> _until(bool Function() ok, String what) async {
  final end = DateTime.now().add(const Duration(seconds: 6));
  while (!ok()) {
    if (DateTime.now().isAfter(end)) fail('timed out waiting for $what');
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
}
