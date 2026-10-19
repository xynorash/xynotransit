import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xynotransit_app/app/providers.dart';
import 'package:xynotransit_app/data/api/api_client.dart';
import 'package:xynotransit_app/data/memory_repository.dart';
import 'package:xynotransit_app/data/repository.dart';
import 'package:xynotransit_app/domain/catalog.dart';
import 'package:xynotransit_app/domain/enums.dart';
import 'package:xynotransit_app/domain/period.dart';
import 'package:xynotransit_app/domain/report.dart';
import 'package:xynotransit_app/domain/text_rules.dart';
import 'package:xynotransit_app/features/form/form_controller.dart';

import 'form_text_test.dart' show customCatalog;

class _Repo extends MemoryRepository {
  _Repo(Catalog c, this.auth)
    : super(
        catalog: c,
        currentUser: () => auth.currentUser ?? DemoAuth.controller,
      );
  final DemoAuth auth;
  Object? failWith;
  final sent = <Report>[];

  @override
  Future<Report> sendReport(Report report) async {
    final f = failWith;
    if (f != null) throw f;
    sent.add(report);
    return super.sendReport(report);
  }
}

class _Auth extends DemoAuth {
  _Auth(super.catalog);
  final users = StreamController<AppUser?>.broadcast();
  @override
  Stream<AppUser?> get userChanges async* {
    yield currentUser;
    yield* users.stream;
  }
}

final _start = MemoryRepository.demoStart;
String get _day => Period.dateOnly(_start);

Report _full(String id) => Report(
  periodId: 'p',
  assignmentId: id,
  values: {
    'm0': [1, 2, 3],
  },
  kpis: {
    'k1': const KpiResult(KpiStatus.met),
    'k2': const KpiResult(KpiStatus.met),
  },
  reporter: const Reporter(name: 'Ana', country: 'Team', role: 'Clerk'),
);

Future<({ProviderContainer c, _Repo repo, SharedPreferences prefs, _Auth auth})>
_setUp(Catalog catalog, {Map<String, Object> initial = const {}}) async {
  SharedPreferences.setMockInitialValues(initial);
  final prefs = await SharedPreferences.getInstance();
  final auth = _Auth(catalog);
  final repo = _Repo(catalog, auth);
  final c = ProviderContainer(
    overrides: [
      prefsProvider.overrideWithValue(prefs),
      repositoryProvider.overrideWithValue(repo),
      authServiceProvider.overrideWithValue(auth),
      initialStartProvider.overrideWithValue(_start),
    ],
  );
  addTearDown(c.dispose);
  c.listen(catalogProvider, (_, _) {});
  c.listen(periodProvider, (_, _) {});
  await c.read(catalogProvider.future);
  await c.read(periodProvider.future);
  return (c: c, repo: repo, prefs: prefs, auth: auth);
}

String _pending(Report r) => jsonEncode({
  'periodId': r.periodId,
  'assignmentId': r.assignmentId,
  'draft': r.toDraftJson(),
});

void main() {
  final key = 'pending/$_day/a';

  test('a queued report that still fits is sent and removed', () async {
    final s = await _setUp(
      customCatalog(1),
      initial: {key: _pending(_full('a'))},
    );
    await s.c.read(formControllerProvider.notifier).retryPending();
    expect(s.repo.sent, hasLength(1));
    expect(s.prefs.containsKey(key), isFalse);
  });

  test(
    'definitions changed while offline: kept as a draft, not sent',
    () async {
      // The report was queued for a seat with a count that is gone.
      final pid = (await _setUp(customCatalog(1))).c
          .read(periodProvider)
          .value!
          .id;
      final old =
          Report(
            periodId: pid,
            assignmentId: 'a',
            kpis: _full('a').kpis,
            reporter: _full('a').reporter,
          ).copyWith(
            values: {
              'm0': [1, 2, 3],
              'gone': [4, 5, 6],
            },
          );
      final s = await _setUp(customCatalog(1), initial: {key: _pending(old)});
      final ctl = s.c.read(formControllerProvider.notifier);
      await ctl.selectAssignment('a');
      await ctl.retryPending();
      expect(s.repo.sent, isEmpty);
      expect(s.prefs.containsKey(key), isFalse);
      final draft = jsonDecode(s.prefs.getString('draft/$_day/a')!) as Map;
      expect(jsonEncode(draft), isNot(contains('gone')));
      final st = s.c.read(formControllerProvider);
      expect(st.phase, isNot(SendPhase.sent));
      expect(st.notice, contains('no longer exist'));
    },
  );

  test('a new count with no number: kept as a draft with a notice', () async {
    final s = await _setUp(
      customCatalog(2),
      initial: {key: _pending(_full('a'))},
    );
    await s.c.read(formControllerProvider.notifier).retryPending();
    expect(s.repo.sent, isEmpty);
    expect(s.prefs.containsKey(key), isFalse);
    expect(s.prefs.containsKey('draft/$_day/a'), isTrue);
    // Opening the seat later still shows the words.
    final ctl = s.c.read(formControllerProvider.notifier);
    await ctl.selectAssignment('a');
    expect(s.c.read(formControllerProvider).notice, contains('not sent'));
  });

  test('NetworkException keeps the entry for the next try', () async {
    final s = await _setUp(
      customCatalog(1),
      initial: {key: _pending(_full('a'))},
    );
    s.repo.failWith = const NetworkException();
    final ctl = s.c.read(formControllerProvider.notifier);
    await ctl.retryPending();
    expect(s.prefs.containsKey(key), isTrue);
  });

  test(
    'UnauthorizedException keeps the entry and a sign in sends it',
    () async {
      final s = await _setUp(
        customCatalog(1),
        initial: {key: _pending(_full('a'))},
      );
      s.c.listen(formControllerProvider, (_, _) {});
      s.c.listen(userProvider, (_, _) {});
      s.repo.failWith = const UnauthorizedException('Sign in again.');
      await s.c.read(formControllerProvider.notifier).retryPending();
      expect(s.prefs.containsKey(key), isTrue);
      s.repo.failWith = null;
      s.auth.users.add(null);
      await Future<void>.delayed(Duration.zero);
      s.auth.users.add(DemoAuth.controller);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(s.repo.sent, hasLength(1));
      expect(s.prefs.containsKey(key), isFalse);
    },
  );

  test('RepositoryException drops the entry', () async {
    final s = await _setUp(
      customCatalog(1),
      initial: {key: _pending(_full('a'))},
    );
    s.repo.failWith = const RepositoryException('Refused.');
    await s.c.read(formControllerProvider.notifier).retryPending();
    expect(s.prefs.containsKey(key), isFalse);
  });

  test('a damaged entry is deleted and the others still go out', () async {
    final s = await _setUp(
      customCatalog(1),
      initial: {
        'pending/$_day/aaa': '{not json',
        'pending/$_day/bbb': '{"periodId":"p"}',
        key: _pending(_full('a')),
      },
    );
    await s.c.read(formControllerProvider.notifier).retryPending();
    expect(s.prefs.containsKey('pending/$_day/aaa'), isFalse);
    expect(s.prefs.containsKey('pending/$_day/bbb'), isFalse);
    expect(s.repo.sent, hasLength(1));
    expect(s.prefs.containsKey(key), isFalse);
  });

  group('comments count characters, not UTF-16 units', () {
    test('201 emoji are cut to 200 whole emoji', () async {
      final s = await _setUp(customCatalog(1));
      final ctl = s.c.read(formControllerProvider.notifier);
      await ctl.selectAssignment('a');
      ctl.setKpi('k1', KpiStatus.met);
      ctl.setKpiComment('k1', '\u{1F69A}' * 201);
      final text = s.c
          .read(formControllerProvider)
          .report!
          .kpis['k1']!
          .comment!;
      expect(charCount(text), 200);
      expect(text.length, 400);
      expect(text.runes.every((r) => r == 0x1F69A), isTrue);
    });

    test('comment typed before the status is cut the same way', () async {
      final s = await _setUp(customCatalog(1));
      final ctl = s.c.read(formControllerProvider.notifier);
      await ctl.selectAssignment('a');
      ctl.setKpiComment('k1', 'a${'\u{1F69A}' * 200}');
      ctl.setKpi('k1', KpiStatus.met);
      final text = s.c
          .read(formControllerProvider)
          .report!
          .kpis['k1']!
          .comment!;
      expect(charCount(text), 200);
      expect(text.endsWith('\u{1F69A}'), isTrue);
    });

    test('cutChars never leaves a lone surrogate', () {
      for (var n = 0; n < 6; n++) {
        final t = cutChars('a\u{1F69A}b\u{1F69A}c\u{1F69A}', n);
        expect(charCount(t), n);
        for (var i = 0; i < t.length; i++) {
          final u = t.codeUnitAt(i);
          if (u >= 0xD800 && u <= 0xDBFF) {
            expect(t.codeUnitAt(i + 1) & 0xFC00, 0xDC00);
          }
        }
      }
      expect(cutChars('abc', 10), 'abc');
      expect(cutChars('abc', 0), '');
    });
  });
}
