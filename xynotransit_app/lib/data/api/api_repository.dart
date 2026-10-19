import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show ValueNotifier;

import '../../domain/admin.dart';
import '../../domain/summary.dart';
import '../../domain/catalog.dart';
import '../../domain/enums.dart';
import '../../domain/deck.dart';
import '../../domain/deck_text.dart';
import '../../domain/period.dart';
import '../../domain/report.dart';
import '../../domain/text_rules.dart';
import '../repository.dart';
import 'api_client.dart';
import 'api_models.dart';
import 'sse.dart';

/// Talks to the axum API. Live data: any change message refetches, with a
/// polling fallback when the live connection is down.
class ApiRepository implements Repository {
  ApiRepository(
    this._api, {
    SseSource? sse,
    bool useDefaultSse = true,
    this.backoff = defaultBackoff,
    this.pollInterval = const Duration(seconds: 5),
    this.debounce = const Duration(milliseconds: 250),
  }) : _sse = sse ?? (useDefaultSse ? createPlatformSseSource() : null);

  final ApiClient _api;
  final SseSource? _sse;
  final Duration Function(int attempt) backoff;
  final Duration pollInterval;
  final Duration debounce;
  final _live = <String, LiveChanges>{};
  final _visibility = createPlatformVisibility();

  /// On while any watched period has live updates down for real.
  @override
  final ValueNotifier<bool> liveUpdatesPaused = ValueNotifier(false);

  void _syncPaused() =>
      liveUpdatesPaused.value = _live.values.any((l) => l.paused.value);

  Future<Object?> _catalogData(bool includeInactive) => _api.get(
    '/catalog',
    query: includeInactive ? {'include_inactive': 'true'} : null,
  );

  @override
  Future<Catalog> loadCatalog({bool includeInactive = false}) async =>
      parseCatalog(await _catalogData(includeInactive));

  /// A read whose last good answer is kept on this device. When the network is
  /// down the kept answer is used, so the app can still open and the form can
  /// still be filled in (sending waits in the queue). [fromCache] says which.
  Future<T> _cachedRead<T>(
    String key,
    Future<Object?> Function() fetch,
    T Function(Object?) parse, {
    void Function(bool fromCache)? onSource,
  }) async {
    try {
      final data = await fetch();
      final value = parse(data);
      try {
        await _api.tokens.cache(key, jsonEncode(data));
      } on Object {
        // A full or blocked store only costs the offline start.
      }
      onSource?.call(false);
      return value;
    } on NetworkException {
      final raw = _api.tokens.cached(key);
      if (raw == null) rethrow;
      try {
        final value = parse(jsonDecode(raw));
        onSource?.call(true);
        return value;
      } on Object {
        throw const NetworkException();
      }
    }
  }

  final _catalogChanged = StreamController<void>.broadcast();

  /// The catalog now, and again after every admin write made through this
  /// repository. A refetch that fails keeps the last value.
  @override
  Stream<Catalog> watchCatalog({bool includeInactive = false}) {
    late final StreamController<Catalog> out;
    StreamSubscription<void>? sub;
    var disposed = false;
    var busy = false;
    var dirty = false;

    Future<void> refetch() async {
      if (busy) {
        dirty = true;
        return;
      }
      busy = true;
      do {
        dirty = false;
        try {
          final c = await loadCatalog(includeInactive: includeInactive);
          if (!disposed) out.add(c);
        } on NetworkException {
          // Keep what we have.
        } on ApiException catch (e) {
          if (e is UnauthorizedException && !disposed) out.addError(e);
        }
      } while (dirty && !disposed);
      busy = false;
    }

    Timer? refresh;
    out = StreamController<Catalog>(
      onListen: () async {
        sub = _catalogChanged.stream.listen((_) => unawaited(refetch()));
        try {
          var stale = false;
          final first = await _cachedRead(
            includeInactive ? 'catalog/all' : 'catalog',
            () => _catalogData(includeInactive),
            parseCatalog,
            onSource: (fromCache) => stale = fromCache,
          );
          if (!disposed) out.add(first);
          // The first catalog came from this device: keep asking until the
          // server answers, then show the live one.
          if (stale && !disposed) {
            refresh = Timer.periodic(pollInterval, (t) async {
              try {
                final live = await loadCatalog(
                  includeInactive: includeInactive,
                );
                t.cancel();
                if (!disposed) out.add(live);
              } on Object {
                // Still offline: try again at the next tick.
              }
            });
          }
        } on Object catch (e) {
          if (disposed) return;
          out.addError(e);
          await out.close();
        }
      },
      onCancel: () {
        disposed = true;
        refresh?.cancel();
        return sub?.cancel();
      },
    );
    return out.stream;
  }

  Future<T> _written<T>(Future<T> write) async {
    final v = await write;
    _catalogChanged.add(null);
    return v;
  }

  @override
  Future<Period> ensurePeriod(DateTime startMonth) {
    final first = DateTime(startMonth.year, startMonth.month);
    return _cachedRead(
      'period/${Period.dateOnly(first)}',
      () => _api.post(
        '/periods/ensure',
        // Creating the period twice is the same as once.
        idempotent: true,
        body: {'start_month': Period.dateOnly(first)},
      ),
      parsePeriod,
    );
  }

  @override
  Future<void> setMeetingDate(String periodId, DateTime? date) async {
    await _api.patch(
      '/periods/$periodId',
      idempotent: true,
      body: {'meeting_date': date == null ? null : Period.dateOnly(date)},
    );
  }

  Future<List<Report>> _fetchReports(String periodId) async =>
      parseReports(await _api.get('/periods/$periodId/reports'));

  Future<DeckRun?> _fetchDeck(String periodId) async =>
      parseDeckOrNull(await _api.get('/periods/$periodId/deck'));

  LiveChanges _liveFor(String periodId) => _live.putIfAbsent(periodId, () {
    final l = LiveChanges(
      source: _sse,
      fetchTicket: () async {
        final j = asJson(await _api.post('/events/ticket'));
        return j['ticket'] as String;
      },
      buildUrl: (ticket) =>
          _api.uri('/events', {'ticket': ticket, 'period_id': periodId}),
      backoff: backoff,
      pollInterval: pollInterval,
      debounce: debounce,
      visibility: _visibility,
    );
    l.paused.addListener(_syncPaused);
    return l;
  });

  /// The first load may fail loudly. Later refetches keep the last value
  /// when they fail, and the next change or poll tries again. Refetches never
  /// overlap: a change during a fetch schedules one more fetch after it.
  Stream<T> _watch<T>(
    String periodId,
    LiveKind own,
    Future<T> Function() load,
  ) {
    late final StreamController<T> out;
    StreamSubscription<LiveKind>? sub;
    var disposed = false;
    var busy = false;
    var dirty = false;

    Future<void> refetch() async {
      if (busy) {
        dirty = true;
        return;
      }
      busy = true;
      do {
        dirty = false;
        try {
          final v = await load();
          if (!disposed) out.add(v);
        } on UnauthorizedException catch (e) {
          if (!disposed) out.addError(e);
        } on Exception {
          // Keep what we have; the next change or poll tries again.
        }
      } while (dirty && !disposed);
      busy = false;
    }

    Future<void> begin() async {
      try {
        final first = await load();
        if (disposed) return;
        out.add(first);
      } on Object catch (e) {
        if (disposed) return;
        out.addError(e);
        await out.close();
        return;
      }
      sub = _liveFor(periodId).stream.listen((kind) {
        if (kind == LiveKind.all || kind == own) unawaited(refetch());
      });
    }

    out = StreamController<T>(
      onListen: () => unawaited(begin()),
      onCancel: () {
        disposed = true;
        return sub?.cancel();
      },
    );
    return out.stream;
  }

  @override
  Stream<List<Report>> watchReports(String periodId) =>
      _watch(periodId, LiveKind.reports, () => _fetchReports(periodId));

  @override
  Future<Report?> getReport(String periodId, String assignmentId) async {
    try {
      return parseReport(
        await _api.get('/periods/$periodId/reports/$assignmentId'),
      );
    } on ApiException catch (e) {
      if (e.statusCode == 404) return null;
      rethrow;
    }
  }

  @override
  Future<Report> sendReport(Report report) async => parseReport(
    await _api.put(
      '/periods/${report.periodId}/reports/${report.assignmentId}',
      // Sending replaces the earlier report, so sending twice equals once.
      idempotent: true,
      body: reportToJson(report),
    ),
  );

  @override
  Stream<DeckRun?> watchDeck(String periodId) =>
      _watch(periodId, LiveKind.deck, () => _fetchDeck(periodId));

  @override
  Future<DeckRun> generateDeck(Period period, Catalog catalog) async =>
      parseDeck(await _api.post('/periods/${period.id}/deck'));

  // ---- Manager only: who reports, on what ----

  @override
  Future<Team> saveTeam({String? id, required String name}) =>
      _written(() async {
        final body = teamToJson(name);
        return parseTeam(
          id == null
              ? await _api.post('/teams', body: body)
              : await _api.patch('/teams/$id', body: body),
        );
      }());

  @override
  Future<void> deleteTeam(String id) => _written(_api.delete('/teams/$id'));

  @override
  Future<Person> savePerson({
    String? id,
    required String fullName,
    required String email,
    required AppRole role,
    bool active = true,
    String? username,
  }) => _written(() async {
    final body = personToJson(
      fullName: fullName,
      email: email,
      role: role,
      active: active,
      username: username,
    );
    if (id != null) {
      return parsePerson(await _api.patch('/persons/$id', body: body));
    }
    final created = parsePerson(
      await _api.post(
        '/persons',
        body: {
          'full_name': body['full_name'],
          if (body['email'] != null) 'email': body['email'],
          'app_role': body['app_role'],
          if (body['username'] != null) 'username': body['username'],
        },
      ),
    );
    if (active) return created;
    return parsePerson(
      await _api.patch('/persons/${created.id}', body: {'active': false}),
    );
  }());

  @override
  Future<TempPassword> resetPassword(String personId) => _written(() async {
    return parseTempPassword(
      await _api.post(
        '/persons/${Uri.encodeComponent(personId)}/password-reset',
        body: const <String, Object?>{},
      ),
    );
  }());

  @override
  Future<void> removePassword(String personId) => _written(
    _api.delete('/persons/${Uri.encodeComponent(personId)}/password'),
  );

  @override
  Future<SignInLink> createSignInLink(
    String personId, {
    int hours = 24,
    bool recovery = false,
  }) async => parseSignInLink(
    await _api.post(
      '/persons/${Uri.encodeComponent(personId)}/sign-in-link',
      body: {'hours': hours, 'recovery': recovery},
    ),
  );

  @override
  Future<Assignment> saveAssignment({
    String? id,
    required String personId,
    required String teamId,
    required String roleTitle,
    bool active = true,
  }) => _written(() async {
    if (id != null) {
      return parseAssignment(
        await _api.patch(
          '/assignments/$id',
          body: {
            'team_id': teamId,
            'role_title': trimText(plainSpaces(roleTitle)),
            'active': active,
          },
        ),
      );
    }
    final created = parseAssignment(
      await _api.post(
        '/assignments',
        body: assignmentToJson(
          personId: personId,
          teamId: teamId,
          roleTitle: roleTitle,
        ),
      ),
    );
    if (active) return created;
    return parseAssignment(
      await _api.patch('/assignments/${created.id}', body: {'active': false}),
    );
  }());

  @override
  Future<Assignment> saveDefinitions(
    String assignmentId, {
    required List<MetricInput> metrics,
    required List<KpiInput> kpis,
  }) => _written(
    _api
        .put(
          '/assignments/$assignmentId/definitions',
          body: definitionsToJson(metrics: metrics, kpis: kpis),
        )
        .then(parseAssignment),
  );

  @override
  Future<Summary> loadSummary(String periodId, {int trend = 6}) async =>
      parseSummary(
        await _api.get(
          '/summary',
          query: {'period_id': periodId, 'trend': '$trend'},
        ),
      );

  @override
  Future<DeckTextsState> loadDeckTexts(String periodId) => _cachedRead(
    'deck-text/$periodId',
    () => _api.get('/periods/$periodId/deck-text'),
    parseDeckTextsState,
  );

  @override
  Future<DeckTextsState> saveDeckTexts(
    String periodId,
    DeckTexts texts,
  ) async => parseDeckTextsState(
    await _api.put(
      '/periods/$periodId/deck-text',
      idempotent: true,
      body: {'settings': texts.toJson()},
    ),
  );
}
