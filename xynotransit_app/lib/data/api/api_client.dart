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

  Future<void> clear() async {
    await _prefs.remove(tokenKey);
    await _prefs.remove(userKey);
  }
}

/// Plain words for an error status when the server sent no message.
String fallbackMessage(int status) => switch (status) {
  400 => 'Some of the input is not valid.',
  401 => 'Please sign in again.',
  403 => 'You are not allowed to do that.',
  404 => 'That was not found.',
  409 => 'Someone changed this at the same time. Reload and try again.',
  429 => 'Too many requests. Try again later.',
  _ => 'Something went wrong on the server. Try again in a moment.',
};

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
    // Not JSON: use the fallback text.
  }
  message ??= fallbackMessage(status);
  return status == 401
      ? UnauthorizedException(message)
      : ApiException(status, message);
}

/// Thin JSON client: bearer token, error mapping, transport failures.
class ApiClient {
  ApiClient({
    required this.baseUrl,
    required this.tokens,
    http.Client? client,
    this.timeout = const Duration(seconds: 20),
  }) : _http = client ?? http.Client();

  /// Without a trailing slash, for example `/api`.
  final String baseUrl;
  final TokenStore tokens;
  final Duration timeout;
  final http.Client _http;

  /// Called after a 401 on a call that carried a token.
  void Function()? onUnauthorized;

  Uri uri(String path, [Map<String, String>? query]) {
    final base = baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
    final u = '$base$path';
    return Uri.parse(u).replace(queryParameters: query);
  }

  /// Decoded JSON body: a map, a list, a scalar, or null for `null` or an empty body.
  Future<Object?> request(
    String method,
    String path, {
    Object? body,
    Map<String, String>? query,
    bool auth = true,
  }) async {
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
    } on http.ClientException {
      throw const NetworkException();
    } on TimeoutException {
      throw const NetworkException();
    } on FormatException {
      throw const NetworkException();
    }
    if (res.statusCode >= 400) {
      final err = errorFromResponse(res.statusCode, utf8.decode(res.bodyBytes));
      if (err is UnauthorizedException && token != null) {
        onUnauthorized?.call();
      }
      throw err;
    }
    final text = utf8.decode(res.bodyBytes).trim();
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
  Future<Object?> post(String path, {Object? body, bool auth = true}) =>
      request('POST', path, body: body ?? const {}, auth: auth);
  Future<Object?> put(String path, {Object? body}) =>
      request('PUT', path, body: body);
  Future<Object?> delete(String path) => request('DELETE', path);
  Future<Object?> patch(String path, {Object? body}) =>
      request('PATCH', path, body: body);

  void close() => _http.close();
}
