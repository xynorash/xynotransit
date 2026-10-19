import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../repository.dart';

/// The server refused with a status code. [message] is the server's own words.
class ApiException extends RepositoryException {
  const ApiException(this.statusCode, super.message);
  final int statusCode;
}

/// 401: not signed in, or the sign-in is no longer valid.
class UnauthorizedException extends ApiException {
  const UnauthorizedException(String message) : super(401, message);
}

/// Keeps the sign-in token in memory and in shared_preferences.
class TokenStore {
  TokenStore(this._prefs);
  final SharedPreferences _prefs;

  static const tokenKey = 'xt_access_token';
  static const userKey = 'xt_user';

  String? get token {
    final t = _prefs.getString(tokenKey);
    return (t == null || t.isEmpty) ? null : t;
  }

  Future<void> save(String token) => _prefs.setString(tokenKey, token);

  String? get cachedUser => _prefs.getString(userKey);
  Future<void> saveUser(String json) => _prefs.setString(userKey, json);

  /// Last good answers of a few reads, so the app can open without a network.
  /// They belong to the signed-in person and go when the sign-in goes.
  static const cachePrefix = 'xt_cache/';

  String? cached(String key) => _prefs.getString('$cachePrefix$key');

  Future<void> cache(String key, String json) =>
      _prefs.setString('$cachePrefix$key', json);

  Future<void> clear() async {
    await _prefs.remove(tokenKey);
    await _prefs.remove(userKey);
    for (final k in _prefs.getKeys().where((k) => k.startsWith(cachePrefix))) {
      await _prefs.remove(k);
    }
  }
}

/// The request got no answer in time. Worth one retry, not more: the server
/// is probably stuck, and every try costs a full [ApiClient.timeout].
class RequestTimeout extends NetworkException {
  const RequestTimeout() : super('The server took too long to answer.');
}

/// Plain words for an error status when the server sent no message.
String fallbackMessage(int status) => switch (status) {
  400 => 'Some of the input is not valid.',
  401 => 'Please sign in again.',
  403 => 'You are not allowed to do that.',
  404 => 'That was not found.',
  409 => 'Someone changed this at the same time. Reload and try again.',
  413 => 'That request is too large.',
  429 => 'Too many requests. Try again later.',
  _ => 'Something went wrong on the server. Try again in a moment.',
};

/// Statuses that say "the service is not there right now" (a proxy that cannot
/// reach the API, a restart, a timeout at the proxy) as opposed to "the service
/// refused". They are [NetworkException]s: safe to retry later, and the form
/// keeps what the person typed.
bool isUnreachableStatus(int status) =>
    status == 408 || status == 502 || status == 503 || status == 504;

/// Doubling pause before a retry: 300 ms, then 600 ms.
Duration defaultRetryDelay(int attempt) =>
    Duration(milliseconds: 300 << (attempt > 4 ? 4 : attempt));

/// Turns an error response into the exception the UI shows.
ApiException errorFromResponse(int status, String body) {
  String? message;
  try {
    final j = jsonDecode(body);
    if (j is Map && j['error'] is String) {
      final s = (j['error'] as String).trim();
      if (s.isNotEmpty) message = s;
    }
  } on FormatException {
    // Not JSON (an HTML error page from a proxy, say): use the fallback text.
  }
  message ??= fallbackMessage(status);
  return status == 401
      ? UnauthorizedException(message)
      : ApiException(status, message);
}

/// Thin JSON client: bearer token, error mapping, transport failures.
///
/// Failure classes, so callers can tell "try again later" from "no":
/// - [NetworkException]: no answer (offline, DNS, refused, reset, timeout) or a
///   gateway answer (408, 502, 503, 504, an HTML page from nginx). Nothing was
///   decided by the server.
/// - [UnauthorizedException]: 401. Cleared once per sign-in (see [onUnauthorized]).
/// - [ApiException]: the server answered and said no, with its own words.
/// - [RepositoryException]: a 2xx answer the app cannot read.
///
/// Calls that are safe to repeat (GET, and writes marked `idempotent`) are
/// retried after a [NetworkException] with a short pause. Everything else is
/// sent once: a repeated POST could do the thing twice.
class ApiClient {
  ApiClient({
    required this.baseUrl,
    required this.tokens,
    http.Client? client,
    this.timeout = const Duration(seconds: 20),
    this.maxAttempts = 3,
    this.retryDelay = defaultRetryDelay,
  }) : _http = client ?? http.Client();

  /// Without a trailing slash, for example `/api`.
  final String baseUrl;
  final TokenStore tokens;
  final Duration timeout;

  /// Tries for a repeatable call, the first one included.
  final int maxAttempts;
  final Duration Function(int attempt) retryDelay;
  final http.Client _http;

  /// Called after a 401 on a call that carried the token that is still the
  /// current one. A late 401 for an old token (the person signed in again
  /// meanwhile) is ignored, so a sign-in is never undone by a stale answer.
  void Function()? onUnauthorized;

  Uri uri(String path, [Map<String, String>? query]) {
    final base = baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
    final u = '$base$path';
    return Uri.parse(u).replace(queryParameters: query);
  }

  /// Decoded JSON body: a map, a list, a scalar, or null for `null` or an empty body.
  ///
  /// [idempotent] says that sending the same call twice has the same effect as
  /// once. It defaults to true for GET only.
  Future<Object?> request(
    String method,
    String path, {
    Object? body,
    Map<String, String>? query,
    bool auth = true,
    bool? idempotent,
  }) async {
    final repeatable = idempotent ?? method == 'GET';
    for (var attempt = 0; ; attempt++) {
      try {
        return await _once(method, path, body, query, auth);
      } on NetworkException catch (e) {
        final last =
            attempt + 1 >= maxAttempts || (e is RequestTimeout && attempt >= 1);
        if (!repeatable || last) rethrow;
        await Future<void>.delayed(retryDelay(attempt));
      }
    }
  }

  Future<Object?> _once(
    String method,
    String path,
    Object? body,
    Map<String, String>? query,
    bool auth,
  ) async {
    final req = http.Request(method, uri(path, query))
      ..headers['Accept'] = 'application/json';
    final token = auth ? tokens.token : null;
    if (token != null) req.headers['Authorization'] = 'Bearer $token';
    if (body != null) {
      req.headers['Content-Type'] = 'application/json';
      req.body = jsonEncode(body);
    }
    final http.Response res;
    try {
      res = await http.Response.fromStream(
        await _http.send(req).timeout(timeout),
      ).timeout(timeout);
    } on TimeoutException {
      throw const RequestTimeout();
    } on http.ClientException {
      throw const NetworkException();
    } on Exception {
      // Anything else that stops a request on its way (DNS, TLS, a reset
      // socket on dart:io) is the network, not a decision of the server.
      throw const NetworkException();
    }
    final bytes = res.bodyBytes;
    if (res.statusCode >= 400) {
      if (isUnreachableStatus(res.statusCode)) {
        throw const NetworkException(
          'The service is not reachable right now. Try again in a moment.',
        );
      }
      final err = errorFromResponse(
        res.statusCode,
        utf8.decode(bytes, allowMalformed: true),
      );
      if (err is UnauthorizedException &&
          token != null &&
          tokens.token == token) {
        onUnauthorized?.call();
      }
      throw err;
    }
    final text = utf8.decode(bytes, allowMalformed: true).trim();
    if (text.isEmpty) return null;
    try {
      return jsonDecode(text);
    } on FormatException {
      throw const RepositoryException(
        'The server sent an answer the app cannot read.',
      );
    }
  }

  Future<Object?> get(String path, {Map<String, String>? query}) =>
      request('GET', path, query: query);
  Future<Object?> post(
    String path, {
    Object? body,
    bool auth = true,
    bool idempotent = false,
  }) => request(
    'POST',
    path,
    body: body ?? const {},
    auth: auth,
    idempotent: idempotent,
  );
  Future<Object?> put(String path, {Object? body, bool idempotent = false}) =>
      request('PUT', path, body: body, idempotent: idempotent);
  Future<Object?> delete(String path) => request('DELETE', path);
  Future<Object?> patch(String path, {Object? body, bool idempotent = false}) =>
      request('PATCH', path, body: body, idempotent: idempotent);

  void close() => _http.close();
}
