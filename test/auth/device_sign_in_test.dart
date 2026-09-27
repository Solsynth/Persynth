import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:persynth/auth/solar_auth_service.dart';

/// Answers the endpoints a device sign-in walks, in the order it walks them,
/// and records the paths it was asked for.
class _StubClient extends http.BaseClient {
  _StubClient(this._answers);

  final List<http.Response> _answers;
  final List<String> paths = [];

  /// The form fields of each request, in wire order.
  final List<Map<String, String>> bodies = [];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    paths.add(request.url.path);
    bodies.add(
      request is http.Request
          ? Uri.splitQueryString(request.body)
          : const <String, String>{},
    );
    if (_answers.isEmpty) {
      throw StateError('the stub was asked for more than it was given');
    }
    final answer = _answers.removeAt(0);
    return http.StreamedResponse(
      Stream.value(utf8.encode(answer.body)),
      answer.statusCode,
    );
  }
}

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status);

http.Response _discovery() => _json({
  'authorization_endpoint': 'https://id.example/auth/authorize',
  'token_endpoint': 'https://api.example/stargate/auth/open/token',
  'device_authorization_endpoint':
      'https://api.example/stargate/auth/open/device/code',
});

http.Response _deviceCode({int interval = 0}) => _json({
  'device_code': 'device-secret',
  'user_code': 'ABCD-EFGH',
  'verification_uri': 'https://id.example/auth/device',
  'verification_uri_complete': 'https://id.example/auth/device?code=ABCD-EFGH',
  'expires_in': 600,
  'interval': interval,
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // The session is written through the secure-storage channel; answer it so a
  // successful sign-in can be stored.
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async => null,
        );
  });

  test('a device sign-in is shown the code and polls until it is approved', () async {
    final client = _StubClient([
      _discovery(),
      _deviceCode(),
      // The user has not answered yet, twice, then does.
      _json({'error': 'authorization_pending'}, 400),
      _json({'error': 'authorization_pending'}, 400),
      _json({'access_token': 'access', 'refresh_token': 'refresh'}),
      _json({'nick': 'Michan', 'name': 'michan'}),
    ]);
    final shown = <SolarDeviceAuthorization>[];
    final service = SolarAuthService(client: client, isWeb: true);

    final user = await service.signIn(onDeviceCode: shown.add);

    expect(user.name, 'Michan');
    expect(shown, hasLength(1));
    expect(shown.single.userCode, 'ABCD-EFGH');
    expect(shown.single.verificationUri.toString(), 'https://id.example/auth/device');
    expect(
      shown.single.verificationUriComplete.queryParameters['code'],
      'ABCD-EFGH',
    );

    // Discovery, the code, two refusals to answer, the token, the account.
    expect(client.paths, [
      '/.well-known/openid-configuration',
      '/stargate/auth/open/device/code',
      '/stargate/auth/open/token',
      '/stargate/auth/open/token',
      '/stargate/auth/open/token',
      '/stargate/accounts/me',
    ]);
    expect(client.bodies[1], {'client_id': 'synthpet', 'scope': '*'});
    expect(client.bodies[4], {
      'grant_type': 'urn:ietf:params:oauth:grant-type:device_code',
      'device_code': 'device-secret',
      'client_id': 'synthpet',
    });
  });

  test('a code that is never approved fails rather than polling forever', () async {
    final client = _StubClient([
      _discovery(),
      _deviceCode(interval: 0),
      _json({'error': 'expired_token'}, 400),
    ]);
    final service = SolarAuthService(client: client, isWeb: true);

    await expectLater(
      service.signIn(),
      throwsA(
        isA<SolarAuthException>().having(
          (error) => error.message,
          'message',
          contains('expired'),
        ),
      ),
    );
    expect(client.paths.where((path) => path.endsWith('/token')), hasLength(1));
  });

  test('a declined sign-in reports the refusal', () async {
    final client = _StubClient([
      _discovery(),
      _deviceCode(interval: 0),
      _json({'error': 'access_denied'}, 400),
    ]);
    final service = SolarAuthService(client: client, isWeb: true);

    await expectLater(
      service.signIn(),
      throwsA(
        isA<SolarAuthException>().having(
          (error) => error.message,
          'message',
          contains('declined'),
        ),
      ),
    );
  });

  test('a deployment without a device endpoint says so', () async {
    final client = _StubClient([
      _json({
        'authorization_endpoint': 'https://id.example/auth/authorize',
        'token_endpoint': 'https://api.example/stargate/auth/open/token',
      }),
    ]);
    final service = SolarAuthService(client: client, isWeb: true);

    await expectLater(
      service.signIn(),
      throwsA(
        isA<SolarAuthException>().having(
          (error) => error.message,
          'message',
          contains('does not offer device sign-in'),
        ),
      ),
    );
    expect(client.paths, hasLength(1));
  });
}
