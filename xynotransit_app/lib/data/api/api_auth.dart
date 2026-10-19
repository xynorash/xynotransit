import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;

import '../repository.dart';
import 'api_client.dart';
import 'api_models.dart';

/// Email magic link sign-in against the API. The token lives in
/// shared_preferences; the role shown in the UI is re-read from the server.
class ApiAuthService implements AuthService, LinkSignIn {
  ApiAuthService(this._api) {
    _api.onUnauthorized = expire;
    _api.onPasswordRequired = () {
      final u = _user;
      if (u != null && !u.mustChangePassword) {
        _set(u.copyWith(mustChangePassword: true));
      }
    };
  }

  final ApiClient _api;
  final _c = StreamController<AppUser?>.broadcast();
  AppUser? _user;

  TokenStore get _tokens => _api.tokens;

  /// The client, for tests that make a plain call with the token.
  @visibleForTesting
  ApiClient get testClient => _api;

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
    // A link session may choose a new password without the old one for a
    // few minutes; the server's /me below confirms it.
    await _startSession(j, viaLink: true);
    // The answer has no username; ask who we are (best effort).
    try {
      final me = parseUser(await _api.get('/me'));
      if (me.personId == _user?.personId) {
        await _keep(me);
      }
    } on Object {
      // Offline now? The sign-in stands; the name shows up on the next start.
    }
  }

  @override
  Future<void> signInWithPassword(String username, String password) async {
    final name = username.trim().toLowerCase();
    final j = asJson(
      await _api.post(
        '/auth/login',
        body: {'username': name, 'password': password},
        auth: false,
      ),
    );
    await _startSession(j, username: name);
  }

  @override
  Future<void> changePassword({
    String? currentPassword,
    required String newPassword,
  }) async {
    final j = asJson(
      await _api.post(
        '/auth/password',
        body: {
          'current_password': ?currentPassword,
          'new_password': newPassword,
        },
      ),
    );
    final access = j['access_token'];
    if (access is! String || access.isEmpty) {
      throw const RepositoryException(
        'The server sent an answer the app cannot read.',
      );
    }
    // The old token is dead now; swap in the fresh one before anything else.
    await _tokens.save(access);
    final u = _user;
    if (u != null) {
      await _keep(
        u.copyWith(
          hasPassword: true,
          mustChangePassword: false,
          recentLinkSession: false,
        ),
      );
    }
  }

  Future<void> _startSession(
    Map<String, Object?> j, {
    String? username,
    bool viaLink = false,
  }) async {
    final access = j['access_token'];
    if (access is! String || access.isEmpty) {
      throw const RepositoryException(
        'The server sent an answer the app cannot read.',
      );
    }
    var user = parseSessionUser(j, username: username);
    if (viaLink && user.hasPassword && j['recent_link_session'] != false) {
      user = user.copyWith(recentLinkSession: true);
    }
    await _tokens.save(access);
    await _keep(user);
  }

  Future<void> _keep(AppUser user) async {
    await _tokens.saveUser(jsonEncode(userToJson(user)));
    _set(user);
  }

  @override
  Future<void> signOut() async {
    await _tokens.clear();
    _set(null);
  }
}
