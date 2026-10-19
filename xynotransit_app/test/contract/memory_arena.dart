import 'dart:async';

import 'package:xynotransit_app/data/memory_repository.dart';
import 'package:xynotransit_app/data/repository.dart';
import 'package:xynotransit_app/domain/catalog.dart';
import 'package:xynotransit_app/domain/enums.dart';
import 'package:xynotransit_app/domain/period.dart';
import 'package:xynotransit_app/domain/admin.dart';
import 'package:xynotransit_app/domain/deck.dart';
import 'package:xynotransit_app/domain/deck_text.dart';
import 'package:xynotransit_app/domain/report.dart';
import 'package:xynotransit_app/domain/summary.dart';

import 'arena.dart';

const _actor = #contractActor;

/// Runs every call as one person, whoever else is acting at the same time.
class _Acting implements Repository {
  _Acting(this._r, this.me);
  final MemoryRepository _r;

  /// Replaced after a password change: the fresh session.
  AppUser me;

  T _as<T>(T Function() f) => runZoned(f, zoneValues: {_actor: me});

  @override
  Future<Catalog> loadCatalog({bool includeInactive = false}) =>
      _as(() => _r.loadCatalog(includeInactive: includeInactive));
  @override
  Stream<Catalog> watchCatalog({bool includeInactive = false}) =>
      _as(() => _r.watchCatalog(includeInactive: includeInactive));
  @override
  Future<Period> ensurePeriod(DateTime startMonth) =>
      _as(() => _r.ensurePeriod(startMonth));
  @override
  Future<void> setMeetingDate(String periodId, DateTime? date) =>
      _as(() => _r.setMeetingDate(periodId, date));
  @override
  Stream<List<Report>> watchReports(String periodId) =>
      _as(() => _r.watchReports(periodId));
  @override
  Future<Report?> getReport(String periodId, String assignmentId) =>
      _as(() => _r.getReport(periodId, assignmentId));
  @override
  Future<Report> sendReport(Report report) => _as(() => _r.sendReport(report));
  @override
  Stream<DeckRun?> watchDeck(String periodId) =>
      _as(() => _r.watchDeck(periodId));
  @override
  Future<DeckRun> generateDeck(Period period, Catalog catalog) =>
      _as(() => _r.generateDeck(period, catalog));
  @override
  Future<Team> saveTeam({String? id, required String name}) =>
      _as(() => _r.saveTeam(id: id, name: name));
  @override
  Future<void> deleteTeam(String id) => _as(() => _r.deleteTeam(id));
  @override
  Future<Person> savePerson({
    String? id,
    required String fullName,
    required String email,
    required AppRole role,
    bool active = true,
    String? username,
  }) => _as(
    () => _r.savePerson(
      id: id,
      fullName: fullName,
      email: email,
      role: role,
      active: active,
      username: username,
    ),
  );
  @override
  Future<TempPassword> resetPassword(String personId) =>
      _as(() => _r.resetPassword(personId));
  @override
  Future<void> removePassword(String personId) =>
      _as(() => _r.removePassword(personId));
  @override
  Future<SignInLink> createSignInLink(String personId, {int hours = 24}) =>
      _as(() => _r.createSignInLink(personId, hours: hours));
  @override
  Future<Assignment> saveAssignment({
    String? id,
    required String personId,
    required String teamId,
    required String roleTitle,
    bool active = true,
  }) => _as(
    () => _r.saveAssignment(
      id: id,
      personId: personId,
      teamId: teamId,
      roleTitle: roleTitle,
      active: active,
    ),
  );
  @override
  Future<Assignment> saveDefinitions(
    String assignmentId, {
    required List<MetricInput> metrics,
    required List<KpiInput> kpis,
  }) =>
      _as(() => _r.saveDefinitions(assignmentId, metrics: metrics, kpis: kpis));
  @override
  Future<DeckTextsState> loadDeckTexts(String periodId) =>
      _as(() => _r.loadDeckTexts(periodId));
  @override
  Future<DeckTextsState> saveDeckTexts(String periodId, DeckTexts texts) =>
      _as(() => _r.saveDeckTexts(periodId, texts));
  @override
  Future<Summary> loadSummary(String periodId, {int trend = 6}) =>
      _as(() => _r.loadSummary(periodId, trend: trend));
}

class _MemorySession implements PersonSession {
  _MemorySession(this._r, this._acting, this._address);
  final MemoryRepository _r;
  final _Acting _acting;
  final String? _address;

  @override
  Repository get repo => _acting;

  @override
  Future<AppUser> me() async => _r.refreshed(_acting.me);

  @override
  Future<void> changePassword({
    String? currentPassword,
    required String newPassword,
  }) async {
    _acting.me = _r.changePasswordOf(
      _acting.me,
      currentPassword: currentPassword,
      newPassword: newPassword,
      address: _address,
    );
  }
}

class MemoryArena implements Arena {
  MemoryArena._(this._repo, this._boss, this.tag);

  static Future<MemoryArena> create(String tag) async {
    late MemoryRepository repo;
    var n = 0;
    final boss = Person(
      id: 'person-boss',
      fullName: 'CT$tag Boss',
      email: 'ct$tag-boss@contract.example',
      appRole: AppRole.controller,
    );
    final catalog = Catalog(
      teams: const [],
      persons: [boss],
      assignments: const [],
    );
    final fallback = AppUser(
      personId: boss.id,
      role: AppRole.controller,
      label: boss.fullName,
    );
    repo = MemoryRepository(
      catalog: catalog,
      currentUser: () => (Zone.current[_actor] as AppUser?) ?? fallback,
      clock: () => DateTime.now().add(Duration(seconds: n++)),
    );
    final arena = MemoryArena._(repo, boss, tag);
    return arena;
  }

  final MemoryRepository _repo;
  final Person _boss;
  @override
  final String tag;
  late final Repository _bossRepo = _Acting(
    _repo,
    AppUser(
      personId: _boss.id,
      role: AppRole.controller,
      label: _boss.fullName,
    ),
  );

  @override
  Repository get boss => _bossRepo;
  @override
  Person get bossPerson => _boss;

  @override
  Future<Repository> signInAs(String email, {bool fresh = false}) async {
    final p = _repo.currentPersons
        .where((p) => p.email?.toLowerCase() == email.toLowerCase())
        .firstOrNull;
    // An internal address never receives mail, so no link is ever sent.
    if (p == null || email.toLowerCase().endsWith('@xynotransit.internal')) {
      throw SignInRefused(email);
    }
    return _Acting(
      _repo,
      AppUser(personId: p.id, role: p.appRole, label: p.fullName),
    );
  }

  @override
  Future<Repository> signInWithLink(String url) async {
    final u = _repo.redeemSignInLink(url);
    return _Acting(_repo, u);
  }

  @override
  Future<PersonSession> signInWithPassword(
    String username,
    String password, {
    String? address,
  }) async => _MemorySession(
    _repo,
    _Acting(
      _repo,
      _repo.loginWithPassword(username, password, address: address),
    ),
    address,
  );

  @override
  Future<PersonSession> signInWithLinkSession(
    String url, {
    String? address,
  }) async => _MemorySession(
    _repo,
    _Acting(_repo, _repo.redeemSignInLink(url, address: address)),
    address,
  );

  @override
  DateTime start(int n) => DateTime(2080, 1 + n);

  @override
  String get unknownId => '00000000-0000-4000-8000-000000000000';

  @override
  Future<bool> closePeriod(Period p) async {
    _repo.closePeriod(p.id);
    return true;
  }

  @override
  Future<({String message, int? retryAfter})?> provokeSignInLimit(
    String email,
  ) async => null;

  @override
  bool get canTestLastManager => true;

  @override
  Future<void> dispose() async {}
}
