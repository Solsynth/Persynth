import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:persynth/personality/personality_api.dart';

/// A one-shot loopback server that records the body of the run request and
/// answers with a minimal run stream, so the client is exercised end to end:
/// real socket, real JSON, real SSE framing.
class _RunServer {
  _RunServer(this._server);

  final HttpServer _server;
  final List<Map<String, dynamic>> bodies = [];
  final List<String> paths = [];

  static Future<_RunServer> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final instance = _RunServer(server);
    server.listen(instance._handle);
    return instance;
  }

  String get baseUrl => 'http://127.0.0.1:${_server.port}';

  Future<void> _handle(HttpRequest request) async {
    paths.add(request.uri.path);
    final raw = await utf8.decoder.bind(request).join();
    bodies.add(
      raw.trim().isEmpty
          ? <String, dynamic>{}
          : Map<String, dynamic>.from(jsonDecode(raw) as Map),
    );
    request.response
      ..statusCode = 200
      ..headers.contentType = ContentType('text', 'event-stream')
      ..write('event: message.completed\ndata: {"content":"ok"}\n\n');
    await request.response.close();
  }

  Future<void> close() => _server.close(force: true);
}

void main() {
  test('the reasoning controls the caller states are what the run carries',
      () async {
    final server = await _RunServer.start();
    addTearDown(server.close);
    final api = PersonalityApi(Dio(BaseOptions(baseUrl: server.baseUrl)));

    await api
        .runConversation(
          conversationId: 'c1',
          message: 'hi',
          reasoningEffort: 'high',
        )
        .drain<void>();

    final body = server.bodies.single;
    expect(server.paths.single, '/personality/conversations/c1/runs');
    expect(body['reasoning_effort'], 'high');
    expect(body.containsKey('disable_reasoning'), isFalse);
  });

  test('turning thinking off sends the switch, not an effort', () async {
    final server = await _RunServer.start();
    addTearDown(server.close);
    final api = PersonalityApi(Dio(BaseOptions(baseUrl: server.baseUrl)));

    await api
        .runConversation(
          conversationId: 'c1',
          message: 'hi',
          disableReasoning: true,
        )
        .drain<void>();

    final body = server.bodies.single;
    expect(body['disable_reasoning'], isTrue);
    expect(body.containsKey('reasoning_effort'), isFalse);
  });

  test('an unstated preference leaves the request without reasoning keys',
      () async {
    final server = await _RunServer.start();
    addTearDown(server.close);
    final api = PersonalityApi(Dio(BaseOptions(baseUrl: server.baseUrl)));

    await api
        .runConversation(conversationId: 'c1', message: 'hi')
        .drain<void>();

    final body = server.bodies.single;
    expect(body.containsKey('reasoning_effort'), isFalse);
    expect(body.containsKey('disable_reasoning'), isFalse);
  });

  test('pasted text rides the run as a named text part', () async {
    final server = await _RunServer.start();
    addTearDown(server.close);
    final api = PersonalityApi(Dio(BaseOptions(baseUrl: server.baseUrl)));

    await api
        .runConversation(
          conversationId: 'c1',
          message: 'what does this say?',
          inputParts: [
            SnRunInputPart.text(
              'the whole document',
              name: 'Pasted text 2026-10-02 143005.txt',
            ),
          ],
        )
        .drain<void>();

    final body = server.bodies.single;
    expect(body['input_parts'], [
      {
        'type': 'text',
        'text': 'the whole document',
        'name': 'Pasted text 2026-10-02 143005.txt',
      },
    ]);
    // Nothing was uploaded: a text attachment has no drive id to send.
    expect(body.containsKey('attachment_ids'), isFalse);
  });
}
