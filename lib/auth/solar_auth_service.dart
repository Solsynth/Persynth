import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';
import 'package:http/http.dart' as http;

/// What the user has to approve before a device-flow sign-in can finish: the
/// code, and the page that takes it. [verificationUriComplete] carries the code
/// in the URL, so opening it saves typing it.
@immutable
class SolarDeviceAuthorization {
  const SolarDeviceAuthorization({
    required this.userCode,
    required this.verificationUri,
    required this.verificationUriComplete,
    required this.expiresAt,
  });

  final String userCode;
  final Uri verificationUri;
  final Uri verificationUriComplete;
  final DateTime expiresAt;
}

class SolarUser {
  const SolarUser({
    required this.name,
    required this.handle,
    this.pictureId,
    this.pictureUrl,
  });

  final String name;
  final String handle;

  /// The drive file the profile uses as its picture, or null for an account
  /// that never set one.
  final String? pictureId;

  /// Where that file is served from, when the profile names a host of its own
  /// rather than the deployment's drive. Null means the app builds the drive
  /// URL itself.
  final String? pictureUrl;

  factory SolarUser.fromJson(Map<String, dynamic> json) {
    final displayName = json['nick']?.toString();
    // The profile's picture rides the same payload as the name: a drive file
    // reference the settings page draws as the account's avatar.
    final profile = json['profile'];
    final picture = profile is Map ? profile['picture'] : null;
    final pictureId = picture is Map ? picture['id']?.toString() : null;
    final pictureUrl = picture is Map ? picture['url']?.toString() : null;
    return SolarUser(
      name: displayName?.isNotEmpty == true
          ? displayName!
          : 'Solar Network user',
      handle: json['name']?.toString() ?? '',
      pictureId: pictureId == null || pictureId.isEmpty ? null : pictureId,
      pictureUrl: pictureUrl == null || pictureUrl.isEmpty ? null : pictureUrl,
    );
  }
}

class SolarAuthService {
  SolarAuthService({
    FlutterSecureStorage? storage,
    http.Client? client,
    bool? isWeb,
  }) : _storage = storage ?? const FlutterSecureStorage(),
       _client = client ?? http.Client(),
       _isWeb = isWeb ?? kIsWeb;

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

  /// The grant the web build signs in with: RFC 8628's device flow, which
  /// needs no callback at all. A browser cannot hand a custom scheme back to a
  /// page, and the package that could receive an HTTPS redirect needs a page
  /// on the app's own origin to forward it — a page and a registered redirect
  /// per origin, for a flow the provider already answers without either.
  static const deviceCodeGrant =
      'urn:ietf:params:oauth:grant-type:device_code';

  static const sessionKey = 'synthpet_solar_network_oauth_session';

  final FlutterSecureStorage _storage;
  final http.Client _client;

  /// Whether this build signs in with the device flow, which the web has to:
  /// nothing in a browser can hand the provider's callback back into the page.
  /// Injected rather than read from [kIsWeb] so a test can run either flow.
  final bool _isWeb;

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

  /// Signs in, returning the account.
  ///
  /// [onDeviceCode] is how the web build tells the user what to approve: the
  /// device flow has no callback to bounce through, so the provider hands out
  /// a code and the app polls until the user has entered it in a browser. The
  /// other platforms open a browser window and never call it.
  Future<SolarUser> signIn({
    void Function(SolarDeviceAuthorization authorization)? onDeviceCode,
  }) async {
    final session = _isWeb
        ? await _authorizeDevice(onDeviceCode)
        : await _authorize();
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
    final redirect = _redirect;
    final authorizationUrl = configuration.authorizationEndpoint.replace(
      queryParameters: {
        'response_type': 'code',
        'client_id': clientId,
        'redirect_uri': redirect.toString(),
        'scope': '*',
        'state': state,
        'code_challenge': challenge,
        'code_challenge_method': 'S256',
      },
    );
    final callback = Uri.parse(
      await FlutterWebAuth2.authenticate(
        url: authorizationUrl.toString(),
        // Unused on the web, where the package resolves the callback from the
        // origin the app runs on rather than from a scheme.
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
      'redirect_uri': redirect.toString(),
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

  /// Signs in with RFC 8628's device flow: take a code, hand it to the user,
  /// poll the token endpoint until they have approved it in a browser.
  ///
  /// This is the web's flow, and the reason is the redirect: nothing in a
  /// browser can hand the provider's callback back into the page, which is
  /// what the scheme and loopback redirects both assume. A code the user types
  /// on their own screen needs no callback at all.
  Future<_SolarSession> _authorizeDevice(
    void Function(SolarDeviceAuthorization authorization)? onDeviceCode,
  ) async {
    final configuration = await _discover();
    final endpoint = configuration.deviceAuthorizationEndpoint;
    if (!endpoint.hasScheme) {
      throw const SolarAuthException(
        'This Solar Network deployment does not offer device sign-in.',
      );
    }
    final response = await _client.post(
      endpoint,
      headers: {'Content-Type': 'application/x-www-form-urlencoded'},
      body: {'client_id': clientId, 'scope': '*'},
    );
    final body = _decode(response.body);
    _checkResponse(response.statusCode, body);
    if (body is! Map) {
      throw const SolarAuthException('Invalid device authorization response.');
    }
    final deviceCode = body['device_code']?.toString() ?? '';
    final userCode = body['user_code']?.toString() ?? '';
    final verificationUri = Uri.tryParse(
      body['verification_uri']?.toString() ?? '',
    );
    if (deviceCode.isEmpty ||
        userCode.isEmpty ||
        verificationUri == null ||
        !verificationUri.hasScheme) {
      throw const SolarAuthException('Invalid device authorization response.');
    }
    // The provider may send a URI that carries the code, which saves the user
    // typing it. Where it does not, the code itself is the whole instruction.
    final completeUri = Uri.tryParse(
      body['verification_uri_complete']?.toString() ?? '',
    );
    final expiresIn = (body['expires_in'] as num?)?.toInt() ?? 600;
    onDeviceCode?.call(
      SolarDeviceAuthorization(
        userCode: userCode,
        verificationUri: verificationUri,
        verificationUriComplete: completeUri != null && completeUri.hasScheme
            ? completeUri
            : verificationUri,
        expiresAt: DateTime.now().add(Duration(seconds: expiresIn)),
      ),
    );
    final session = await _awaitDeviceApproval(
      configuration.tokenEndpoint,
      deviceCode,
      interval: (body['interval'] as num?)?.toInt() ?? 5,
      deadline: DateTime.now().add(Duration(seconds: expiresIn)),
    );
    await _saveSession(session);
    return session;
  }

  /// Polls [tokenEndpoint] until the user has approved [deviceCode].
  ///
  /// RFC 8628's two "not yet" answers are not failures: `authorization_pending`
  /// means the user has not got there yet, `slow_down` means the provider
  /// wants the next poll further out. Anything else — approval, refusal, an
  /// expired code — is the answer, and the loop ends either way.
  Future<_SolarSession> _awaitDeviceApproval(
    Uri tokenEndpoint,
    String deviceCode, {
    required int interval,
    required DateTime deadline,
  }) async {
    var wait = interval;
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(Duration(seconds: wait));
      final response = await _client.post(
        tokenEndpoint,
        headers: {'Content-Type': 'application/x-www-form-urlencoded'},
        body: {
          'grant_type': deviceCodeGrant,
          'device_code': deviceCode,
          'client_id': clientId,
        },
      );
      final body = _decode(response.body);
      if (response.statusCode >= 200 && response.statusCode < 300) {
        return _sessionFrom(body);
      }
      final error = body is Map ? body['error']?.toString() : null;
      if (error == 'authorization_pending') continue;
      if (error == 'slow_down') {
        wait += 5;
        continue;
      }
      if (error == 'expired_token') {
        throw const SolarAuthException(
          'The sign-in code expired before it was approved. Try again.',
        );
      }
      if (error == 'access_denied') {
        throw const SolarAuthException('The sign-in was declined.');
      }
      _checkResponse(response.statusCode, body);
      throw SolarAuthException(
        'Solar Network sign-in failed (HTTP ${response.statusCode}).',
      );
    }
    throw const SolarAuthException(
      'The sign-in code expired before it was approved. Try again.',
    );
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
    return _sessionFrom(body, previous: previous);
  }

  /// The session a token response describes.
  _SolarSession _sessionFrom(Object? body, {_SolarSession? previous}) {
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
      Uri.parse(body['device_authorization_endpoint']?.toString() ?? ''),
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

  /// Where the provider returns the authorization code.
  ///
  /// Android, iOS and macOS answer the `synthpet` scheme; Windows and Linux
  /// cannot register one and listen on a loopback port instead. The web does
  /// neither — it never reaches this, because it signs in with the device flow
  /// in [_authorizeDevice].
  Uri get _redirect =>
      _usesLoopback ? Uri.parse(loopbackRedirectUri) : Uri.parse(redirectUri);

  String _randomUrlSafe(int length) => base64UrlEncode(
    List<int>.generate(length, (_) => Random.secure().nextInt(256)),
  ).replaceAll('=', '');
}

class _OidcConfiguration {
  const _OidcConfiguration(
    this.authorizationEndpoint,
    this.tokenEndpoint,
    this.deviceAuthorizationEndpoint,
  );

  final Uri authorizationEndpoint;
  final Uri tokenEndpoint;

  /// Where a device-flow sign-in asks for its code. Empty when the deployment
  /// does not offer one.
  final Uri deviceAuthorizationEndpoint;
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
