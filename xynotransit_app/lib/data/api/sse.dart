import 'dart:async';
import 'dart:convert';

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

/// Doubling delay, 1 s up to 30 s.
Duration defaultBackoff(int attempt) {
  final seconds = 1 << (attempt.clamp(0, 5));
  return Duration(seconds: seconds > 30 ? 30 : seconds);
}

/// Change notifications for one period. Listen to [stream] and refetch when
/// it fires. Reconnects with backoff. While no connection is up it falls back
/// to a tick every [pollInterval]. Messages are debounced by [debounce].
class LiveChanges {
  LiveChanges({
    required this.source,
    required this.fetchTicket,
    required this.buildUrl,
    this.backoff = defaultBackoff,
    this.pollInterval = const Duration(seconds: 5),
    this.safetyInterval = const Duration(seconds: 60),
    this.debounce = const Duration(milliseconds: 250),
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

  late final StreamController<LiveKind> _controller;
  Stream<LiveKind> get stream => _controller.stream;

  bool _running = false;
  int _generation = 0;
  Timer? _poll;
  Timer? _debounce;
  Timer? _wait;
  Completer<void>? _waiting;
  Completer<void>? _ended;
  StreamSubscription<SseEvent>? _sub;
  final _pending = <LiveKind>{};

  void _emit(LiveKind k) {
    if (!_controller.isClosed && _controller.hasListener) _controller.add(k);
  }

  void _start() {
    if (_running) return;
    _running = true;
    final gen = ++_generation;
    _startPolling();
    if (source != null) unawaited(_loop(gen));
  }

  void _stop() {
    _running = false;
    _generation++;
    _poll?.cancel();
    _poll = null;
    _debounce?.cancel();
    _debounce = null;
    _pending.clear();
    unawaited(_sub?.cancel());
    _sub = null;
    _wait?.cancel();
    final e = _ended;
    if (e != null && !e.isCompleted) e.complete();
    final w = _waiting;
    _waiting = null;
    if (w != null && !w.isCompleted) w.complete();
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
    var attempt = 0;
    while (_running && gen == _generation) {
      final ended = _ended = Completer<void>();
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
                    attempt = 0;
                    _stopPolling();
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
        return;
      } on Object {
        // Ticket or connection failed: back off, keep polling meanwhile.
      }
      if (!_running || gen != _generation) return;
      unawaited(_sub?.cancel());
      _sub = null;
      _startPolling();
      await _sleep(backoff(attempt));
      attempt++;
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
