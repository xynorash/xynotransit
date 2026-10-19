// ignore_for_file: prefer_initializing_formals
import 'dart:async';
import 'dart:math';

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
import '../domain/text_rules.dart';
import '../domain/password_rules.dart';
import 'api/api_client.dart'
    show ApiException, UnauthorizedException, waitWords;
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
    final original = _catalog;
    _accounts[_managerKey] = _Account('manager');
    for (final p in _catalog.persons) {
      _accounts[p.id] = _Account(
        UsernameRules.fromEmail(p.email ?? p.fullName, _usernameTaken),
      );
    }
    _catalog = _withAccounts(_catalog.persons, _catalog);
    _catalogLive = _Live(_catalog);
    _sources[original] = this;
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

  /// Targets taken off a seat, or whose words changed. Old reports still hold
  /// their answers.
  final _retiredKpis = <String, List<KpiDef>>{};

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

  /// The acting person as the catalog knows them right now, like the API that
  /// reads the role from the database on every request: a demoted person is an
  /// employee at once, and a deactivated or unknown person is signed out.
  AppUser _me() {
    final u = _meRaw();
    if (_accountOf(u).mustChange) {
      throw const ApiException(403, PasswordRules.mustChangeFirst);
    }
    return u;
  }

  /// Like [_me], but also for a person who must choose a new password first
  /// (the only calls such a person may make).
  AppUser _meRaw() => refreshed(_currentUser());

  /// What the server would answer to `GET /api/me` for the session [u]: the
  /// person as the catalog and the account know them now.
  AppUser refreshed(AppUser u) {
    final id = u.personId;
    if (id != null) {
      final p = _catalog.personById(id);
      if (p == null || !p.active) {
        throw const UnauthorizedException('Please sign in.');
      }
    }
    final a = _accountOf(u);
    if (a.epoch != u.sessionEpoch) {
      throw const UnauthorizedException(PasswordRules.signInAgain);
    }
    if (id == null) return u.copyWith(username: a.username);
    final p = _catalog.personById(id)!;
    return AppUser(
      personId: id,
      role: p.appRole,
      label: p.fullName,
      username: a.username,
      hasPassword: a.password != null,
      mustChangePassword: a.mustChange,
      sessionEpoch: a.epoch,
      viaLink: u.viaLink,
      issuedAt: u.issuedAt,
      recentLinkSession: _recentLink(u, a),
    );
  }

  bool _recentLink(AppUser u, _Account a) =>
      u.viaLink &&
      a.password != null &&
      u.issuedAt != null &&
      _clock().difference(u.issuedAt!) <= PasswordRules.linkRecovery;

  // ---- Passwords ----

  static const _managerKey = '_manager';
  final _accounts = <String, _Account>{};
  final _failures = <String, List<DateTime>>{};
  final _resetTimes = <String, List<DateTime>>{};

  /// What happened to passwords, never the passwords: kind (change, reset,
  /// remove), whose, and who made it happen. For tests.
  final passwordAudit = <({String kind, String personId, String? issuedBy})>[];

  _Account _accountOf(AppUser u) =>
      _accounts.putIfAbsent(u.personId ?? _managerKey, () => _Account('user'));

  bool _usernameTaken(String name) =>
      _accounts.values.any((a) => a.username == name);

  Catalog _withAccounts(List<Person> persons, Catalog base) => Catalog(
    teams: base.teams,
    persons: [
      for (final p in persons)
        Person(
          id: p.id,
          fullName: p.fullName,
          email: p.email,
          appRole: p.appRole,
          active: p.active,
          username: _accounts[p.id]?.username,
          hasPassword: _accounts[p.id]?.password != null,
        ),
    ],
    assignments: base.assignments,
  );

  void _republishPersons() {
    _catalog = _withAccounts(_catalog.persons, _catalog);
    _catalogLive.value = _catalog;
  }

  /// The signed-in state of [personId] as a fresh session, like the one the
  /// server hands out after a sign-in. Null personId is the demo manager.
  AppUser sessionFor(String? personId, {bool viaLink = false}) {
    final p = personId == null ? null : _catalog.personById(personId);
    final a = _accounts[personId ?? _managerKey]!;
    return AppUser(
      personId: personId,
      role: p?.appRole ?? AppRole.controller,
      label: p?.fullName ?? 'Manager',
      username: a.username,
      hasPassword: a.password != null,
      mustChangePassword: a.mustChange,
      sessionEpoch: a.epoch,
      viaLink: viaLink,
      issuedAt: _clock(),
      recentLinkSession: viaLink && a.password != null,
    );
  }

  /// The 429 for a list of failures in the window: the person may try again
  /// when enough of the oldest ones have aged out (so that fewer than [limit]
  /// remain).
  ApiException _locked(List<DateTime> times, int limit, DateTime now) {
    final oldest = times[times.length - limit];
    final wait = oldest.add(PasswordRules.window).difference(now);
    final s = wait.inMilliseconds <= 0
        ? 1
        : (wait.inMilliseconds + 999) ~/ 1000;
    return ApiException(
      429,
      'Too many sign-in attempts. Try again in ${waitWords(s)}.',
      retryAfterSeconds: s,
    );
  }

  List<DateTime> _recentFailures(String key, DateTime now) {
    final l = _failures.putIfAbsent(key, () => []);
    l.removeWhere((t) => now.difference(t) >= PasswordRules.window);
    return l;
  }

  /// The address key of a pair when the address cannot be determined.
  static const unknownAddress = 'unknown';

  String _pairKey(String user, String? address) =>
      'pair|$user|${address ?? unknownAddress}';

  /// Where a sign-in came from last: an address with a successful sign-in
  /// (password or link) for this username within 30 days is trusted.
  final _successes = <String, Map<String, DateTime>>{};

  bool _trusted(String user, String? address, DateTime now) {
    if (address == null) return false;
    final at = _successes[user]?[address];
    return at != null &&
        now.difference(at) < Duration(days: PasswordRules.trustDays);
  }

  void _noteSuccess(String user, String? address, DateTime now) {
    // An address nobody can name is no proof of anything.
    if (address == null) return;
    (_successes[user] ??= {})[address] = now;
  }

  /// Counts one failure for the pair, the username backstop and (for a known
  /// address) the address.
  void _noteFailure(String user, String? address, DateTime now) {
    _recentFailures(_pairKey(user, address), now).add(now);
    _recentFailures('user|$user', now).add(now);
    if (address != null) _recentFailures('addr|$address', now).add(now);
  }

  /// Throws the 429 that applies, or returns. [backstop] is false for the
  /// signed-in password change: failures from other addresses never lock it.
  void _checkLocks(
    String user,
    String? address,
    DateTime now, {
    bool backstop = true,
  }) {
    final pair = _recentFailures(_pairKey(user, address), now);
    if (pair.length >= PasswordRules.failuresPerPair) {
      throw _locked(pair, PasswordRules.failuresPerPair, now);
    }
    if (address != null) {
      final addr = _recentFailures('addr|$address', now);
      if (addr.length >= PasswordRules.failuresPerAddress) {
        throw _locked(addr, PasswordRules.failuresPerAddress, now);
      }
    }
    if (backstop) {
      final all = _recentFailures('user|$user', now);
      if (all.length >= PasswordRules.failuresBackstop &&
          !_trusted(user, address, now)) {
        throw _locked(all, PasswordRules.failuresBackstop, now);
      }
    }
  }

  /// Signs in with a username and a password, with the same answers as the
  /// API: one wrong-login message for every reason (also for an unknown
  /// name). 5 failures per pair of username and [address] in 15 minutes lock
  /// that pair only; 100 failures for the username from anywhere lock it for
  /// every address that has not signed in as that person in 30 days; 30
  /// failures from one known address lock that address. A null [address] is
  /// one the server cannot name: it has no address limit.
  AppUser loginWithPassword(
    String username,
    String password, {
    String? address,
  }) {
    _requireOnline();
    final key = trimText(username).toLowerCase();
    final now = _clock();
    _checkLocks(key, address, now);
    final id = _accounts.entries
        .where((e) => e.value.username == key && e.key != _managerKey)
        .map((e) => e.key)
        .firstOrNull;
    final person = id == null ? null : _catalog.personById(id);
    final account = id == null ? null : _accounts[id];
    if (person == null ||
        !person.active ||
        account?.password == null ||
        account!.password != password) {
      _noteFailure(key, address, now);
      throw const UnauthorizedException(PasswordRules.wrongLogin);
    }
    // The right password: this pair starts again from zero (others do not).
    _recentFailures(_pairKey(key, address), now).clear();
    _noteSuccess(key, address, now);
    return sessionFor(id);
  }

  /// Changes the password of [who] and returns the fresh session. Everything
  /// older ends. A session that began with a link at most 15 minutes ago
  /// needs no current password.
  AppUser changePasswordOf(
    AppUser who, {
    String? currentPassword,
    required String newPassword,
    String? address,
  }) {
    _requireOnline();
    // Check the session the caller holds.
    final a = _accountOf(who);
    if (who.personId != null) {
      final p = _catalog.personById(who.personId!);
      if (p == null || !p.active) {
        throw const UnauthorizedException('Please sign in.');
      }
    }
    if (a.epoch != who.sessionEpoch) {
      throw const UnauthorizedException(PasswordRules.signInAgain);
    }
    if (newPassword.isEmpty) {
      throw const RepositoryException(PasswordRules.newRequired);
    }
    final now = _clock();
    final issued = who.issuedAt;
    final viaLink =
        who.viaLink &&
        issued != null &&
        now.difference(issued) <= PasswordRules.linkRecovery;
    if (a.password != null && !viaLink) {
      if (currentPassword == null || currentPassword.isEmpty) {
        throw const RepositoryException(PasswordRules.currentRequired);
      }
      // Counts against the pair like a wrong login, but only this pair can
      // lock it: others cannot lock a signed-in person out of their own change.
      _checkLocks(a.username, address, now, backstop: false);
      if (currentPassword != a.password) {
        _noteFailure(a.username, address, now);
        throw const ApiException(403, PasswordRules.currentWrong);
      }
      _recentFailures(_pairKey(a.username, address), now).clear();
      if (newPassword == a.password) {
        throw const RepositoryException(PasswordRules.sameAsCurrent);
      }
    }
    final p = who.personId == null ? null : _catalog.personById(who.personId!);
    final problem = PasswordRules.check(
      newPassword,
      username: a.username,
      email: p?.email,
      fullName: p?.fullName ?? who.label,
    );
    if (problem != null) throw RepositoryException(problem);
    final hadPassword = a.password != null;
    a
      ..password = newPassword
      ..mustChange = false
      ..epoch += 1;
    passwordAudit.add((
      kind: hadPassword && viaLink ? 'change-via-link' : 'change',
      personId: who.personId ?? _managerKey,
      issuedBy: null,
    ));
    _republishPersons();
    return sessionFor(who.personId);
  }

  @override
  Future<TempPassword> resetPassword(String personId) async {
    _requireController();
    final me = _me();
    final p = _catalog.personById(personId);
    if (p == null) throw const RepositoryException(AdminRules.noPerson);
    if (!p.active) {
      throw const RepositoryException(AdminRules.personSwitchedOff);
    }
    final now = _clock();
    final times = _resetTimes.putIfAbsent(me.personId ?? '', () => []);
    times.removeWhere((t) => now.difference(t) >= const Duration(hours: 1));
    if (times.length >= PasswordRules.resetsPerHour) {
      final s = times.first.add(const Duration(hours: 1)).difference(now);
      final secs = s.inMilliseconds <= 0 ? 1 : (s.inMilliseconds + 999) ~/ 1000;
      throw ApiException(
        429,
        'Too many temporary passwords created. '
        'Try again in ${waitWords(secs)}.',
        retryAfterSeconds: secs,
      );
    }
    times.add(now);
    final random = Random.secure();
    final temp = List.generate(
      PasswordRules.resetLength,
      (_) =>
          PasswordRules.resetAlphabet[random.nextInt(
            PasswordRules.resetAlphabet.length,
          )],
    ).join();
    final a = _accounts[personId]!
      ..password = temp
      ..mustChange = true
      ..epoch += 1;
    passwordAudit.add((
      kind: 'reset',
      personId: personId,
      issuedBy: me.personId,
    ));
    _republishPersons();
    return TempPassword(username: a.username, password: temp);
  }

  @override
  Future<void> removePassword(String personId) async {
    _requireController();
    final me = _me();
    if (_catalog.personById(personId) == null) {
      throw const RepositoryException(AdminRules.noPerson);
    }
    _accounts[personId]!
      ..password = null
      ..mustChange = false
      ..epoch += 1;
    passwordAudit.add((
      kind: 'remove',
      personId: personId,
      issuedBy: me.personId,
    ));
    _republishPersons();
  }

  static const _onlyController = 'Only the manager can do this.';

  /// Closes a period, which the app has no button for (an operator does it
  /// with SQL). Tests use it to prove what a closed period refuses.
  void closePeriod(String periodId) {
    final p = _periods[periodId];
    if (p == null) return;
    _periods[periodId] = Period(
      id: p.id,
      startMonth: p.startMonth,
      meetingDate: p.meetingDate,
      status: PeriodStatus.closed,
    );
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

  /// A manager who did not ask for the inactive ones sees seats that are
  /// switched on and belong to people who are switched on, and those people
  /// (a switched off person is not expected to report and cannot sign in). An
  /// employee sees only themselves: their own person (with their own email),
  /// their own seats that are switched on, and the teams of those seats. Nobody
  /// else's name, role or team is sent to an employee.
  Catalog _viewOf(Catalog c, bool includeInactive) {
    final me = _me();
    if (includeInactive && me.isController) return c;
    final on = {
      for (final p in c.persons)
        if (p.active) p.id,
    };
    if (!me.isController) {
      final mine = me.personId;
      final seats = [
        for (final a in c.assignments)
          if (a.active && a.personId == mine && on.contains(a.personId)) a,
      ];
      final teamIds = {for (final a in seats) a.teamId};
      return Catalog(
        teams: [
          for (final t in c.teams)
            if (teamIds.contains(t.id)) t,
        ],
        persons: [
          for (final p in c.persons)
            if (p.id == mine && p.active) p,
        ],
        assignments: seats,
      );
    }
    final seats = c.assignments
        .where((a) => a.active && on.contains(a.personId))
        .toList();
    return Catalog(
      teams: c.teams,
      persons: [
        for (final p in c.persons)
          if (p.active) p,
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
    _me();
    final d = AdminRules.checkDate(startMonth);
    if (!d.ok) throw RepositoryException(d.problem!);
    return _periodFor(DateTime(startMonth.year, startMonth.month));
  }

  @override
  Future<void> setMeetingDate(String periodId, DateTime? date) async {
    _requireController();
    var day = date;
    if (day != null) {
      final d = AdminRules.checkDate(day);
      if (!d.ok) throw RepositoryException(d.problem!);
      day = d.value;
    }
    final p = _periods[periodId];
    if (p == null) {
      throw const RepositoryException('That period does not exist.');
    }
    _periods[periodId] = Period(
      id: p.id,
      startMonth: p.startMonth,
      meetingDate: day,
      status: p.status,
    );
  }

  Period? periodById(String id) => _periods[id];

  /// Live lists are for the manager, like the API's list and event calls.
  RepositoryException? _streamRefusal(String periodId) {
    try {
      _requireController();
    } on RepositoryException catch (e) {
      return e;
    }
    if (!_periods.containsKey(periodId)) {
      return const RepositoryException('That period does not exist.');
    }
    return null;
  }

  @override
  Stream<List<Report>> watchReports(String periodId) {
    final refused = _streamRefusal(periodId);
    if (refused != null) return Stream.error(refused);
    _liveReports.putIfAbsent(
      periodId,
      () => _Live(List.unmodifiable(_reportsOf(periodId))),
    );
    return _liveReports[periodId]!.watch();
  }

  @override
  Future<Report?> getReport(String periodId, String assignmentId) async {
    _requireOnline();
    final me = _me();
    if (!me.isController) {
      final owner = _catalog.assignmentById(assignmentId)?.personId;
      if (owner == null || owner != me.personId) {
        throw const RepositoryException('You can only see your own report.');
      }
    }
    for (final r in _reportsOf(periodId)) {
      if (r.assignmentId == assignmentId) return r;
    }
    return null;
  }

  @override
  Future<Report> sendReport(Report report) async {
    _requireOnline();
    final me = _me();
    final period = _periods[report.periodId];
    if (period == null) {
      throw const RepositoryException('That period does not exist.');
    }
    final a = _catalog.assignmentById(report.assignmentId);
    if (a == null || !a.active) {
      throw const RepositoryException('That seat does not exist.');
    }
    if (!me.isController && me.personId != a.personId) {
      throw const RepositoryException('You can only send your own report.');
    }
    if (period.status == PeriodStatus.closed && !me.isController) {
      throw const RepositoryException('This period is closed.');
    }
    final problems = report.validate(a, period);
    if (problems.isNotEmpty) throw RepositoryException(problems.first);

    final list = [..._reportsOf(period.id)];
    final i = list.indexWhere((r) => r.assignmentId == report.assignmentId);
    // Stored the way the database stores it: only the seat's counts, three
    // slots each, trimmed words, empty comments as none.
    final saved = Report(
      id: i >= 0 ? list[i].id : 'r-${++_seq}',
      periodId: period.id,
      assignmentId: a.id,
      status: ReportStatus.submitted,
      submittedAt: _clock(),
      values: {
        for (final m in a.metrics)
          m.id: [for (var s = 0; s < 3; s++) report.values[m.id]?[s]],
      },
      kpis: {
        for (final k in a.kpis)
          if (report.kpis[k.id] != null)
            k.id: KpiResult(
              report.kpis[k.id]!.status,
              comment: _commentOf(report.kpis[k.id]!.comment),
            ),
      },
      notes: {
        for (final k in NoteKind.values)
          k: [for (final t in report.notesOf(k)) trimText(t)],
      },
      reporter: Reporter.fromJson(report.reporter?.toJson()),
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

  static String? _commentOf(String? c) {
    final t = trimText(c ?? '');
    return t.isEmpty ? null : t;
  }

  @override
  Stream<DeckRun?> watchDeck(String periodId) {
    final refused = _streamRefusal(periodId);
    if (refused != null) return Stream.error(refused);
    _liveDecks.putIfAbsent(periodId, () => _Live(null));
    return _liveDecks[periodId]!.watch();
  }

  /// The seat with the counts and targets [r] was answered against: live and
  /// retired ones that the report has numbers or answers for, in series and
  /// sort order. A slide shows what the report says, whatever the manager
  /// changed since. If a retired count and a renumbered live one share a series,
  /// the series are renumbered in order so no two bars share a colour.
  Assignment _answeredDefinitions(Assignment a, Report r) {
    final metrics =
        <MetricDef>[
          for (final m in [...a.metrics, ...?_retired[a.id]])
            if (r.values.containsKey(m.id)) m,
        ]..sort((x, y) {
          final c = x.series.compareTo(y.series);
          return c != 0 ? c : x.id.compareTo(y.id);
        });
    final distinct = {for (final m in metrics) m.series};
    final numbered = distinct.length == metrics.length
        ? metrics
        : [
            for (final (i, m) in metrics.indexed)
              MetricDef(id: m.id, key: m.key, label: m.label, series: i),
          ];
    final kpis =
        <KpiDef>[
          for (final k in [...a.kpis, ...?_retiredKpis[a.id]])
            if (r.kpis.containsKey(k.id)) k,
        ]..sort((x, y) {
          final c = x.sort.compareTo(y.sort);
          return c != 0 ? c : x.id.compareTo(y.id);
        });
    return Assignment(
      id: a.id,
      code: a.code,
      personId: a.personId,
      teamId: a.teamId,
      roleTitle: a.roleTitle,
      sort: a.sort,
      metrics: numbered,
      kpis: kpis,
      active: a.active,
    );
  }

  /// Builds the deck from what this repository holds, like the server does:
  /// the catalog and the period passed in are not trusted.
  @override
  Future<DeckRun> generateDeck(Period period, Catalog catalog) async {
    _requireController();
    final known = _periods[period.id];
    if (known == null) {
      throw const RepositoryException('That period does not exist.');
    }
    // A seat is expected when it and its person are switched on, like the
    // server. Reports of switched off seats or people are still in the deck.
    final expected = _catalog.assignments.where(_catalog.isExpected).length;
    final order = {
      for (var i = 0; i < _catalog.assignments.length; i++)
        _catalog.assignments[i].id: i,
    };
    // Works with any number of submitted reports, none included.
    final submitted =
        _reportsOf(known.id)
            .where((r) => r.isSubmitted && order.containsKey(r.assignmentId))
            .toList()
          ..sort(
            (a, b) => order[a.assignmentId]!.compareTo(order[b.assignmentId]!),
          );
    final items = <DeckItem>[];
    for (var i = 0; i < submitted.length; i++) {
      final r = submitted[i];
      items.add(
        DeckItem(
          reportId: r.id!,
          sort: i + 1,
          // Round trip through JSON so the deck holds exactly what the database would hold.
          snapshot: ReportSnapshot.fromJson(
            ReportSnapshot.build(
              report: r,
              assignment: _answeredDefinitions(
                _catalog.assignmentById(r.assignmentId)!,
                r,
              ),
              catalog: _catalog,
              period: known,
            ).toJson(),
          ),
        ),
      );
    }
    final run = DeckRun(
      id: 'deck-${++_seq}',
      periodId: known.id,
      generatedAt: _clock(),
      expectedCount: expected,
      includedCount: submitted.length,
      switchedOffCount: submitted
          .where(
            (r) =>
                !_catalog.isExpected(_catalog.assignmentById(r.assignmentId)!),
          )
          .length,
      items: items,
      texts: _effectiveTexts(known.id).texts,
    );
    _liveDecks.putIfAbsent(known.id, () => _Live(null)).value = run;
    return run;
  }

  // ---- Manager only: who reports, on what ----

  void _requireController() {
    _requireOnline();
    if (!_me().isController) {
      throw const RepositoryException(_onlyController);
    }
  }

  void _setCatalog({
    List<Team>? teams,
    List<Person>? persons,
    List<Assignment>? assignments,
  }) {
    _catalog = _withAccounts(
      persons ?? _catalog.persons,
      Catalog(
        teams: teams ?? _catalog.teams,
        persons: const [],
        assignments: assignments ?? _catalog.assignments,
      ),
    );
    _catalogLive.value = _catalog;
  }

  static T _ok<T>(Cleaned<T> c) {
    if (!c.ok) throw RepositoryException(c.problem!);
    return c.value as T;
  }

  static const _noTeam = RepositoryException('That team does not exist.');

  bool _teamNameTaken(String name, String? except) => _catalog.teams.any(
    (t) => t.id != except && t.name.toLowerCase() == name.toLowerCase(),
  );

  @override
  Future<Team> saveTeam({String? id, required String name}) async {
    _requireController();
    final n = _ok(AdminRules.cleanTeamName(name));
    final teams = [..._catalog.teams];
    final i = id == null ? -1 : teams.indexWhere((t) => t.id == id);
    if (_teamNameTaken(n, id)) {
      throw const RepositoryException(AdminRules.teamNameTaken);
    }
    if (id != null) {
      if (i < 0) throw _noTeam;
      final t = teams[i];
      teams[i] = Team(id: t.id, code: t.code, name: n, sort: t.sort);
      _setCatalog(teams: teams);
      return teams[i];
    }
    final t = Team(
      id: 'team-${++_seq}',
      code: uniqueSlug(slugOf(n), (c) => teams.any((x) => x.code == c)),
      name: n,
      sort: teams.fold(0, (m, x) => x.sort > m ? x.sort : m) + 1,
    );
    _setCatalog(teams: [...teams, t]);
    return t;
  }

  @override
  Future<void> deleteTeam(String id) async {
    _requireController();
    if (!_catalog.teams.any((t) => t.id == id)) throw _noTeam;
    if (_catalog.assignments.any((a) => a.teamId == id)) {
      throw const RepositoryException(
        'Move or remove the seats of this team first.',
      );
    }
    _setCatalog(teams: _catalog.teams.where((t) => t.id != id).toList());
  }

  @override
  Future<Person> savePerson({
    String? id,
    required String fullName,
    required String email,
    required AppRole role,
    bool active = true,
    String? username,
  }) async {
    _requireController();
    final name = _ok(AdminRules.cleanPersonName(fullName));
    final persons = [..._catalog.persons];
    final i = id == null ? -1 : persons.indexWhere((p) => p.id == id);
    if (id != null && i < 0) {
      throw const RepositoryException('That person does not exist.');
    }
    final blank = trimText(email).isEmpty;
    final String mail;
    if (!blank) {
      mail = _ok(AdminRules.cleanEmail(email));
    } else if (i >= 0 && persons[i].email != null) {
      mail = persons[i].email!;
    } else {
      mail = internalEmailOf(
        name,
        AdminRules.internalDomain,
        (e) => persons.any((p) => p.email?.toLowerCase() == e),
      );
    }
    if (persons.any((p) => p.id != id && p.email?.toLowerCase() == mail)) {
      throw const RepositoryException(AdminRules.emailTaken);
    }
    // The username: typed (checked) or made from the address on creation.
    final typed = trimText(username ?? '');
    String? newName;
    if (typed.isNotEmpty) {
      newName = UsernameRules.clean(typed);
      if (newName == null) {
        throw const RepositoryException(UsernameRules.invalid);
      }
      final owner = _accounts.entries
          .where((e) => e.value.username == newName)
          .map((e) => e.key)
          .firstOrNull;
      if (owner != null && owner != id) {
        throw const RepositoryException(UsernameRules.taken);
      }
    }
    final person = Person(
      id: id ?? 'person-${++_seq}',
      fullName: name,
      email: mail,
      appRole: role,
      active: active,
    );
    if (id == null) {
      _accounts[person.id] = _Account(
        newName ?? UsernameRules.fromEmail(mail, _usernameTaken),
      );
    } else if (newName != null) {
      _accounts[id]!.username = newName;
    }
    // Nobody may take the last manager away, by role or by switching them off.
    if (i >= 0) {
      final cur = persons[i];
      final was = cur.active && cur.appRole == AppRole.controller;
      final will = active && role == AppRole.controller;
      final others = persons.any(
        (p) => p.id != id && p.active && p.appRole == AppRole.controller,
      );
      if (was && !will && !others) {
        throw const RepositoryException(AdminRules.lastManager);
      }
      persons[i] = person;
    } else {
      persons.add(person);
    }
    _setCatalog(persons: persons);
    return _catalog.personById(person.id)!;
  }

  final _links = <String, _IssuedLink>{};
  final _linkTimes = <String, List<DateTime>>{};

  @override
  Future<SignInLink> createSignInLink(String personId, {int hours = 24}) async {
    _requireController();
    final me = _me();
    if (hours < 1 || hours > AdminRules.maxSignInHours) {
      throw const RepositoryException(AdminRules.hoursInvalid);
    }
    final p = _catalog.personById(personId);
    if (p == null) throw const RepositoryException(AdminRules.noPerson);
    if (!p.active) {
      throw const RepositoryException(AdminRules.personSwitchedOff);
    }
    final now = _clock();
    final times = _linkTimes.putIfAbsent(me.personId ?? '', () => []);
    times.removeWhere((t) => now.difference(t) >= const Duration(hours: 1));
    if (times.length >= AdminRules.maxSignInLinksPerHour) {
      throw const RepositoryException(AdminRules.tooManyLinks);
    }
    times.add(now);
    final random = Random.secure();
    final token =
        'demo-${List.generate(12, (_) => random.nextInt(36).toRadixString(36)).join()}';
    final expires = now.add(Duration(hours: hours));
    _links[token] = _IssuedLink(personId, expires);
    return SignInLink(
      url: 'https://demo.invalid/auth/verify?token=$token',
      expiresAt: expires,
      personId: personId,
    );
  }

  /// Uses a link made by [createSignInLink], like the server does with the
  /// token: once, before it expires, for a person who is still active. Returns
  /// the person now signed in. Demo links are only displayed in the app; this
  /// is for tests and the contract suite.
  AppUser redeemSignInLink(String url, {String? address}) {
    const refused = RepositoryException(
      'This link has expired or was already used. Ask for a new one.',
    );
    final token = Uri.tryParse(url)?.queryParameters['token'];
    final link = token == null ? null : _links[token];
    if (link == null || link.used || !_clock().isBefore(link.expiresAt)) {
      throw refused;
    }
    final p = _catalog.personById(link.personId);
    if (p == null || !p.active) throw refused;
    link.used = true;
    final who = _catalog.personById(p.id)!;
    final account = _accounts[who.id];
    if (account != null) _noteSuccess(account.username, address, _clock());
    return sessionFor(p.id, viaLink: true);
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
    final role = _ok(AdminRules.cleanRoleTitle(roleTitle));
    final seats = [..._catalog.assignments];
    final i = id == null ? -1 : seats.indexWhere((a) => a.id == id);
    if (id != null && i < 0) {
      throw const RepositoryException('That seat does not exist.');
    }
    final old = i >= 0 ? seats[i] : null;
    // A seat keeps its person; only the team, the title and the state move.
    final owner = old?.personId ?? personId;
    final person = _catalog.personById(owner);
    if (old == null && person == null) {
      throw const RepositoryException('Choose a person.');
    }
    if (!_catalog.teams.any((t) => t.id == teamId)) {
      throw const RepositoryException('Choose a team.');
    }
    final duplicate = seats.any(
      (a) =>
          a.id != id &&
          a.personId == owner &&
          a.teamId == teamId &&
          a.roleTitle == role,
    );
    if (duplicate) {
      throw const RepositoryException(AdminRules.seatTaken);
    }
    final code =
        old?.code ??
        uniqueSlug(
          slugOf('${person!.fullName} $role'),
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
    final problem =
        AdminRules.checkMetrics(metrics) ?? AdminRules.checkKpis(kpis);
    if (problem != null) throw RepositoryException(problem);
    final seats = [..._catalog.assignments];
    final i = seats.indexWhere((a) => a.id == assignmentId);
    if (i < 0) throw const RepositoryException('That seat does not exist.');
    final seat = seats[i];

    final metricById = {for (final m in seat.metrics) m.id: m};
    final kpiById = {for (final k in seat.kpis) k.id: k};
    if (metrics.any((m) => m.id != null && !metricById.containsKey(m.id)) ||
        kpis.any((k) => k.id != null && !kpiById.containsKey(k.id))) {
      throw const RepositoryException(AdminRules.notThisSeat);
    }

    final keys = _keys.putIfAbsent(seat.id, () => {});
    final newMetrics = <MetricDef>[];
    for (final (pos, m) in metrics.indexed) {
      final label = trimText(m.label);
      final old = m.id == null ? null : metricById[m.id];
      if (old != null) {
        newMetrics.add(
          MetricDef(id: old.id, key: old.key, label: label, series: pos),
        );
      } else {
        final key = uniqueSlug(slugOf(label), keys.contains);
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
      final text = trimText(k.text);
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
    final keptKpis = {for (final k in newKpis) k.id};
    _retiredKpis[seat.id] = [
      ...?_retiredKpis[seat.id],
      for (final k in seat.kpis)
        if (!keptKpis.contains(k.id)) k,
    ];

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
    if (trend < 1 || trend > 24) {
      throw const RepositoryException(
        'The trend must be a number from 1 to 24.',
      );
    }
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
    // Every signed-in person reads the words: the live preview needs them.
    _requireOnline();
    _me();
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
      final problem = DeckTexts.check(f, texts[f.key]);
      if (problem != null) throw RepositoryException(problem);
      clean = clean.withValue(f.key, DeckTexts.normalise(f, texts[f.key]));
    }
    _deckTexts[periodId] = clean;
    return DeckTextsState(texts: clean);
  }
}

class _Account {
  _Account(this.username);
  String username;
  String? password;
  bool mustChange = false;
  int epoch = 0;
}

class _IssuedLink {
  _IssuedLink(this.personId, this.expiresAt);
  final String personId;
  final DateTime expiresAt;
  bool used = false;
}

/// Demo sign-in: pick who you are, no email. With [requireSignIn] it starts
/// signed out and signs in with a username and password or a link, like the
/// real thing (tests use this; the public demo does not).
class DemoAuth implements AuthService, LinkSignIn {
  DemoAuth(this._catalog, {this.requireSignIn = false})
    : _user = requireSignIn ? null : controller;

  final Catalog _catalog;
  final bool requireSignIn;
  AppUser? _user;
  final _c = StreamController<AppUser?>.broadcast();

  static const controller = AppUser(
    personId: null,
    role: AppRole.controller,
    label: 'Manager',
  );

  MemoryRepository get _repo {
    final repo = MemoryRepository._sources[_catalog];
    if (repo == null) {
      throw StateError('DemoAuth needs the MemoryRepository of its catalog.');
    }
    return repo;
  }

  /// The demo people a viewer can act as. Follows the people of the
  /// repository built on the same catalog, so a person added later shows up.
  List<AppUser> get choices {
    final repo = MemoryRepository._sources[_catalog];
    final persons = repo?.currentPersons ?? _catalog.persons;
    return [
      repo?.sessionFor(null) ?? controller,
      for (final p in persons)
        repo?.sessionFor(p.id) ??
            AppUser(personId: p.id, role: p.appRole, label: p.fullName),
    ];
  }

  void actAs(AppUser u) {
    final repo = MemoryRepository._sources[_catalog];
    _user = repo == null ? u : repo.sessionFor(u.personId);
    _c.add(_user);
  }

  @override
  AppUser? get currentUser => _user;

  @override
  Stream<AppUser?> get userChanges async* {
    yield _user;
    yield* _c.stream;
  }

  @override
  bool get needsSignIn => requireSignIn;

  @override
  Future<void> signInWithEmail(String email) async {}

  @override
  Future<void> signInWithPassword(String username, String password) async {
    _user = _repo.loginWithPassword(username, password);
    _c.add(_user);
  }

  @override
  Future<void> exchangeToken(String token) async {
    _user = _repo.redeemSignInLink('https://demo.invalid/?token=$token');
    _c.add(_user);
  }

  @override
  Future<void> changePassword({
    String? currentPassword,
    required String newPassword,
  }) async {
    final me = _user;
    if (me == null) throw const UnauthorizedException('Please sign in.');
    _user = _repo.changePasswordOf(
      me,
      currentPassword: currentPassword,
      newPassword: newPassword,
    );
    _c.add(_user);
  }

  @override
  Future<void> signOut() async {
    // The public demo has no sign-in: signing out goes back to the manager.
    _user = requireSignIn ? null : _repo.sessionFor(null);
    _c.add(_user);
  }
}
