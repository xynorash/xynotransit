// Deck, deck words and summary scenarios.
import 'package:flutter_test/flutter_test.dart';
import 'package:xynotransit_app/domain/admin.dart';
import 'package:xynotransit_app/domain/catalog.dart';
import 'package:xynotransit_app/domain/deck_text.dart';
import 'package:xynotransit_app/domain/enums.dart';
import 'package:xynotransit_app/domain/period.dart';
import 'package:xynotransit_app/domain/report.dart';
import 'package:xynotransit_app/domain/snapshot.dart';
import 'package:xynotransit_app/domain/summary_compute.dart';

import 'arena.dart';
import 'scenarios_admin.dart' show onlyController;
import 'scenarios_reports.dart' show eventually;

Future<void> deck(Arena a) async {
  final boss = a.boss;
  // Team B is made first, so it comes first in the deck.
  final tb = await a.makeTeam('Deck B');
  final ta = await a.makeTeam('Deck A');
  final alice = await a.makeSeat('alice', ta);
  final bob = await a.makeSeat('bob', ta, counts: 1, targets: 3);
  final carol = await a.makeSeat('carol', tb, counts: 0, targets: 0);
  final p = await boss.ensurePeriod(a.start(0));

  expect(await boss.watchDeck(p.id).first, isNull, reason: 'no deck yet');

  // Zero reports: a deck with nothing in it (cover and suggestions only).
  var cat = await boss.loadCatalog();
  final active = cat.expectedCount;
  final empty = await boss.generateDeck(p, cat);
  expect(empty.items, isEmpty);
  expect(empty.includedCount, 0);
  expect(empty.expectedCount, active);
  expect(empty.periodId, p.id);
  expect(empty.id, isNotEmpty);
  expect(
    DateTime.now().difference(empty.generatedAt).abs(),
    lessThan(const Duration(minutes: 2)),
  );
  expect((await boss.watchDeck(p.id).first)!.id, empty.id);

  // One report.
  Future<Report> send(Seat s, {int n = 5, int step = 1, Reporter? who}) async {
    final emp = await a.signInAs(s.email);
    final seat = (await emp.loadCatalog()).assignmentById(s.assignment.id)!;
    return emp.sendReport(fullReport(seat, p, n: n, step: step, reporter: who));
  }

  final ra = await send(
    alice,
    who: const Reporter(name: 'Alice A.', country: 'Kenya', role: 'Lead'),
  );
  cat = await boss.loadCatalog();
  final one = await boss.generateDeck(p, cat);
  expect(one.id, isNot(empty.id));
  expect(one.items, hasLength(1));
  expect(one.includedCount, 1);
  expect(one.items.single.reportId, ra.id);
  expect(one.items.single.sort, 1, reason: 'items are numbered from 1');
  final snap = one.items.single.snapshot;
  expect(snap.name, 'Alice A.');
  expect(snap.team, 'Kenya', reason: 'the slide team is the reporter country');
  expect(snap.role, 'Lead');
  expect(snap.assignmentCode, alice.assignment.code);
  expect(snap.periodLabel, p.label);
  expect(snap.months.map((m) => m.short), p.months.map((m) => m.short));
  // The snapshot is exactly what the pure code builds from the same data.
  final expected = ReportSnapshot.build(
    report: ra,
    assignment: cat.assignmentById(alice.assignment.id)!,
    catalog: cat,
    period: p,
  );
  expect(snap.toJson(), expected.toJson());

  // N reports, in deck order: team order, then seat order.
  final rb = await send(bob, n: 1000000000, step: 0);
  final rc = await send(carol, n: 0);
  cat = await boss.loadCatalog();
  final three = await boss.generateDeck(p, cat);
  expect(three.items.map((i) => i.reportId), [rc.id, ra.id, rb.id]);
  expect(three.items.map((i) => i.sort), [1, 2, 3]);
  expect(three.includedCount, 3);
  expect(three.expectedCount, cat.expectedCount);
  expect(
    three.items[0].snapshot.metrics,
    isEmpty,
    reason: 'carol has no counts',
  );
  expect(three.items[0].snapshot.targets, isEmpty);
  final bobSnap = three.items[2].snapshot;
  expect(bobSnap.metrics.single.values, [1000000000, 1000000000, 1000000000]);
  expect(bobSnap.metrics.single.total, 3000000000);
  expect(bobSnap.targets, hasLength(3));
  for (final i in three.items) {
    final r = [ra, rb, rc].firstWhere((r) => r.id == i.reportId);
    final seat = cat.assignmentById(r.assignmentId)!;
    expect(
      i.snapshot.toJson(),
      ReportSnapshot.build(
        report: r,
        assignment: seat,
        catalog: cat,
        period: p,
      ).toJson(),
      reason: seat.code,
    );
  }

  // The latest deck is the one that was made last, and older ones are frozen:
  // sending a report again changes nothing in a deck that exists.
  expect((await boss.watchDeck(p.id).first)!.id, three.id);
  await send(alice, n: 99);
  final latest = (await boss.watchDeck(p.id).first)!;
  expect(latest.id, three.id);
  expect(
    latest.items[1].snapshot.toJson(),
    three.items[1].snapshot.toJson(),
    reason: 'a deck is frozen',
  );
  final fresh = await boss.generateDeck(p, await boss.loadCatalog());
  expect(fresh.items[1].snapshot.metrics.first.values, [99, 100, 101]);

  // A seat that is switched off drops out of the deck and of "expected".
  await boss.saveAssignment(
    id: bob.assignment.id,
    personId: bob.person.id,
    teamId: ta.id,
    roleTitle: bob.assignment.roleTitle,
    active: false,
  );
  cat = await boss.loadCatalog();
  final less = await boss.generateDeck(p, cat);
  expect(less.includedCount, 2);
  expect(less.expectedCount, cat.expectedCount);
  expect(less.items.map((i) => i.snapshot.assignmentCode), [
    carol.assignment.code,
    alice.assignment.code,
  ]);

  // A slide shows the counts the report was answered against: a count taken
  // off the seat since stays on it, a count added since (no numbers) is not on it.
  final changed = await boss.saveDefinitions(
    alice.assignment.id,
    metrics: [
      MetricInput(
        id: alice.assignment.metrics[0].id,
        label: alice.assignment.metrics[0].label,
      ),
      const MetricInput(label: 'Fresh'),
    ],
    kpis: [
      for (final k in alice.assignment.kpis) KpiInput(id: k.id, text: k.text),
    ],
  );
  cat = await boss.loadCatalog();
  final after = await boss.generateDeck(p, cat);
  final aliceNow = after.items
      .firstWhere((i) => i.snapshot.assignmentCode == alice.assignment.code)
      .snapshot;
  expect(aliceNow.metrics.map((m) => m.label), ['Count 1', 'Count 2']);
  expect(aliceNow.metrics.map((m) => m.series), [0, 1]);
  expect(aliceNow.metrics[0].values, [99, 100, 101]);
  expect(aliceNow.metrics[1].values, [99, 100, 101]);
  expect(changed.metrics.map((m) => m.label), ['Count 1', 'Fresh']);

  // A target whose words changed (a new target, the old one retired) keeps its
  // old wording on the slide of the report that answered it.
  final reworded = await boss.saveDefinitions(
    alice.assignment.id,
    metrics: [
      for (final m in changed.metrics) MetricInput(id: m.id, label: m.label),
    ],
    kpis: [
      KpiInput(
        id: alice.assignment.kpis[0].id,
        text: 'A new wording of the first target',
      ),
      KpiInput(
        id: alice.assignment.kpis[1].id,
        text: alice.assignment.kpis[1].text,
      ),
    ],
  );
  expect(reworded.kpis[0].id, isNot(alice.assignment.kpis[0].id));
  final last = await boss.generateDeck(p, await boss.loadCatalog());
  final aliceLast = last.items
      .firstWhere((i) => i.snapshot.assignmentCode == alice.assignment.code)
      .snapshot;
  expect(aliceLast.targets.map((t) => t.text), ['Target 1', 'Target 2']);
  expect(aliceLast.targets.map((t) => t.status), [
    KpiStatus.met,
    KpiStatus.met,
  ]);
}

DeckTexts _custom() => DeckTexts.defaults
    .withValue('title', 'Meeting {period}')
    .withValue('orgName', 'Acme')
    .withValue('suggestionsBody', 'Line one\nLine two');

Future<void> deckTexts(Arena a) async {
  final boss = a.boss;
  final team = await a.makeTeam('Words');
  final s = await a.makeSeat('wes', team);
  final p1 = await boss.ensurePeriod(a.start(0));
  final p2 = await boss.ensurePeriod(a.start(1));
  final p3 = await boss.ensurePeriod(a.start(2));
  final emp = await a.signInAs(s.email);

  // Before anything is saved here, the words are carried over from earlier or
  // are the built-in ones. Never "own".
  final before = await boss.loadDeckTexts(p1.id);
  expect(before.inheritedFrom, isNotNull);
  final empNow = await emp.loadDeckTexts(p1.id);
  expect(
    empNow.texts,
    before.texts,
    reason: 'an employee reads the same words',
  );

  // Save for P1.
  final saved = await boss.saveDeckTexts(p1.id, _custom());
  expect(saved.inheritedFrom, isNull, reason: 'P1 has its own words now');
  expect(saved.texts['title'], 'Meeting {period}');
  expect(saved.texts['suggestionsBody'], 'Line one\nLine two');
  expect(
    saved.texts['subtitle'],
    DeckTexts.defaults['subtitle'],
    reason: 'the rest keeps the defaults',
  );
  expect((await boss.loadDeckTexts(p1.id)).texts, saved.texts);

  // P2 and P3 have none: they inherit from the latest earlier one, P1.
  final in2 = await boss.loadDeckTexts(p2.id);
  expect(in2.inheritedFrom, p1.label);
  expect(in2.texts, saved.texts);
  expect((await emp.loadDeckTexts(p3.id)).inheritedFrom, p1.label);

  // A deck made now freezes the words in force.
  final d2 = await boss.generateDeck(p2, await boss.loadCatalog());
  expect(d2.texts, saved.texts, reason: 'inherited words are frozen too');

  // P3 gets its own; P2 still takes P1 (P3 is later, not earlier).
  final own3 = await boss.saveDeckTexts(
    p3.id,
    DeckTexts.defaults.withValue('title', 'Third'),
  );
  expect(own3.inheritedFrom, isNull);
  expect((await boss.loadDeckTexts(p2.id)).inheritedFrom, p1.label);

  // Changing P1 later moves P2 but never an existing deck.
  await boss.saveDeckTexts(
    p1.id,
    DeckTexts.defaults.withValue('title', 'Changed {period}'),
  );
  expect((await boss.loadDeckTexts(p2.id)).texts['title'], 'Changed {period}');
  expect(
    (await boss.watchDeck(p2.id).first)!.texts['title'],
    'Meeting {period}',
    reason: 'the deck keeps the words it was made with',
  );
  final d2b = await boss.generateDeck(p2, await boss.loadCatalog());
  expect(d2b.texts['title'], 'Changed {period}');
  expect(d2b.id, isNot(d2.id));

  // Trimming, line breaks and the words of every refusal.
  final trimmed = await boss.saveDeckTexts(
    p1.id,
    DeckTexts.defaults
        .withValue('title', '  Padded  ')
        .withValue('suggestionsBody', 'a\r\nb\rc'),
  );
  expect(trimmed.texts['title'], 'Padded');
  expect(trimmed.texts['suggestionsBody'], 'a\nb\nc');
  Future<void> bad(String key, String value, String message) => expectRefused(
    boss.saveDeckTexts(p1.id, DeckTexts.defaults.withValue(key, value)),
    message,
    why: '$key = "$value"',
  );
  await bad('title', '', 'Meeting title cannot be empty.');
  await bad('title', '   ', 'Meeting title cannot be empty.');
  await bad('title', 'x' * 81, 'Meeting title can be at most 80 characters.');
  await bad(
    'title',
    'Hello {team}',
    '{team} cannot be used in Meeting title. It allows {period}.',
  );
  await bad(
    'orgName',
    'A {period}',
    '{period} cannot be used in Organisation name. It allows no placeholders.',
  );
  await bad('title', 'a​b', 'Use plain text in Meeting title.');
  await bad('title', 'a\nb', 'Use plain text in Meeting title.');
  await bad('title', 'a\tb', 'Use plain text in Meeting title.');
  await bad('suggestionsBody', 'a\u0007b', 'Use plain text in Page text.');
  // Empty is fine where it is allowed; exact limit is fine.
  final ok = await boss.saveDeckTexts(
    p1.id,
    DeckTexts.defaults.withValue('dateText', '').withValue('title', 'é' * 80),
  );
  expect(ok.texts['dateText'], '');
  expect(ok.texts['title'].runes.length, 80);
  // Unknown period, and employees cannot save.
  await expectRefused(
    boss.loadDeckTexts(a.unknownId),
    'That period does not exist.',
  );
  await expectRefused(
    boss.saveDeckTexts(a.unknownId, DeckTexts.defaults),
    'That period does not exist.',
  );
  await expectRefused(
    emp.saveDeckTexts(p1.id, DeckTexts.defaults),
    onlyController,
  );
}

/// What the pure code makes of the same data, to hold the API against.
Future<void> summary(Arena a) async {
  final boss = a.boss;
  final ta = await a.makeTeam('Sum A');
  final tb = await a.makeTeam('Sum B');
  final l = 'CT${a.tag}';
  final amy = await a.makeSeat(
    'amy',
    ta,
    labels: ['$l Vol', '$l Parcels'],
    targets: 3,
  );
  final ben = await a.makeSeat('ben', ta, labels: ['$l vol'], targets: 2);
  final cal = await a.makeSeat('cal', tb, labels: ['$l Parcels'], targets: 1);
  final dot = await a.makeSeat('dot', tb, counts: 0, targets: 0);
  final ps = [for (var i = 0; i < 3; i++) await boss.ensurePeriod(a.start(i))];

  Future<void> send(Seat s, Period p, int n, KpiStatus status) async {
    final emp = await a.signInAs(s.email);
    final seat = (await emp.loadCatalog()).assignmentById(s.assignment.id)!;
    // One billion is the largest number a count can hold: keep it flat.
    await emp.sendReport(
      fullReport(seat, p, n: n, step: n == 1000000000 ? 0 : 1, status: status),
    );
  }

  await send(amy, ps[0], 3, KpiStatus.met);
  await send(ben, ps[0], 10, KpiStatus.missed);
  await send(amy, ps[1], 4, KpiStatus.partly);
  await send(cal, ps[1], 1000000000, KpiStatus.met);
  await send(amy, ps[2], 5, KpiStatus.met);
  await send(ben, ps[2], 1000000000, KpiStatus.partly);
  await send(cal, ps[2], 1000000000, KpiStatus.missed);
  await send(dot, ps[2], 0, KpiStatus.met);

  Future<void> compare(
    int trend, {
    Map<String, List<MetricDef>> retired = const {},
  }) async {
    final cat = await boss.loadCatalog(includeInactive: true);
    final reports = {
      for (final p in ps) p.id: await boss.watchReports(p.id).first,
    };
    final live = await boss.loadSummary(ps[2].id, trend: trend);
    final pure = computeSummary(
      period: ps[2],
      allPeriods: ps,
      catalog: cat,
      reports: reports,
      retired: retired,
      trend: trend,
    );
    final reason = 'trend $trend';
    expect(live.periodId, pure.periodId);
    expect(live.periodLabel, pure.periodLabel, reason: reason);
    expect(
      [for (final m in live.months) m.toJson()],
      [for (final m in pure.months) m.toJson()],
    );
    expect(live.expected, pure.expected, reason: reason);
    expect(live.submitted, pure.submitted, reason: reason);
    expect(
      [
        for (final t in live.teams.where((t) => t.name.startsWith(l)))
          t.toJson(),
      ],
      [
        for (final t in pure.teams.where((t) => t.name.startsWith(l)))
          t.toJson(),
      ],
      reason: 'teams, $reason',
    );
    expect(
      [
        for (final m in live.metrics.where((m) => m.label.startsWith(l)))
          m.toJson(),
      ],
      [
        for (final m in pure.metrics.where((m) => m.label.startsWith(l)))
          m.toJson(),
      ],
      reason: 'counts, $reason',
    );
    expect(
      [
        for (final x in live.people.where((x) => x.name.startsWith(l)))
          x.toJson(),
      ],
      [
        for (final x in pure.people.where((x) => x.name.startsWith(l)))
          x.toJson(),
      ],
      reason: 'people, $reason',
    );
    final mine = {for (final p in ps) p.id};
    expect(
      [
        for (final t in live.trend.where((t) => mine.contains(t.periodId)))
          t.toJson(),
      ],
      [
        for (final t in pure.trend.where((t) => mine.contains(t.periodId)))
          t.toJson(),
      ],
      reason: 'trend, $reason',
    );
    expect(
      live.trend.last.periodId,
      ps[2].id,
      reason: 'the shown period is last',
    );
    expect(live.trend.length, lessThanOrEqualTo(trend));
  }

  await compare(6);
  await compare(1);
  await compare(2);
  await compare(24);

  // The numbers themselves, so the pure code is not only agreeing with a bug.
  final s = await boss.loadSummary(ps[2].id);
  final vol = s.metrics.firstWhere(
    (m) => m.label.toLowerCase() == '$l vol'.toLowerCase(),
  );
  expect(vol.label, '$l Vol', reason: 'the first spelling is shown');
  // amy: 5, 6, 7 on Vol, ben: one billion a month on vol.
  expect(vol.byMonth, [5 + 1000000000, 6 + 1000000000, 7 + 1000000000]);
  expect(vol.total, 18 + 3000000000);
  final parcels = s.metrics.firstWhere((m) => m.label == '$l Parcels');
  expect(parcels.total, 18 + 3000000000);
  expect(s.teams.firstWhere((t) => t.name == 'CT${a.tag} Sum A').submitted, 2);
  expect(s.teams.firstWhere((t) => t.name == 'CT${a.tag} Sum B').submitted, 2);

  // A count taken off a seat keeps counting in reports that hold it.
  final amyNow = (await boss.loadCatalog()).assignmentById(amy.assignment.id)!;
  await boss.saveDefinitions(
    amy.assignment.id,
    metrics: [
      MetricInput(id: amyNow.metrics[0].id, label: amyNow.metrics[0].label),
    ],
    kpis: [for (final k in amyNow.kpis) KpiInput(id: k.id, text: k.text)],
  );
  await compare(
    6,
    retired: {
      amy.assignment.id: [amyNow.metrics[1]],
    },
  );

  // Trend words.
  const trendWords = 'The trend must be a number from 1 to 24.';
  await expectRefused(boss.loadSummary(ps[2].id, trend: 0), trendWords);
  await expectRefused(boss.loadSummary(ps[2].id, trend: 25), trendWords);
  await expectRefused(boss.loadSummary(ps[2].id, trend: -1), trendWords);
  await expectRefused(
    boss.loadSummary(a.unknownId),
    'That period does not exist.',
  );
  await eventually(
    () async => (await boss.loadSummary(ps[2].id, trend: 1)).trend.length,
    (n) => n == 1,
    'trend of one',
  );
}
