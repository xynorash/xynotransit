import 'dart:async';
import 'dart:convert';

import '../repository.dart';
import 'api_client.dart';
import 'api_models.dart';

/// Email magic link sign-in against the API. The token lives in
/// shared_preferences; the role shown in the UI is re-read from the server.
class ApiAuthService implements AuthService, LinkSignIn {
  ApiAuthService(this._api) {
    _api.onUnauthorized = expire;
  }

  final ApiClient _api;
  final _c = StreamController<AppUser?>.broadcast();
  AppUser? _user;

  TokenStore get _tokens => _api.tokens;

  @override
  AppUser? get currentUser => _user;

  @override
  Stream<AppUser?> get userChanges async* {
    yield _user;
    yield* _c.stream;
  }

  @override
  bool get needsSignIn => true;

  void _set(AppUser? u) {
    _user = u;
    _c.add(u);
  }

  /// Picks up a saved sign-in at start. Offline, the last known person is
  /// used so the app still opens; a rejected token signs out.
  Future<void> restore() async {
    if (_tokens.token == null) return;
    try {
      final user = parseUser(await _api.get('/me'));
      await _tokens.saveUser(jsonEncode(userToJson(user)));
      _user = user;
    } on UnauthorizedException {
      await _tokens.clear();
      _user = null;
    } on NetworkException {
      _user = _cached();
    } on RepositoryException {
      _user = _cached();
    }
  }

  AppUser? _cached() {
    final s = _tokens.cachedUser;
    if (s == null) return null;
    try {
      return parseUser(jsonDecode(s));
    } on Object {
      return null;
    }
  }

  /// A call with our token came back 401: forget the sign-in. Once only:
  /// several calls in flight may all come back 401, and the person is told
  /// a single time.
  void expire() {
    if (_user == null && _tokens.token == null) return;
    final announce = _user != null;
    unawaited(_tokens.clear());
    _user = null;
    if (announce) _c.add(null);
  }

  @override
  Future<void> signInWithEmail(String email) async {
    await _api.post('/auth/magic-link', body: {'email': email}, auth: false);
  }

  @override
  Future<void> exchangeToken(String token) async {
    final j = asJson(
      await _api.post('/auth/verify', body: {'token': token}, auth: false),
    );
    final access = j['access_token'];
    if (access is! String || access.isEmpty) {
      throw const RepositoryException(
        'The server sent an answer the app cannot read.',
      );
    }
    final user = parseUser(j['user']);
    await _tokens.save(access);
    await _tokens.saveUser(jsonEncode(userToJson(user)));
    _set(user);
  }

  @override
  Future<void> signOut() async {
    await _tokens.clear();
    _set(null);
  }
}
