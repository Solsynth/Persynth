import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synth_pet/auth/solar_auth_service.dart';
import 'package:synth_pet/personality/personality_network.dart';

/// Serves canned [ResponseBody]s in order and records a snapshot of each
/// request's headers (the retried request reuses the same options object, so
/// a live reference would show the mutated header).
class _StubAdapter implements HttpClientAdapter {
  _StubAdapter(this._responses);

  final List<ResponseBody> _responses;
  final List<RequestOptions> requests = [];
  final List<Map<String, dynamic>> requestHeaders = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    requestHeaders.add(Map<String, dynamic>.from(options.headers));
    return _responses.removeAt(0);
  }

  @override
  void close({bool force = false}) {}
}

/// A session that starts stale and whose refresh either yields [next] (and
/// rotates `current`) or fails when [next] is null. [refreshDelay] models the
/// network latency of a real token exchange so concurrent 401s overlap.
class _FakeAuth extends SolarAuthService {
  String current = 'expired-token';
  String? next;
  int refreshCalls = 0;
  Duration refreshDelay = Duration.zero;

  @override
  Future<String?> accessToken() async => current;

  @override
  Future<String?> forceRefresh() async {
    refreshCalls++;
    final result = next;
    if (result != null && result.isNotEmpty) {
      if (refreshDelay > Duration.zero) {
        await Future<void>.delayed(refreshDelay);
      }
      current = result;
    }
    return result;
  }
}

ResponseBody _json(int status, String body) => ResponseBody.fromString(
  body,
  status,
  headers: {Headers.contentTypeHeader: ['application/json']},
);

String _authHeader(Map<String, dynamic> headers) {
  final value = headers['Authorization'];
  return value is String ? value : (value as List).join(',');
}

void main() {
  test('a 401 refreshes the token and retries once with it', () async {
    final adapter = _StubAdapter([
      _json(401, '{"detail":"expired"}'),
      _json(200, '{"ok":true}'),
    ]);
    final auth = _FakeAuth()..next = 'fresh-token';
    var expired = 0;
    final dio = buildPersonalityApiDio(
      serverUrl: 'https://x.solian.app',
      auth: auth,
      onAuthExpired: () => expired++,
    );
    dio.httpClientAdapter = adapter;

    final response = await dio.get('/personality/agents');

    expect(response.statusCode, 200);
    expect(adapter.requests, hasLength(2));
    expect(_authHeader(adapter.requestHeaders[0]), 'Bearer expired-token');
    expect(_authHeader(adapter.requestHeaders[1]), 'Bearer fresh-token');
    expect(auth.refreshCalls, 1);
    expect(expired, 0);
  });

  test('a failed refresh surfaces the 401 and flags the expired session', () async {
    final adapter = _StubAdapter([_json(401, '{"detail":"expired"}')]);
    final auth = _FakeAuth()..next = null;
    var expired = 0;
    final dio = buildPersonalityApiDio(
      serverUrl: 'https://x.solian.app',
      auth: auth,
      onAuthExpired: () => expired++,
    );
    dio.httpClientAdapter = adapter;

    await expectLater(
      dio.get('/personality/agents'),
      throwsA(
        isA<DioException>().having(
          (e) => e.response?.statusCode,
          'status',
          401,
        ),
      ),
    );
    expect(adapter.requests, hasLength(1));
    expect(auth.refreshCalls, 1);
    expect(expired, 1);
  });

  test('concurrent 401s share a single refresh', () async {
    final adapter = _StubAdapter([
      _json(401, '{"detail":"expired"}'),
      _json(401, '{"detail":"expired"}'),
      _json(401, '{"detail":"expired"}'),
      _json(200, '{"a":1}'),
      _json(200, '{"b":2}'),
      _json(200, '{"c":3}'),
    ]);
    final auth = _FakeAuth()
      ..next = 'fresh-token'
      ..refreshDelay = const Duration(milliseconds: 30);
    final dio = buildPersonalityApiDio(
      serverUrl: 'https://x.solian.app',
      auth: auth,
      onAuthExpired: () {},
    );
    dio.httpClientAdapter = adapter;

    final results = await Future.wait([
      dio.get('/a'),
      dio.get('/b'),
      dio.get('/c'),
    ]);

    expect(results.map((r) => r.statusCode), everyElement(200));
    expect(adapter.requests, hasLength(6));
    expect(auth.refreshCalls, 1);
  });

  test('a 404 passes through untouched', () async {
    final adapter = _StubAdapter([_json(404, '{"detail":"missing"}')]);
    final auth = _FakeAuth();
    var expired = 0;
    final dio = buildPersonalityApiDio(
      serverUrl: 'https://x.solian.app',
      auth: auth,
      onAuthExpired: () => expired++,
    );
    dio.httpClientAdapter = adapter;

    await expectLater(dio.get('/personality/agents'), throwsA(isA<DioException>()));
    expect(adapter.requests, hasLength(1));
    expect(auth.refreshCalls, 0);
    expect(expired, 0);
  });
}
