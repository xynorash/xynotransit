// The real API on the live stack, over real HTTP. Sign-in goes through the
// magic link that lands in Mailpit, exactly as a person does it.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xynotransit_app/data/api/api_auth.dart';
import 'package:xynotransit_app/data/api/api_client.dart';
import 'package:xynotransit_app/data/api/api_repository.dart';
import 'package:xynotransit_app/data/repository.dart';
import 'package:xynotransit_app/domain/catalog.dart';
import 'package:xynotransit_app/domain/enums.dart';
import 'package:xynotransit_app/domain/period.dart';

import 'arena.dart';

/// Where the live stack is, from `--dart-define=CONTRACT_API=http://127.0.0.1:8080`.
const contractApi = String.fromEnvironment('CONTRACT_API');

/// Mailpit, where the sign-in links arrive.
const contractMail = String.fromEnvironment(
  'CONTRACT_MAIL',
  defaultValue: 'http://127.0.0.1:8025',
);

/// The dev manager that creates the arena manager of each run.
const contractManager = String.fromEnvironment(
  'CONTRACT_MANAGER',
  defaultValue: 'shalini@xynotransit.example',
);

const _dbContainer = 'xynotransit-db-db-1';

/// Runs SQL in the dev database through docker. Null when docker or the
/// container is not there (the suite then cleans up by deactivating instead).
Future<String?> psql(String sql) async {
  try {
    final p = await Process.run('docker', [
      'exec',
      '-i',
      _dbContainer,
      'psql',
      '-U',
      'xynotransit',
      '-d',
      'xynotransit',
      '-v',
      'ON_ERROR_STOP=1',
      '-tA',
      '-c',
      sql,
    ]);
    if (p.exitCode != 0) return null;
    return (p.stdout as String).trim();
  } on Object {
    return null;
  }
}

class ApiSession {
  ApiSession(this.api, this.tokens, this.repo);
  final ApiClient api;
  final TokenStore tokens;
  final ApiRepository repo;
}

/// One run against the live stack: one tag for everything it creates.
class ApiRun {
  ApiRun._(this.tag, this._mail);

  final String tag;
  final http.Client _mail;
  final _clients = <ApiClient>[];
  final _sessions = <String, ApiSession>{};
  late final DateTime base;
  late ApiSession bossSession;
  late Person bossPerson;
  late bool sqlAvailable;

  static Future<ApiRun> start() async {
    final tag = (Random.secure().nextInt(0xffffff) + 0x1000000)
        .toRadixString(16)
        .substring(1);
    final run = ApiRun._(tag, http.Client());
    final r = Random();
    run.base = DateTime(2080 + r.nextInt(10), 1 + r.nextInt(12));
    run.sqlAvailable = await psql('select 1') == '1';
    // Anything an earlier run that was killed left behind.
    await run._signInManager();
    return run;
  }

  String get bossEmail => 'ct$tag-boss@contract.example';

  /// Signs in the dev manager, makes this run's own manager and signs in as
  /// that one, so the dev manager is used once per run.
  Future<void> _signInManager() async {
    final dev = await signIn(contractManager);
    final p = await dev.repo.savePerson(
      fullName: 'CT$tag Boss',
      email: bossEmail,
      role: AppRole.controller,
    );
    bossPerson = p;
    bossSession = await signIn(bossEmail);
  }

  Future<ApiSession> signIn(String email, {bool fresh = false}) async {
    final cached = _sessions[email];
    if (cached != null && !fresh) return cached;
    SharedPreferences.setMockInitialValues({});
    final tokens = TokenStore(await SharedPreferences.getInstance());
    final api = ApiClient(
      baseUrl: '$contractApi/api',
      tokens: tokens,
      timeout: const Duration(seconds: 20),
    );
    _clients.add(api);
    final auth = ApiAuthService(api);
    final since = DateTime.now().toUtc();
    try {
      await auth.signInWithEmail(email);
    } on RepositoryException catch (e) {
      if (e.message.contains('Too many links') && sqlAvailable) {
        await psql(
          "delete from login_attempt where email = '${email.replaceAll("'", '')}'",
        );
        await auth.signInWithEmail(email);
      } else {
        rethrow;
      }
    }
    final token = await _tokenFromMail(email, since);
    if (token == null) throw SignInRefused(email);
    await auth.exchangeToken(token);
    final s = ApiSession(
      api,
      tokens,
      ApiRepository(
        api,
        useDefaultSse: false,
        pollInterval: const Duration(milliseconds: 300),
        debounce: const Duration(milliseconds: 20),
      ),
    );
    _sessions[email] = s;
    return s;
  }

  /// Trades the token of a sign-in link (made by a manager) for a session.
  Future<ApiSession> signInWithLink(String url) async {
    final token = Uri.parse(url).queryParameters['token'];
    if (token == null) {
      throw const RepositoryException('The link has no token.');
    }
    SharedPreferences.setMockInitialValues({});
    final tokens = TokenStore(await SharedPreferences.getInstance());
    final api = ApiClient(
      baseUrl: '$contractApi/api',
      tokens: tokens,
      timeout: const Duration(seconds: 20),
    );
    _clients.add(api);
    await ApiAuthService(api).exchangeToken(token);
    return ApiSession(
      api,
      tokens,
      ApiRepository(
        api,
        useDefaultSse: false,
        pollInterval: const Duration(milliseconds: 300),
        debounce: const Duration(milliseconds: 20),
      ),
    );
  }

  /// The token in the newest link mailed to [email], or null when none comes.
  Future<String?> _tokenFromMail(String email, DateTime since) async {
    final deadline = DateTime.now().add(const Duration(seconds: 4));
    while (DateTime.now().isBefore(deadline)) {
      final res = await _mail.get(
        Uri.parse(
          '$contractMail/api/v1/search?query=${Uri.encodeQueryComponent('to:$email')}&limit=5',
        ),
      );
      final list =
          (jsonDecode(res.body) as Map<String, dynamic>)['messages']
              as List<dynamic>? ??
          const [];
      // Only a link mailed after we asked: older ones were used already.
      final fresh = [
        for (final m in list.cast<Map<String, dynamic>>())
          if (DateTime.parse(m['Created'] as String)
              .isAfter(since.subtract(const Duration(seconds: 1))))
            m,
      ];
      if (fresh.isNotEmpty) {
        final id = fresh.first['ID'] as String;
        final msg = await _mail.get(
          Uri.parse('$contractMail/api/v1/message/$id'),
        );
        final text =
            (jsonDecode(msg.body) as Map<String, dynamic>)['Text'] as String? ??
            '';
        final m = RegExp(r'token=([A-Za-z0-9_\-]+)').firstMatch(text);
        // Tidy the mailbox: the link is single use anyway.
        await _mail.delete(
          Uri.parse('$contractMail/api/v1/messages'),
          headers: {'content-type': 'application/json'},
          body: jsonEncode({
            'IDs': [id],
          }),
        );
        if (m != null) return m.group(1);
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    return null;
  }

  /// Removes what this run made. With SQL access everything goes; without
  /// it, people and seats are deactivated (teams and periods stay).
  Future<void> cleanUp() async {
    if (sqlAvailable) {
      final from = Period.dateOnly(base);
      final to = Period.dateOnly(DateTime(base.year, base.month + 100));
      await psql('''
begin;
set local xt.allow_deck_delete = 'on';
delete from deck_run_item where deck_run_id in (select id from deck_run where period_id in (select id from period where start_month >= '$from' and start_month < '$to'));
delete from deck_run where period_id in (select id from period where start_month >= '$from' and start_month < '$to');
delete from report where period_id in (select id from period where start_month >= '$from' and start_month < '$to')
  or assignment_id in (select a.id from assignment a join person p on p.id = a.person_id where p.email like 'ct$tag%@contract.example' or p.email like 'ct$tag%@xynotransit.internal');
delete from period where (start_month >= '$from' and start_month < '$to')
  or (start_month in ('2000-01-01', '2100-12-01') and not exists (select 1 from report r where r.period_id = period.id));
delete from assignment where person_id in (select id from person where email like 'ct$tag%@contract.example' or email like 'ct$tag%@xynotransit.internal');
delete from person where email like 'ct$tag%@contract.example' or email like 'ct$tag%@xynotransit.internal';
delete from team where name like 'CT$tag%';
delete from login_attempt where email like 'ct$tag%@contract.example';
commit;
''');
    } else {
      final boss = bossSession.repo;
      try {
        final c = await boss.loadCatalog(includeInactive: true);
        for (final a in c.assignments) {
          final p = c.personOf(a);
          if (p.email?.startsWith('ct$tag') ?? false) {
            await boss.saveAssignment(
              id: a.id,
              personId: a.personId,
              teamId: a.teamId,
              roleTitle: a.roleTitle,
              active: false,
            );
          }
        }
        for (final p in c.persons) {
          if ((p.email?.startsWith('ct$tag') ?? false) &&
              p.id != bossPerson.id) {
            await boss.savePerson(
              id: p.id,
              fullName: p.fullName,
              email: p.email!,
              role: AppRole.contributor,
              active: false,
            );
          }
        }
      } on Object {
        // Best effort.
      }
    }
    for (final c in _clients) {
      c.close();
    }
    _mail.close();
  }
}

class ApiArena implements Arena {
  ApiArena(this.run, this._n) : tag = '${run.tag}s$_n';
  final ApiRun run;
  @override
  final String tag;
  final int _n;

  @override
  Repository get boss => run.bossSession.repo;
  @override
  Person get bossPerson => run.bossPerson;

  @override
  Future<Repository> signInAs(String email, {bool fresh = false}) async =>
      (await run.signIn(email, fresh: fresh)).repo;

  @override
  Future<Repository> signInWithLink(String url) async =>
      (await run.signInWithLink(url)).repo;

  @override
  DateTime start(int n) => DateTime(run.base.year, run.base.month + _n * 4 + n);

  @override
  String get unknownId => '00000000-0000-4000-8000-000000000000';

  @override
  Future<bool> closePeriod(Period p) async {
    if (!run.sqlAvailable) return false;
    final out = await psql(
      "update period set status = 'closed' where id = '${p.id}' returning 1",
    );
    return out != null && out.startsWith('1');
  }

  @override
  Future<({String message, int? retryAfter})?> provokeSignInLimit(
    String email,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final api = ApiClient(
      baseUrl: '$contractApi/api',
      tokens: TokenStore(await SharedPreferences.getInstance()),
    );
    final auth = ApiAuthService(api);
    try {
      for (var i = 0; i < 12; i++) {
        try {
          await auth.signInWithEmail(email);
        } on ApiException catch (e) {
          if (e.statusCode != 429) rethrow;
          return (message: e.message, retryAfter: e.retryAfterSeconds);
        }
      }
      return null;
    } finally {
      api.close();
      if (run.sqlAvailable) {
        await psql(
          "delete from login_attempt where email = '${email.replaceAll("'", '')}'",
        );
      }
    }
  }

  // Other managers share this stack; the guard is proven by the API's own
  // Rust tests, which run on a database of their own.
  @override
  bool get canTestLastManager => false;

  @override
  Future<void> dispose() async {}
}
