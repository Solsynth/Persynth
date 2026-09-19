import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';
import 'package:http/http.dart' as http;

class SolarUser {
  const SolarUser({required this.name, required this.handle});

  final String name;
  final String handle;

  factory SolarUser.fromJson(Map<String, dynamic> json) {
    final displayName = json['nick']?.toString();
    return SolarUser(
      name: displayName?.isNotEmpty == true
          ? displayName!
          : 'Solar Network user',
      handle: json['name']?.toString() ?? '',
    );
  }
}

class SolarAuthService {
  SolarAuthService({FlutterSecureStorage? storage, http.Client? client})
    : _storage = storage ?? const FlutterSecureStorage(),
      _client = client ?? http.Client();

  static const apiBase = 'https://api.solian.app';
  static const clientId = String.fromEnvironment(
    'SOLAR_OAUTH_CLIENT_ID',
    defaultValue: 'synthpet',
  );
  static const callbackScheme = 'synthpet';
  static const redirectUri = '$callbackScheme://oauth/callback';
  static const loopbackPort = 42872;
  static const loopbackCallbackUrlScheme = 'http://127.0.0.1:$loopbackPort';
  static const loopbackRedirectUri =
      '$loopbackCallbackUrlScheme/oauth/callback';
  static const sessionKey = 'synthpet_solar_network_oauth_session';

  final FlutterSecureStorage _storage;
  final http.Client _client;

  Future<SolarUser?> currentUser() async {
    final session = await _validSession();
    if (session == null) return null;
    final response = await _client.get(
      Uri.parse('$apiBase/stargate/accounts/me'),
      headers: _authHeaders(session.accessToken),
    );
    final body = _decode(response.body);
    _checkResponse(response.statusCode, body);
    return body is Map
        ? SolarUser.fromJson(Map<String, dynamic>.from(body))
        : null;
  }

  Future<String?> accessToken() async => (await _validSession())?.accessToken;

  /// Exchanges the stored refresh token for a fresh access token regardless
  /// of the client-side expiry clock — used when the server rejects a request
  /// with 401. Returns the new access token, or null when there is no session,
  /// no refresh token, or the refresh failed (the unusable session is deleted
  /// so the user can sign in again).
  Future<String?> forceRefresh() async {
    try {
      final session = await _readSession();
      if (session == null) return null;
      final refreshToken = session.refreshToken;
      if (refreshToken == null || refreshToken.isEmpty) return null;
      final refreshed = await _exchange((await _discover()).tokenEndpoint, {
        'grant_type': 'refresh_token',
        'client_id': clientId,
        'refresh_token': refreshToken,
      }, previous: session);
      await _saveSession(refreshed);
      return refreshed.accessToken;
    } on SolarAuthException {
      try {
        await _deleteSession();
      } on SolarAuthException {
        // The session is already unusable.
      }
      return null;
    }
  }

  Future<SolarUser> signIn() async {
    final session = await _authorize();
    final user = await _currentUser(session);
    if (user == null) {
      throw const SolarAuthException('Unable to load the signed-in account.');
    }
    return user;
  }

  Future<void> signOut() => _deleteSession();

  Future<SolarUser?> _currentUser(_SolarSession session) async {
    final response = await _client.get(
      Uri.parse('$apiBase/stargate/accounts/me'),
      headers: _authHeaders(session.accessToken),
    );
    final body = _decode(response.body);
    _checkResponse(response.statusCode, body);
    return body is Map
        ? SolarUser.fromJson(Map<String, dynamic>.from(body))
        : null;
  }

  Future<_SolarSession> _authorize() async {
    final configuration = await _discover();
    final verifier = _randomUrlSafe(64);
    final state = _randomUrlSafe(32);
    final challenge = base64UrlEncode(
      sha256.convert(utf8.encode(verifier)).bytes,
    ).replaceAll('=', '');
    final useLoopback = _usesLoopback;
    final redirect = useLoopback ? loopbackRedirectUri : redirectUri;
    final authorizationUrl = configuration.authorizationEndpoint.replace(
      queryParameters: {
        'response_type': 'code',
        'client_id': clientId,
        'redirect_uri': redirect,
        'scope': '*',
        'state': state,
        'code_challenge': challenge,
        'code_challenge_method': 'S256',
      },
    );
    final callback = Uri.parse(
      await FlutterWebAuth2.authenticate(
        url: authorizationUrl.toString(),
        callbackUrlScheme: useLoopback
            ? loopbackCallbackUrlScheme
            : callbackScheme,
        options: useLoopback
            ? const FlutterWebAuth2Options(useWebview: false)
            : const FlutterWebAuth2Options(),
      ),
    );
    if (callback.queryParameters['state'] != state) {
      throw const SolarAuthException('OAuth state verification failed.');
    }
    final error = callback.queryParameters['error'];
    if (error != null) {
      throw SolarAuthException(
        callback.queryParameters['error_description'] ?? error,
      );
    }
    final code = callback.queryParameters['code'];
    if (code == null || code.isEmpty) {
      throw const SolarAuthException(
        'OAuth did not return an authorization code.',
      );
    }
    final session = await _exchange(configuration.tokenEndpoint, {
      'grant_type': 'authorization_code',
      'client_id': clientId,
      'code': code,
      'redirect_uri': redirect,
      'code_verifier': verifier,
    });
    await _saveSession(session);
    return session;
  }

  Future<_SolarSession?> _validSession() async {
    final session = await _readSession();
    if (session == null || !session.needsRefresh) return session;
    final refreshToken = session.refreshToken;
    if (refreshToken == null || refreshToken.isEmpty) {
      return null;
    }
    try {
      final refreshed = await _exchange((await _discover()).tokenEndpoint, {
        'grant_type': 'refresh_token',
        'client_id': clientId,
        'refresh_token': refreshToken,
      }, previous: session);
      await _saveSession(refreshed);
      return refreshed;
    } on SolarAuthException {
      try {
        await _deleteSession();
      } on SolarAuthException {
        // The expired session is already unusable.
      }
      return null;
    }
  }

  Future<_SolarSession> _exchange(
    Uri endpoint,
    Map<String, String> fields, {
    _SolarSession? previous,
  }) async {
    final response = await _client.post(
      endpoint,
      headers: {'Content-Type': 'application/x-www-form-urlencoded'},
      body: fields,
    );
    final body = _decode(response.body);
    _checkResponse(response.statusCode, body);
    if (body is! Map) {
      throw const SolarAuthException('Invalid OAuth token response.');
    }
    final accessToken = (body['access_token'] ?? body['token'])?.toString();
    if (accessToken == null || accessToken.isEmpty) {
      throw const SolarAuthException(
        'OAuth token response had no access token.',
      );
    }
    final expiresIn = body['expires_in'];
    return _SolarSession(
      accessToken: accessToken,
      refreshToken: body['refresh_token']?.toString() ?? previous?.refreshToken,
      expiresAt: expiresIn is num
          ? DateTime.now().add(Duration(seconds: expiresIn.toInt()))
          : null,
    );
  }

  Future<_OidcConfiguration> _discover() async {
    final response = await _client.get(
      Uri.parse('$apiBase/.well-known/openid-configuration'),
    );
    final body = _decode(response.body);
    _checkResponse(response.statusCode, body);
    if (body is! Map) {
      throw const SolarAuthException('Invalid OAuth discovery response.');
    }
    return _OidcConfiguration(
      Uri.parse(body['authorization_endpoint']?.toString() ?? ''),
      Uri.parse(body['token_endpoint']?.toString() ?? ''),
    );
  }

  Future<_SolarSession?> _readSession() async {
    late final String? raw;
    try {
      raw = await _storage.read(key: sessionKey);
    } on PlatformException catch (error) {
      throw _secureStorageException(error);
    }
    if (raw == null) return null;
    try {
      return _SolarSession.fromJson(
        Map<String, dynamic>.from(jsonDecode(raw) as Map),
      );
    } catch (_) {
      try {
        await _deleteSession();
      } on SolarAuthException {
        // The malformed session will be replaced on the next successful sign-in.
      }
      return null;
    }
  }

  Future<void> _saveSession(_SolarSession session) async {
    try {
      await _storage.write(
        key: sessionKey,
        value: jsonEncode(session.toJson()),
      );
    } on PlatformException catch (error) {
      throw _secureStorageException(error);
    }
  }

  Future<void> _deleteSession() async {
    try {
      await _storage.delete(key: sessionKey);
    } on PlatformException catch (error) {
      throw _secureStorageException(error);
    }
  }

  SolarAuthException _secureStorageException(PlatformException _) {
    return const SolarAuthException(
      'Secure session storage is unavailable. Please restart the app and try again.',
    );
  }

  Map<String, String> _authHeaders(String accessToken) => {
    'Authorization': 'Bearer $accessToken',
  };

  Object? _decode(String value) {
    try {
      return jsonDecode(value);
    } catch (_) {
      throw const SolarAuthException('Invalid Solar Network response.');
    }
  }

  void _checkResponse(int statusCode, Object? body) {
    if (statusCode >= 200 && statusCode < 300) return;
    if (body is Map) {
      final detail = body['detail'] ?? body['message'];
      if (detail != null && detail.toString().isNotEmpty) {
        throw SolarAuthException(detail.toString());
      }
    }
    throw SolarAuthException(
      'Solar Network request failed (HTTP $statusCode).',
    );
  }

  bool get _usesLoopback {
    return !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.windows ||
            defaultTargetPlatform == TargetPlatform.linux);
  }

  String _randomUrlSafe(int length) => base64UrlEncode(
    List<int>.generate(length, (_) => Random.secure().nextInt(256)),
  ).replaceAll('=', '');
}

class _OidcConfiguration {
  const _OidcConfiguration(this.authorizationEndpoint, this.tokenEndpoint);

  final Uri authorizationEndpoint;
  final Uri tokenEndpoint;
}

class _SolarSession {
  const _SolarSession({
    required this.accessToken,
    this.refreshToken,
    this.expiresAt,
  });

  final String accessToken;
  final String? refreshToken;
  final DateTime? expiresAt;

  bool get needsRefresh =>
      expiresAt != null &&
      DateTime.now().isAfter(expiresAt!.subtract(const Duration(minutes: 1)));

  Map<String, dynamic> toJson() => {
    'access_token': accessToken,
    'refresh_token': refreshToken,
    'expires_at': expiresAt?.toIso8601String(),
  };

  factory _SolarSession.fromJson(Map<String, dynamic> json) {
    return _SolarSession(
      accessToken: json['access_token']?.toString() ?? '',
      refreshToken: json['refresh_token']?.toString(),
      expiresAt: DateTime.tryParse(json['expires_at']?.toString() ?? ''),
    );
  }
}

class SolarAuthException implements Exception {
  const SolarAuthException(this.message);

  final String message;

  @override
  String toString() => message;
}
