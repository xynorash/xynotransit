import 'dart:async';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:xynotransit_app/data/api/api_client.dart';
import 'package:xynotransit_app/data/api/api_repository.dart';
import 'package:xynotransit_app/data/api/sse.dart';
import 'package:xynotransit_app/data/repository.dart';

import 'api_client_test.dart' show clientFor, json;

/// A connection the test drives by hand.
class FakeConn {
  FakeConn(this.url);
  final Uri url;
  final controller = StreamController<SseEvent>();
  bool cancelled = false;

  void open() => controller.add(const SseOpened());
  void message(String s) => controller.add(SseMessage(s));
  void drop() => controller.addError(StateError('lost'));
}

class FakeSource implements SseSource {
  final conns = <FakeConn>[];

  @override
  Stream<SseEvent> open(Uri url) {
    final c = FakeConn(url);
    conns.add(c);
    c.controller.onCancel = () => c.cancelled = true;
    return c.controller.stream;
  }
}

const tick = Duration(milliseconds: 10);

class _Top implements Random {
  @override
  int nextInt(int max) => max - 1;
  @override
  bool nextBool() => true;
  @override
  double nextDouble() => 0.999;
}

class _Low extends _Top {
  @override
  int nextInt(int max) => 0;
}

Future<void> settle([int ms = 60]) =>
    Future<void>.delayed(Duration(milliseconds: ms));

LiveChanges live(
  FakeSource src, {
  Future<String> Function()? ticket,
  List<Duration>? delays,
  Duration poll = const Duration(seconds: 1),
}) {
  var tickets = 0;
  return LiveChanges(
    source: src,
    fetchTicket: ticket ?? () async => 't${++tickets}',
    buildUrl: (t) => Uri.parse('/api/events?ticket=$t&period_id=p'),
    backoff: (a) {
      delays?.add(Duration(milliseconds: a));
      return tick;
    },
    pollInterval: poll,
    debounce: tick,
    healthyAfter: const Duration(milliseconds: 20),
  );
}

void main() {
  test('default backoff: at once first, then doubles, capped at 15 s', () {
    // Longest possible wait (random at its top) for each failure count.
    final top = _Top();
    expect(
      [for (var i = 0; i < 8; i++) defaultBackoff(i, top).inMilliseconds],
      [0, 1000, 2000, 4000, 8000, 15000, 15000, 15000],
    );
    // Jitter: never below half, never above the full delay.
    final low = _Low();
    expect(
      [for (var i = 0; i < 6; i++) defaultBackoff(i, low).inMilliseconds],
      [0, 500, 1000, 2000, 4000, 7500],
    );
  });

  test('connects with a fresh ticket and emits all once open', () async {
    final src = FakeSource();
    final l = live(src);
    final got = <LiveKind>[];
    final sub = l.stream.listen(got.add);
    await settle();
    expect(src.conns, hasLength(1));
    expect(src.conns.single.url.toString(), contains('ticket=t1'));
    src.conns.single.open();
    await settle();
    expect(got, [LiveKind.all]);
    await sub.cancel();
    expect(src.conns.single.cancelled, isTrue);
  });

  test('messages are debounced and typed', () async {
    final src = FakeSource();
    final l = live(src);
    final got = <LiveKind>[];
    final sub = l.stream.listen(got.add);
    await settle();
    final c = src.conns.single..open();
    await settle();
    got.clear();
    for (var i = 0; i < 5; i++) {
      c.message('{"kind":"reports","period_id":"p"}');
    }
    await settle();
    expect(got, [LiveKind.reports]);
    got.clear();
    c
      ..message('{"kind":"reports","period_id":"p"}')
      ..message('{"kind":"deck","period_id":"p"}');
    await settle();
    expect(got, unorderedEquals([LiveKind.reports, LiveKind.deck]));
    got.clear();
    c.message('not json');
    await settle();
    expect(got, [LiveKind.all]);
    await sub.cancel();
  });

  test('reconnects with backoff and a new ticket after a drop', () async {
    final src = FakeSource();
    final delays = <Duration>[];
    final l = live(src, delays: delays);
    final got = <LiveKind>[];
    final sub = l.stream.listen(got.add);
    await settle();
    src.conns[0].open();
    await settle();
    src.conns[0].drop();
    await settle();
    expect(src.conns, hasLength(2));
    expect(src.conns[1].url.toString(), contains('ticket=t2'));
    got.clear();
    src.conns[1].open();
    await settle();
    // Catch up on anything missed while away.
    expect(got, [LiveKind.all]);
    await sub.cancel();
  });

  test(
    'attempt counter grows while failing and resets after opening',
    () async {
      final src = FakeSource();
      final delays = <Duration>[];
      final l = live(src, delays: delays);
      final sub = l.stream.listen((_) {});
      await settle();
      for (var i = 0; i < 3; i++) {
        src.conns[i].drop();
        await settle();
      }
      expect(delays.map((d) => d.inMilliseconds), [0, 1, 2]);
      src.conns[3].open();
      await settle();
      src.conns[3].drop();
      await settle();
      expect(delays.last.inMilliseconds, 0);
      await sub.cancel();
    },
  );

  test('polls while down and stops polling while connected', () async {
    final src = FakeSource();
    final l = live(
      src,
      ticket: () => Completer<String>().future,
      poll: const Duration(milliseconds: 50),
    );
    final got = <LiveKind>[];
    final sub = l.stream.listen(got.add);
    await settle(220);
    expect(got.length, greaterThanOrEqualTo(3));
    expect(got.toSet(), {LiveKind.all});
    await sub.cancel();

    final src2 = FakeSource();
    final l2 = live(src2, poll: const Duration(milliseconds: 50));
    final got2 = <LiveKind>[];
    final sub2 = l2.stream.listen(got2.add);
    await settle();
    src2.conns.single.open();
    await settle();
    got2.clear();
    await settle(220);
    expect(got2, isEmpty);
    // Connection lost: polling resumes.
    src2.conns.single.drop();
    await settle(30);
    got2.clear();
    await settle(220);
    expect(got2, isNotEmpty);
    await sub2.cancel();
  });

  test('ticket failures retry with backoff', () async {
    final src = FakeSource();
    var n = 0;
    final l = live(
      src,
      ticket: () async {
        if (++n < 3) throw const NetworkException();
        return 'ok';
      },
    );
    final sub = l.stream.listen((_) {});
    await settle(150);
    expect(n, 3);
    expect(src.conns.single.url.toString(), contains('ticket=ok'));
    await sub.cancel();
  });

  test('unauthorized ticket stops the live loop', () async {
    final src = FakeSource();
    var n = 0;
    final l = live(
      src,
      ticket: () async {
        n++;
        throw const UnauthorizedException('Sign in.');
      },
    );
    final sub = l.stream.listen((_) {});
    await settle(150);
    expect(n, 1);
    await sub.cancel();
  });

  test('no source means polling only', () async {
    final l = LiveChanges(
      source: null,
      fetchTicket: () async => 'x',
      buildUrl: (_) => Uri(),
      pollInterval: const Duration(milliseconds: 20),
    );
    final got = <LiveKind>[];
    final sub = l.stream.listen(got.add);
    await settle(100);
    await sub.cancel();
    expect(got, isNotEmpty);
  });

  test('can be listened to again after cancel', () async {
    final src = FakeSource();
    final l = live(src);
    var sub = l.stream.listen((_) {});
    await settle();
    await sub.cancel();
    sub = l.stream.listen((_) {});
    await settle();
    expect(src.conns, hasLength(2));
    expect(src.conns[0].cancelled, isTrue);
    await sub.cancel();
  });

  test(
    'repository refetches on a live message and uses the ticket endpoint',
    () async {
      final src = FakeSource();
      var reports = 0;
      var decks = 0;
      final paths = <String>[];
      final repo = ApiRepository(
        await clientFor((r) async {
          paths.add('${r.method} ${r.url.path}');
          switch (r.url.path) {
            case '/api/events/ticket':
              return json({'ticket': 'tt'});
            case '/api/periods/p/reports':
              reports++;
              return json(<Object?>[]);
            case '/api/periods/p/deck':
              decks++;
              return http.Response('null', 200);
          }
          return json({}, 404);
        }, token: 'tok'),
        sse: src,
        pollInterval: const Duration(seconds: 30),
        debounce: tick,
        backoff: (_) => tick,
      );
      final rsub = repo.watchReports('p').listen((_) {});
      final dsub = repo.watchDeck('p').listen((_) {});
      await settle();
      expect(src.conns, hasLength(1), reason: 'one connection per period');
      expect(src.conns.single.url.toString(), contains('ticket=tt'));
      expect(src.conns.single.url.toString(), contains('period_id=p'));
      src.conns.single.open();
      await settle();
      final r0 = reports;
      final d0 = decks;
      src.conns.single.message('{"kind":"reports","period_id":"p"}');
      await settle();
      expect(reports, r0 + 1);
      expect(decks, d0);
      src.conns.single.message('{"kind":"deck","period_id":"p"}');
      await settle();
      expect(decks, d0 + 1);
      await rsub.cancel();
      await dsub.cancel();
      expect(src.conns.single.cancelled, isTrue);
    },
  );
}
