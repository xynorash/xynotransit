import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xynotransit_app/data/api/api_client.dart';
import 'package:xynotransit_app/data/api/sse.dart';

/// Reconnect behaviour behind a proxy that cuts a stream about every 26
/// seconds. All time is the test clock: nothing here really sleeps.

class Conn {
  Conn(this.url);
  final Uri url;
  final controller = StreamController<SseEvent>();
  bool cancelled = false;
  void open() => controller.add(const SseOpened());
  void drop() => controller.addError(StateError('cut'));
  void end() => unawaited(controller.close());
}

class Source implements SseSource {
  final conns = <Conn>[];
  @override
  Stream<SseEvent> open(Uri url) {
    final c = Conn(url);
    conns.add(c);
    c.controller.onCancel = () => c.cancelled = true;
    return c.controller.stream;
  }
}

class FakeVisibility implements PageVisibility {
  bool _visible = true;
  final _c = StreamController<bool>.broadcast();
  @override
  bool get visible => _visible;
  @override
  Stream<bool> get changes => _c.stream;
  void set(bool v) {
    _visible = v;
    _c.add(v);
  }
}

class Harness {
  Harness({
    this.failTickets = false,
    FakeVisibility? visibility,
    Duration poll = const Duration(hours: 1),
  }) {
    live = LiveChanges(
      source: src,
      fetchTicket: () async {
        tickets++;
        if (unauthorized) throw const UnauthorizedException('Sign in.');
        if (failTickets) throw StateError('offline');
        return 't$tickets';
      },
      buildUrl: (t) => Uri.parse('/api/events?ticket=$t'),
      backoff: (n) {
        delays.add(n);
        return Duration(seconds: n);
      },
      pollInterval: poll,
      safetyInterval: const Duration(hours: 2),
      debounce: const Duration(milliseconds: 10),
      visibility: visibility ?? const AlwaysVisible(),
    );
  }
  final src = Source();
  late final LiveChanges live;
  bool failTickets;
  bool unauthorized = false;
  int tickets = 0;
  final delays = <int>[];
  final got = <LiveKind>[];
  StreamSubscription<LiveKind>? sub;
  void listen() => sub = live.stream.listen(got.add);
}

/// Runs [body] on a fake clock. `pump(d)` moves the clock by d and lets
/// every waiting future run. Nothing sleeps for real.
void testFake(String name, void Function(void Function(Duration) pump) body) {
  test(name, () {
    fakeAsync((async) {
      body((d) => async.elapse(d));
    });
  });
}

void main() {
  testFake('a normal cut reconnects at once, quietly, with a new ticket and '
      'one refresh', (pump) {
    final h = Harness()..listen();
    pump(const Duration(milliseconds: 1));
    h.src.conns[0].open();
    pump(const Duration(seconds: 26));
    expect(h.live.paused.value, isFalse);
    h.got.clear();
    h.src.conns[0].drop();
    pump(const Duration(milliseconds: 1));
    // Immediate: no waiting at all.
    expect(h.src.conns, hasLength(2));
    expect(h.src.conns[1].url.toString(), contains('ticket=t2'));
    expect(h.delays.last, 0);
    h.src.conns[1].open();
    pump(const Duration(milliseconds: 1));
    expect(h.got, [LiveKind.all]);
    expect(h.live.paused.value, isFalse);
    h.sub!.cancel();
    pump(Duration.zero);
  });

  testFake('a stream that ends cleanly is treated like a cut', (pump) {
    final h = Harness()..listen();
    pump(const Duration(milliseconds: 1));
    h.src.conns[0].open();
    pump(const Duration(seconds: 26));
    h.src.conns[0].end();
    pump(const Duration(milliseconds: 1));
    expect(h.src.conns, hasLength(2));
    expect(h.live.paused.value, isFalse);
    h.sub!.cancel();
    pump(Duration.zero);
  });

  testFake('many normal cuts in a row never show the notice', (pump) {
    final h = Harness()..listen();
    pump(const Duration(milliseconds: 1));
    for (var i = 0; i < 10; i++) {
      h.src.conns[i].open();
      pump(const Duration(seconds: 26));
      h.src.conns[i].drop();
      pump(const Duration(milliseconds: 1));
      expect(h.live.paused.value, isFalse);
    }
    expect(h.src.conns, hasLength(11));
    expect(h.delays.every((d) => d == 0), isTrue);
    h.sub!.cancel();
    pump(Duration.zero);
  });

  testFake('failures back off, the notice shows only after 3 in a row, '
      'and goes away once a connection holds', (pump) {
    final h = Harness()..listen();
    pump(const Duration(milliseconds: 1));
    // Failure 1: retry at once.
    h.src.conns[0].drop();
    pump(const Duration(milliseconds: 1));
    expect(h.src.conns, hasLength(2));
    expect(h.live.paused.value, isFalse);
    // Failure 2: waits 1 s.
    h.src.conns[1].drop();
    pump(const Duration(milliseconds: 1));
    expect(h.src.conns, hasLength(2));
    expect(h.live.paused.value, isFalse);
    pump(const Duration(seconds: 1));
    expect(h.src.conns, hasLength(3));
    // Failure 3: now the notice shows.
    h.src.conns[2].drop();
    pump(const Duration(milliseconds: 1));
    expect(h.live.paused.value, isTrue);
    expect(h.delays, [0, 1, 2]);
    pump(const Duration(seconds: 2));
    expect(h.src.conns, hasLength(4));
    // A connection that opens but is gone at once is still a failure.
    h.src.conns[3].open();
    pump(const Duration(milliseconds: 100));
    expect(h.live.paused.value, isTrue);
    // One that stays up counts as working.
    pump(const Duration(seconds: 4));
    expect(h.live.paused.value, isFalse);
    h.src.conns[3].drop();
    pump(const Duration(milliseconds: 1));
    expect(h.delays.last, 0);
    h.sub!.cancel();
    pump(Duration.zero);
  });

  testFake('ticket failures count too', (pump) {
    final h = Harness(failTickets: true)..listen();
    pump(const Duration(milliseconds: 1));
    expect(h.live.paused.value, isFalse);
    pump(const Duration(seconds: 1));
    pump(const Duration(seconds: 2));
    expect(h.live.paused.value, isTrue);
    expect(h.src.conns, isEmpty);
    h.failTickets = false;
    pump(const Duration(seconds: 4));
    expect(h.src.conns, hasLength(1));
    h.sub!.cancel();
    pump(Duration.zero);
  });

  testFake('signed out: stops retrying and shows nothing', (pump) {
    final h = Harness()..listen();
    pump(const Duration(milliseconds: 1));
    h.src.conns[0].open();
    pump(const Duration(seconds: 26));
    h.unauthorized = true;
    h.src.conns[0].drop();
    pump(const Duration(minutes: 5));
    expect(h.tickets, 2);
    expect(h.src.conns, hasLength(1));
    expect(h.live.paused.value, isFalse);
    h.sub!.cancel();
    pump(Duration.zero);
  });

  testFake('hidden for long: stops, and resumes with a refresh when shown', (
    pump,
  ) {
    final vis = FakeVisibility();
    final h = Harness(visibility: vis)..listen();
    pump(const Duration(milliseconds: 1));
    h.src.conns[0].open();
    pump(const Duration(seconds: 5));
    vis.set(false);
    // A short stay in the background keeps the connection and reconnects.
    pump(const Duration(seconds: 30));
    h.src.conns[0].drop();
    pump(const Duration(milliseconds: 1));
    expect(h.src.conns, hasLength(2));
    // Past the grace period everything stops.
    pump(const Duration(minutes: 3));
    expect(h.src.conns[1].cancelled, isTrue);
    final before = h.tickets;
    pump(const Duration(minutes: 30));
    expect(h.tickets, before);
    h.got.clear();
    vis.set(true);
    pump(const Duration(milliseconds: 1));
    expect(h.tickets, before + 1);
    h.src.conns.last.open();
    pump(const Duration(milliseconds: 20));
    expect(h.got, [LiveKind.all]);
    h.sub!.cancel();
    pump(Duration.zero);
  });

  testFake('shown again before the grace period: nothing restarts', (pump) {
    final vis = FakeVisibility();
    final h = Harness(visibility: vis)..listen();
    pump(const Duration(milliseconds: 1));
    h.src.conns[0].open();
    pump(const Duration(seconds: 5));
    vis.set(false);
    pump(const Duration(seconds: 60));
    vis.set(true);
    pump(const Duration(minutes: 5));
    expect(h.src.conns, hasLength(1));
    expect(h.src.conns[0].cancelled, isFalse);
    h.sub!.cancel();
    pump(Duration.zero);
  });

  testFake('a page that starts hidden waits until it is shown', (pump) {
    final vis = FakeVisibility().._visible = false;
    final h = Harness(visibility: vis)..listen();
    pump(const Duration(minutes: 10));
    // Starts hidden: connects, then gives up after the grace period.
    expect(h.src.conns.length, lessThanOrEqualTo(1));
    final n = h.tickets;
    pump(const Duration(minutes: 10));
    expect(h.tickets, n);
    vis.set(true);
    pump(const Duration(milliseconds: 1));
    expect(h.tickets, n + 1);
    h.sub!.cancel();
    pump(Duration.zero);
  });
}
