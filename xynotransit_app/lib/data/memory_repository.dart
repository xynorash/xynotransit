// ignore_for_file: prefer_initializing_formals
import 'dart:async';

import '../domain/admin.dart';
import '../domain/summary.dart';
import '../domain/summary_compute.dart';
import '../domain/catalog.dart';
import '../domain/deck.dart';
import '../domain/deck_text.dart';
import '../domain/enums.dart';
import '../domain/period.dart';
import '../domain/report.dart';
import '../domain/snapshot.dart';
import 'demo_data.dart';
import 'repository.dart';
import 'seed_data.dart';

/// Replays the latest value to every new listener, then follows changes.
class _Live<T> {
  _Live(this._value);
  T _value;
  final _c = StreamController<T>.broadcast();

  T get value => _value;
  set value(T v) {
    _value = v;
    _c.add(v);
  }

  Stream<T> watch() async* {
    yield _value;
    yield* _c.stream;
  }
}

/// Runs the whole app without a server. Same rules as the database:
/// sending replaces, submitting needs every number and every target.
class MemoryRepository implements Repository {
  MemoryRepository({
    Catalog? catalog,
    required AppUser Function() currentUser,
    bool withDemoReports = false,
    DateTime Function()? clock,
  }) : _catalog = catalog ?? buildSeedCatalog(),
       _currentUser = currentUser,
       _clock = clock ?? DateTime.now {
    _catalogLive = _Live(_catalog);
    _sources[_catalog] = this;
    for (final a in _catalog.assignments) {
      _keys[a.id] = {for (final m in a.metrics) m.key};
    }
    if (withDemoReports) {
      final p = _periodFor(demoStart, meeting: DateTime(2026, 6, 9));
      for (final r in buildDemoReports(_catalog, p.id)) {
        _reports[p.id] = [...(_reports[p.id] ?? []), r];
      }
    }
  }

  /// Feb to Apr 2026, the period the demo reports belong to.
  static final demoStart = DateTime(2026, 2);

  /// The whole catalog, inactive rows included.
  Catalog _catalog;
  late final _Live<Catalog> _catalogLive;

  /// Lets [DemoAuth] find the repository that owns the catalog it was given.
  static final _sources = Expando<MemoryRepository>('catalog owner');

  /// Counts taken off a seat. Old reports still hold their numbers.
  final _retired = <String, List<MetricDef>>{};

  /// Every count key ever used on a seat, so a new key never reuses an old one.
  final _keys = <String, Set<String>>{};
  var _kpiSeq = 1000;
  final AppUser Function() _currentUser;
  final DateTime Function() _clock;

  final _periods = <String, Period>{};
  final _reports = <String, List<Report>>{};
  final _liveReports = <String, _Live<List<Report>>>{};
  final _liveDecks = <String, _Live<DeckRun?>>{};
  final _deckTexts = <String, DeckTexts>{};
  var _seq = 0;

  /// Tests flip this to act as a person without a connection.
  bool offline = false;

  void _requireOnline() {
    if (offline) throw const NetworkException();
  }

  Period _periodFor(DateTime start, {DateTime? meeting}) {
    final id = 'period-${Period.dateOnly(DateTime(start.year, start.month))}';
    return _periods.putIfAbsent(
      id,
      () => Period(id: id, startMonth: start, meetingDate: meeting),
    );
  }

  List<Report> _reportsOf(String periodId) => _reports[periodId] ?? const [];

  void _publish(String periodId) {
    final live = _liveReports.putIfAbsent(periodId, () => _Live(const []));
    live.value = List.unmodifiable(_reportsOf(periodId));
  }

  @override
  Future<Catalog> loadCatalog({bool includeInactive = false}) async =>
      _viewOf(_catalog, includeInactive);

  @override
  Stream<Catalog> watchCatalog({bool includeInactive = false}) =>
      _catalogLive.watch().map((c) => _viewOf(c, includeInactive));

  /// Everyone but a controller, and a controller who did not ask, only sees
  /// active seats and people (people who still hold a visible seat stay).
  Catalog _viewOf(Catalog c, bool includeInactive) {
    if (includeInactive && _currentUser().isController) return c;
    final seats = c.assignments.where((a) => a.active).toList();
    final used = {for (final a in seats) a.personId};
    return Catalog(
      teams: c.teams,
      persons: [
        for (final p in c.persons)
          if (p.active || used.contains(p.id)) p,
      ],
      assignments: seats,
    );
  }

  /// The people of the catalog as it is now, for the demo sign-in menu.
  List<Person> get currentPersons =>
      _catalog.persons.where((p) => p.active).toList();

  @override
  Future<Period> ensurePeriod(DateTime startMonth) async {
    _requireOnline();
    return _periodFor(startMonth);
  }

  @override
  Future<void> setMeetingDate(String periodId, DateTime? date) async {
    _requireOnline();
    if (!_currentUser().isController) {
      throw const RepositoryException('Only the controller can do this.');
    }
    final p = _periods[periodId];
    if (p == null) return;
    _periods[periodId] = Period(
      id: p.id,
      startMonth: p.startMonth,
      meetingDate: date,
      status: p.status,
    );
  }

  Period? periodById(String id) => _periods[id];

  @override
  Stream<List<Report>> watchReports(String periodId) {
    _liveReports.putIfAbsent(
      periodId,
      () => _Live(List.unmodifiable(_reportsOf(periodId))),
    );
    return _liveReports[periodId]!.watch();
  }

  @override
  Future<Report?> getReport(String periodId, String assignmentId) async {
    _requireOnline();
    for (final r in _reportsOf(periodId)) {
      if (r.assignmentId == assignmentId) return r;
    }
    return null;
  }

  @override
  Future<Report> sendReport(Report report) async {
    _requireOnline();
    final a = _catalog.assignmentById(report.assignmentId);
    final period = _periods.values
        .where((p) => p.id == report.periodId)
        .firstOrNull;
    if (a == null || period == null) {
      throw const RepositoryException('This person or period does not exist.');
    }
    final user = _currentUser();
    if (!user.isController && user.personId != a.personId) {
      throw const RepositoryException('You can only send your own report.');
    }
    final problems = report.validate(a, period);
    if (problems.isNotEmpty) throw RepositoryException(problems.first);
    for (final k in NoteKind.values) {
      final list = report.notesOf(k);
      if (list.length > NoteRules.maxCount ||
          list.any((s) => NoteRules.clean(s) == null)) {
        throw const RepositoryException(
          'Notes must be 1 to 70 characters, three at most per box.',
        );
      }
    }
    final list = [..._reportsOf(period.id)];
    final i = list.indexWhere((r) => r.assignmentId == report.assignmentId);
    final saved = report.copyWith(
      id: i >= 0 ? list[i].id : 'r-${++_seq}',
      status: ReportStatus.submitted,
      submittedAt: _clock(),
    );
    if (i >= 0) {
      list[i] = saved;
    } else {
      list.add(saved);
    }
    _reports[period.id] = list;
    _publish(period.id);
    return saved;
  }

  @override
  Stream<DeckRun?> watchDeck(String periodId) {
    _liveDecks.putIfAbsent(periodId, () => _Live(null));
    return _liveDecks[periodId]!.watch();
  }

  @override
  Future<DeckRun> generateDeck(Period period, Catalog catalog) async {
    _requireOnline();
    if (!_currentUser().isController) {
      throw const RepositoryException('Only the controller can do this.');
    }
    final submitted = _reportsOf(period.id)
        .where((r) => r.isSubmitted)
        .toList();
    final order = {
      for (var i = 0; i < catalog.assignments.length; i++)
        catalog.assignments[i].id: i,
    };
    submitted.sort(
      (a, b) =>
          (order[a.assignmentId] ?? 0).compareTo(order[b.assignmentId] ?? 0),
    );
    final items = <DeckItem>[];
    for (var i = 0; i < submitted.length; i++) {
      final r = submitted[i];
      final a = catalog.assignmentById(r.assignmentId)!;
      items.add(
        DeckItem(
          reportId: r.id!,
          sort: i,
          // Round trip through JSON so the deck holds exactly what the database would hold.
          snapshot: ReportSnapshot.fromJson(
            ReportSnapshot.build(
              report: r,
              assignment: a,
              catalog: catalog,
              period: period,
            ).toJson(),
          ),
        ),
      );
    }
    final run = DeckRun(
      id: 'deck-${++_seq}',
      periodId: period.id,
      generatedAt: _clock(),
      expectedCount: catalog.assignments.length,
      includedCount: submitted.length,
      items: items,
      texts: _effectiveTexts(period.id).texts,
    );
    _liveDecks.putIfAbsent(period.id, () => _Live(null)).value = run;
    return run;
  }

  // ---- Manager only: who reports, on what ----

  void _requireController() {
    _requireOnline();
    if (!_currentUser().isController) {
      throw const RepositoryException('Only the controller can do this.');
    }
  }

  void _setCatalog({
    List<Team>? teams,
    List<Person>? persons,
    List<Assignment>? assignments,
  }) {
    _catalog = Catalog(
      teams: teams ?? _catalog.teams,
      persons: persons ?? _catalog.persons,
      assignments: assignments ?? _catalog.assignments,
    );
    _catalogLive.value = _catalog;
  }

  static String _slug(String s) {
    final t = s
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    return t.isEmpty ? 'x' : t;
  }

  static String _unique(String base, bool Function(String) taken) {
    var c = base;
    for (var n = 2; taken(c); n++) {
      c = '$base-$n';
    }
    return c;
  }

  @override
  Future<Team> saveTeam({String? id, required String name}) async {
    _requireController();
    final n = name.trim();
    if (n.isEmpty || n.length > 60) {
      throw const RepositoryException(
        'Give the team a name of 1 to 60 characters.',
      );
    }
    final teams = [..._catalog.teams];
    if (id != null) {
      final i = teams.indexWhere((t) => t.id == id);
      if (i < 0) throw const RepositoryException('That team does not exist.');
      final t = teams[i];
      teams[i] = Team(id: t.id, code: t.code, name: n, sort: t.sort);
      _setCatalog(teams: teams);
      return teams[i];
    }
    final t = Team(
      id: 'team-${++_seq}',
      code: _unique(_slug(n), (c) => teams.any((x) => x.code == c)),
      name: n,
      sort: teams.fold(0, (m, x) => x.sort > m ? x.sort : m) + 1,
    );
    _setCatalog(teams: [...teams, t]);
    return t;
  }

  @override
  Future<void> deleteTeam(String id) async {
    _requireController();
    if (_catalog.assignments.any((a) => a.teamId == id)) {
      throw const RepositoryException(
        'Move or remove the seats of this team first.',
      );
    }
    if (!_catalog.teams.any((t) => t.id == id)) {
      throw const RepositoryException('That team does not exist.');
    }
    _setCatalog(teams: _catalog.teams.where((t) => t.id != id).toList());
  }

  static final _emailShape = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');

  @override
  Future<Person> savePerson({
    String? id,
    required String fullName,
    required String email,
    required AppRole role,
    bool active = true,
  }) async {
    _requireController();
    final name = fullName.trim();
    if (name.isEmpty || name.length > DefinitionRules.maxName) {
      throw RepositoryException(
        'Give the person a name of 1 to ${DefinitionRules.maxName} characters.',
      );
    }
    final mail = email.trim().toLowerCase();
    if (!_emailShape.hasMatch(mail)) {
      throw const RepositoryException('Enter a valid email address.');
    }
    final persons = [..._catalog.persons];
    if (persons.any((p) => p.id != id && p.email?.toLowerCase() == mail)) {
      throw const RepositoryException('That email is already used.');
    }
    final person = Person(
      id: id ?? 'person-${++_seq}',
      fullName: name,
      email: mail,
      appRole: role,
      active: active,
    );
    final i = persons.indexWhere((p) => p.id == id);
    if (id != null && i < 0) {
      throw const RepositoryException('That person does not exist.');
    }
    if (i >= 0) {
      persons[i] = person;
    } else {
      persons.add(person);
    }
    final hadManager = _catalog.persons.any(
      (p) => p.active && p.appRole == AppRole.controller,
    );
    final hasManager = persons.any(
      (p) => p.active && p.appRole == AppRole.controller,
    );
    if (hadManager && !hasManager) {
      throw const RepositoryException('There must be at least one manager.');
    }
    _setCatalog(persons: persons);
    return person;
  }

  @override
  Future<Assignment> saveAssignment({
    String? id,
    required String personId,
    required String teamId,
    required String roleTitle,
    bool active = true,
  }) async {
    _requireController();
    final role = roleTitle.trim();
    if (role.isEmpty || role.length > DefinitionRules.maxRoleTitle) {
      throw RepositoryException(
        'Give the role a title of 1 to ${DefinitionRules.maxRoleTitle} characters.',
      );
    }
    final seats = [..._catalog.assignments];
    final i = id == null ? -1 : seats.indexWhere((a) => a.id == id);
    if (id != null && i < 0) {
      throw const RepositoryException('That seat does not exist.');
    }
    final old = i >= 0 ? seats[i] : null;
    // A seat keeps its person; only the team, the title and the state move.
    final owner = old?.personId ?? personId;
    if (!_catalog.persons.any((p) => p.id == owner)) {
      throw const RepositoryException('That person does not exist.');
    }
    if (!_catalog.teams.any((t) => t.id == teamId)) {
      throw const RepositoryException('That team does not exist.');
    }
    final duplicate = seats.any(
      (a) =>
          a.id != id &&
          a.personId == owner &&
          a.teamId == teamId &&
          a.roleTitle.toLowerCase() == role.toLowerCase(),
    );
    if (duplicate) {
      throw const RepositoryException(
        'That person already has this role in this team.',
      );
    }
    final code =
        old?.code ??
        _unique(
          _slug(
            '${_catalog.persons.firstWhere((p) => p.id == owner).fullName}-$role',
          ),
          (c) => seats.any((a) => a.code == c),
        );
    final moved = old == null || old.teamId != teamId;
    final sort = moved
        ? seats
                  .where((a) => a.teamId == teamId)
                  .fold(0, (m, a) => a.sort > m ? a.sort : m) +
              1
        : old.sort;
    final seat = Assignment(
      id: old?.id ?? code,
      code: code,
      personId: owner,
      teamId: teamId,
      roleTitle: role,
      sort: sort,
      metrics: old?.metrics ?? const [],
      kpis: old?.kpis ?? const [],
      active: active,
    );
    if (i >= 0) {
      seats[i] = seat;
    } else {
      seats.add(seat);
      _keys[seat.id] = {};
    }
    _setCatalog(assignments: seats);
    return seat;
  }

  @override
  Future<Assignment> saveDefinitions(
    String assignmentId, {
    required List<MetricInput> metrics,
    required List<KpiInput> kpis,
  }) async {
    _requireController();
    final seats = [..._catalog.assignments];
    final i = seats.indexWhere((a) => a.id == assignmentId);
    if (i < 0) throw const RepositoryException('That seat does not exist.');
    final seat = seats[i];

    if (metrics.length > DefinitionRules.maxMetrics) {
      throw const RepositoryException('A seat can have 8 counts at most.');
    }
    if (kpis.length > DefinitionRules.maxKpis) {
      throw const RepositoryException('A seat can have 20 targets at most.');
    }
    final labels = <String>{};
    for (final m in metrics) {
      final l = m.label.trim();
      if (l.isEmpty || l.length > DefinitionRules.maxMetricLabel) {
        throw const RepositoryException(
          'Each count needs a name of 1 to 60 characters.',
        );
      }
      if (!labels.add(l.toLowerCase())) {
        throw const RepositoryException(
          'Two counts of this seat have the same name.',
        );
      }
    }
    for (final k in kpis) {
      final t = k.text.trim();
      if (t.isEmpty || t.length > DefinitionRules.maxKpiText) {
        throw const RepositoryException(
          'Each target needs a text of 1 to 200 characters.',
        );
      }
    }
    final metricById = {for (final m in seat.metrics) m.id: m};
    final kpiById = {for (final k in seat.kpis) k.id: k};
    const foreign = 'Some of the counts or targets do not belong to this seat.';
    for (final m in metrics) {
      if (m.id != null && !metricById.containsKey(m.id)) {
        throw const RepositoryException(foreign);
      }
    }
    for (final k in kpis) {
      if (k.id != null && !kpiById.containsKey(k.id)) {
        throw const RepositoryException(foreign);
      }
    }

    final keys = _keys.putIfAbsent(seat.id, () => {});
    final newMetrics = <MetricDef>[];
    for (final (pos, m) in metrics.indexed) {
      final label = m.label.trim();
      final old = m.id == null ? null : metricById[m.id];
      if (old != null) {
        newMetrics.add(
          MetricDef(id: old.id, key: old.key, label: label, series: pos),
        );
      } else {
        final key = _unique(_slug(label), keys.contains);
        keys.add(key);
        newMetrics.add(
          MetricDef(
            id: '${seat.code}/$key',
            key: key,
            label: label,
            series: pos,
          ),
        );
      }
    }
    final kept = {for (final m in newMetrics) m.id};
    _retired[seat.id] = [
      ...?_retired[seat.id],
      for (final m in seat.metrics)
        if (!kept.contains(m.id)) m,
    ];

    final newKpis = <KpiDef>[];
    for (final (pos, k) in kpis.indexed) {
      final text = k.text.trim();
      final old = k.id == null ? null : kpiById[k.id];
      newKpis.add(
        old != null && old.text == text
            ? KpiDef(id: old.id, sort: pos + 1, text: text)
            : KpiDef(
                id: '${seat.code}/k${++_kpiSeq}',
                sort: pos + 1,
                text: text,
              ),
      );
    }

    final saved = Assignment(
      id: seat.id,
      code: seat.code,
      personId: seat.personId,
      teamId: seat.teamId,
      roleTitle: seat.roleTitle,
      sort: seat.sort,
      metrics: newMetrics,
      kpis: newKpis,
      active: seat.active,
    );
    seats[i] = saved;
    _setCatalog(assignments: seats);
    return saved;
  }

  @override
  Future<Summary> loadSummary(String periodId, {int trend = 6}) async {
    _requireController();
    final period = _periods[periodId];
    if (period == null) {
      throw const RepositoryException('That period does not exist.');
    }
    return computeSummary(
      period: period,
      allPeriods: _periods.values.toList(),
      catalog: _catalog,
      reports: _reports,
      retired: _retired,
      trend: trend,
    );
  }

  /// Own words of the period, else those of the latest earlier period that
  /// has some, else the built-in defaults.
  DeckTextsState _effectiveTexts(String periodId) {
    final own = _deckTexts[periodId];
    if (own != null) return DeckTextsState(texts: own);
    final period = _periods[periodId];
    if (period != null) {
      Period? best;
      for (final p in _periods.values) {
        if (!_deckTexts.containsKey(p.id)) continue;
        if (!p.startMonth.isBefore(period.startMonth)) continue;
        if (best == null || p.startMonth.isAfter(best.startMonth)) best = p;
      }
      if (best != null) {
        return DeckTextsState(
          texts: _deckTexts[best.id]!,
          inheritedFrom: best.label,
        );
      }
    }
    return DeckTextsState(texts: DeckTexts.defaults, inheritedFrom: 'defaults');
  }

  @override
  Future<DeckTextsState> loadDeckTexts(String periodId) async {
    _requireController();
    if (!_periods.containsKey(periodId)) {
      throw const RepositoryException('That period does not exist.');
    }
    return _effectiveTexts(periodId);
  }

  @override
  Future<DeckTextsState> saveDeckTexts(String periodId, DeckTexts texts) async {
    _requireController();
    if (!_periods.containsKey(periodId)) {
      throw const RepositoryException('That period does not exist.');
    }
    var clean = DeckTexts.defaults;
    for (final f in deckTextFields) {
      final v = texts[f.key].trim();
      final problem = DeckTexts.check(f, v);
      if (problem != null) throw RepositoryException(problem);
      clean = clean.withValue(f.key, v);
    }
    _deckTexts[periodId] = clean;
    return DeckTextsState(texts: clean);
  }
}

/// Demo sign-in: pick who you are, no email.
class DemoAuth implements AuthService {
  DemoAuth(this._catalog) : _user = controller;

  final Catalog _catalog;
  AppUser _user;
  final _c = StreamController<AppUser?>.broadcast();

  static const controller = AppUser(
    personId: null,
    role: AppRole.controller,
    label: 'Controller',
  );

  /// The demo people a viewer can act as. Follows the people of the
  /// repository built on the same catalog, so a person added later shows up.
  List<AppUser> get choices {
    final repo = MemoryRepository._sources[_catalog];
    final persons = repo?.currentPersons ?? _catalog.persons;
    return [
      controller,
      for (final p in persons)
        AppUser(personId: p.id, role: p.appRole, label: p.fullName),
    ];
  }

  void actAs(AppUser u) {
    _user = u;
    _c.add(u);
  }

  @override
  AppUser? get currentUser => _user;

  @override
  Stream<AppUser?> get userChanges async* {
    yield _user;
    yield* _c.stream;
  }

  @override
  bool get needsSignIn => false;

  @override
  Future<void> signInWithEmail(String email) async {}

  @override
  Future<void> signOut() async {}
}
