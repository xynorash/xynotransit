import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart' show ValueNotifier;

import 'api_client.dart';
import 'sse_stub.dart' if (dart.library.js_interop) 'sse_web.dart' as platform;

/// What a live connection reports.
sealed class SseEvent {
  const SseEvent();
}

/// The connection is up.
class SseOpened extends SseEvent {
  const SseOpened();
}

/// One `data:` message.
class SseMessage extends SseEvent {
  const SseMessage(this.data);
  final String data;
}

/// Opens one Server-Sent Events connection. The stream emits [SseOpened] once
/// connected, then [SseMessage]s. It ends or errors when the connection drops;
/// it never reconnects by itself (a ticket works only once).
abstract class SseSource {
  Stream<SseEvent> open(Uri url);
}

/// The source for this platform, or null where there is none (polling only).
SseSource? createPlatformSseSource() => platform.createSseSource();

/// Whether the person can see the page. A hidden tab does not need a live
/// connection for ever.
abstract class PageVisibility {
  bool get visible;

  /// Fires with the new value when the page is shown or hidden.
  Stream<bool> get changes;
}

/// The visibility of this platform (always visible where there is no tab).
PageVisibility createPlatformVisibility() => platform.createVisibility();

/// Always visible, never changes. The default outside a browser and in tests.
class AlwaysVisible implements PageVisibility {
  const AlwaysVisible();
  @override
  bool get visible => true;
  @override
  Stream<bool> get changes => const Stream<bool>.empty();
}

/// What changed. [all] means "refetch everything": first connection,
/// reconnection, or a poll.
enum LiveKind {
  all,
  reports,
  deck;

  static LiveKind? tryParse(String? s) {
    for (final k in values) {
      if (k.name == s) return k;
    }
    return null;
  }
}

/// How long to wait before the next try, given how many tries in a row have
/// already failed. The first retry is immediate: a proxy that cuts a quiet
/// stream every 26 seconds is normal, not an outage. After that the delay
/// doubles from 1 s up to 15 s, with random jitter (half to full) so many
/// browsers do not come back at the same moment.
Duration defaultBackoff(int failures, [Random? random]) {
  if (failures <= 0) return Duration.zero;
  final seconds = min(15, 1 << min(failures - 1, 4));
  final ms = seconds * 1000;
  final r = random ?? _jitter;
  return Duration(milliseconds: ms ~/ 2 + r.nextInt(ms ~/ 2 + 1));
}

final _jitter = Random();

/// Change notifications for one period. Listen to [stream] and refetch when
/// it fires. Reconnects quietly with a new ticket each time: at once after a
/// normal cut, then with backoff while it keeps failing. While no connection
/// is up it falls back to a tick every [pollInterval]. Messages are debounced
/// by [debounce].
///
/// [paused] turns true after [pausedAfter] failed tries in a row and false
/// again once a connection has stayed up for [healthyAfter]. A connection that
/// opened and then lived long enough is a normal cut, not a failure.
///
/// While the page is hidden for longer than [hiddenGrace] the connection and
/// the polling stop; they start again, with a refetch, when it is shown.
class LiveChanges {
  LiveChanges({
    required this.source,
    required this.fetchTicket,
    required this.buildUrl,
    this.backoff = defaultBackoff,
    this.pollInterval = const Duration(seconds: 5),
    this.safetyInterval = const Duration(seconds: 60),
    this.debounce = const Duration(milliseconds: 250),
    this.healthyAfter = const Duration(seconds: 3),
    this.pausedAfter = 3,
    this.hiddenGrace = const Duration(minutes: 2),
    this.visibility = const AlwaysVisible(),
  }) {
    _controller = StreamController<LiveKind>.broadcast(
      onListen: _start,
      onCancel: _stop,
    );
  }

  /// Null when the platform has no SSE: the stream only polls.
  final SseSource? source;
  final Future<String> Function() fetchTicket;
  final Uri Function(String ticket) buildUrl;
  final Duration Function(int attempt) backoff;
  final Duration pollInterval;

  /// While the live connection is up, a slow tick still fires. A connection
  /// can die without a word (a laptop that slept, a proxy that dropped it
  /// quietly), and without this the view would stay stale for ever.
  final Duration safetyInterval;
  final Duration debounce;

  /// A connection that stays up this long counts as working.
  final Duration healthyAfter;

  /// Failed tries in a row before [paused] turns on.
  final int pausedAfter;

  /// How long a hidden page keeps its connection.
  final Duration hiddenGrace;
  final PageVisibility visibility;

  /// True when live updates are down for real (not a normal cut). The app
  /// shows a calm notice while it is true.
  final ValueNotifier<bool> paused = ValueNotifier(false);

  late final StreamController<LiveKind> _controller;
  Stream<LiveKind> get stream => _controller.stream;

  bool _running = false;
  int _generation = 0;
  Timer? _poll;
  Timer? _debounce;
  Timer? _wait;
  Completer<void>? _waiting;
  Completer<void>? _ended;
  Timer? _healthy;
  Timer? _hiddenTimer;
  StreamSubscription<bool>? _visSub;
  bool _suspended = false;
  int _failures = 0;
  StreamSubscription<SseEvent>? _sub;
  final _pending = <LiveKind>{};

  void _emit(LiveKind k) {
    if (!_controller.isClosed && _controller.hasListener) _controller.add(k);
  }

  void _start() {
    if (_running) return;
    _running = true;
    _suspended = false;
    _failures = 0;
    _visSub = visibility.changes.listen(_onVisible);
    if (!visibility.visible) _onVisible(false);
    if (!_suspended) _begin();
  }

  void _begin() {
    final gen = ++_generation;
    _startPolling();
    if (source != null) unawaited(_loop(gen));
  }

  void _stop() {
    _running = false;
    _suspended = false;
    _hiddenTimer?.cancel();
    _hiddenTimer = null;
    unawaited(_visSub?.cancel());
    _visSub = null;
    _halt();
    _failures = 0;
    paused.value = false;
  }

  /// Drops the connection, the timers and anything waiting.
  void _halt() {
    _generation++;
    _poll?.cancel();
    _poll = null;
    _debounce?.cancel();
    _debounce = null;
    _pending.clear();
    _healthy?.cancel();
    _healthy = null;
    unawaited(_sub?.cancel());
    _sub = null;
    _wait?.cancel();
    final e = _ended;
    if (e != null && !e.isCompleted) e.complete();
    final w = _waiting;
    _waiting = null;
    if (w != null && !w.isCompleted) w.complete();
  }

  void _onVisible(bool visible) {
    if (!_running) return;
    _hiddenTimer?.cancel();
    _hiddenTimer = null;
    if (!visible) {
      _hiddenTimer = Timer(hiddenGrace, () {
        if (!_running || _suspended) return;
        _suspended = true;
        _halt();
        _failures = 0;
        paused.value = false;
      });
    } else if (_suspended) {
      _suspended = false;
      _begin();
      // With a connection the open event refetches; polling-only needs it now.
      if (source == null) _emit(LiveKind.all);
    }
  }

  void _startPolling() => _tick(pollInterval);

  /// Connected: only the safety tick remains.
  void _stopPolling() => _tick(safetyInterval);

  void _tick(Duration every) {
    _poll?.cancel();
    _poll = Timer.periodic(every, (_) => _emit(LiveKind.all));
  }

  Future<void> _sleep(Duration d) {
    final c = Completer<void>();
    _waiting = c;
    _wait = Timer(d, () {
      if (!c.isCompleted) c.complete();
    });
    return c.future;
  }

  Future<void> _loop(int gen) async {
    while (_running && gen == _generation) {
      final ended = _ended = Completer<void>();
      var proved = false;
      try {
        final ticket = await fetchTicket();
        if (!_running || gen != _generation) return;
        _sub = source!
            .open(buildUrl(ticket))
            .listen(
              (e) {
                if (gen != _generation) return;
                switch (e) {
                  case SseOpened():
                    _stopPolling();
                    // Working only once it has stayed up for a while.
                    _healthy?.cancel();
                    _healthy = Timer(healthyAfter, () {
                      proved = true;
                      _failures = 0;
                      paused.value = false;
                    });
                    // Anything may have changed while we were away.
                    _emit(LiveKind.all);
                  case SseMessage(:final data):
                    _onMessage(data);
                }
              },
              onError: (Object _) {
                if (!ended.isCompleted) ended.complete();
              },
              onDone: () {
                if (!ended.isCompleted) ended.complete();
              },
              cancelOnError: true,
            );
        await ended.future;
      } on UnauthorizedException {
        // Signed out: nothing to watch any more.
        _poll?.cancel();
        _poll = null;
        paused.value = false;
        return;
      } on Object {
        // Ticket or connection failed: back off, keep polling meanwhile.
      }
      if (!_running || gen != _generation) return;
      // A connection that stayed up long enough already reset the count, so
      // a normal cut retries at once and shows nothing.
      _healthy?.cancel();
      _healthy = null;
      unawaited(_sub?.cancel());
      _sub = null;
      _startPolling();
      final delay = backoff(_failures);
      if (!proved) {
        _failures++;
        if (_failures >= pausedAfter) paused.value = true;
      }
      await _sleep(delay);
    }
  }

  void _onMessage(String data) {
    LiveKind? kind;
    try {
      final j = jsonDecode(data);
      if (j is Map) kind = LiveKind.tryParse(j['kind'] as String?);
    } on FormatException {
      // Unknown message: refetch everything.
    }
    _pending.add(kind ?? LiveKind.all);
    _debounce?.cancel();
    _debounce = Timer(debounce, () {
      final kinds = _pending.contains(LiveKind.all)
          ? {LiveKind.all}
          : {..._pending};
      _pending.clear();
      kinds.forEach(_emit);
    });
  }
}
