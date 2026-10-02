import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart';
import 'package:http/io_client.dart';
import 'package:http/testing.dart';

import 'package:persynth/personality/personality_service.dart';

void main() {
  test('sends an OpenAI-compatible Personality Core chat request', () async {
    late Request request;
    final service = PersonalityCoreService(
      tokenResolver: () async => 'token-123',
      client: MockClient((incoming) async {
        request = incoming;
        return Response(
          jsonEncode({
            'choices': [
              {
                'message': {'content': 'Stay soft, little sheep.'},
              },
            ],
          }),
          200,
        );
      }),
    );

    final reply = await service.chat(agentId: 'mochi', prompt: 'Say hello.');

    expect(
      request.url.toString(),
      endsWith('/personality/v1/chat/completions'),
    );
    expect(request.headers['authorization'], 'Bearer token-123');
    expect(jsonDecode(request.body), {
      'model': 'mochi',
      'stream': false,
      'server_tools': true,
      'messages': [
        {'role': 'user', 'content': 'Say hello.'},
      ],
    });
    expect(reply, 'Stay soft, little sheep.');
  });

  test('uploads a local file and returns the drive id', () async {
    late BaseRequest captured;
    final service = PersonalityCoreService(
      tokenResolver: () async => 'token-123',
      client: MockClient((incoming) async {
        captured = incoming;
        return Response(jsonEncode({'id': 'file-9'}), 200);
      }),
    );

    final id = await service.uploadAttachment(
      filePath: 'test/fixtures/pet_image.png',
    );

    expect(captured.method, 'POST');
    expect(captured.url.path, '/drive/files/upload/direct');
    expect(captured.headers['authorization'], 'Bearer token-123');
    expect(id, 'file-9');
  });

  test('reports the body as it goes, and says what the file is', () async {
    final reports = <List<int>>[];
    late Request captured;
    final service = PersonalityCoreService(
      tokenResolver: () async => 'token-123',
      client: MockClient((incoming) async {
        captured = incoming;
        return Response(jsonEncode({'id': 'file-9'}), 200);
      }),
    );

    await service.uploadAttachment(
      filePath: 'test/fixtures/pet_image.png',
      contentType: 'image/png',
      onProgress: (sent, total) => reports.add([sent, total]),
    );

    // The count runs to the whole body and never past it, which is what the
    // tile's bar is drawn from.
    expect(reports, isNotEmpty);
    final total = reports.last[1];
    expect(total, greaterThan(0));
    expect(reports.last[0], total);
    for (var i = 1; i < reports.length; i++) {
      expect(reports[i][0], greaterThanOrEqualTo(reports[i - 1][0]));
      expect(reports[i][0], lessThanOrEqualTo(total));
    }
    // The drive is told what it is storing, rather than left to guess.
    expect(latin1.decode(captured.bodyBytes), contains('image/png'));
  });

  test('an upload stops when the reader takes it back', () async {
    // A server that reads the body and never answers, so the upload is still
    // in flight when the abort lands.
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      try {
        await request.drain<void>();
      } on HttpException {
        // The reader hung up mid-body: what an aborted upload looks like from
        // the other end, and the point of the test.
      }
    });

    final service = PersonalityCoreService(
      tokenResolver: () async => 'token-123',
      client: IOClient(),
    );
    final abort = Completer<void>();
    var sawProgress = false;
    final upload = service.uploadAttachment(
      filePath: 'test/fixtures/pet_image.png',
      driveBaseUrl: 'http://127.0.0.1:${server.port}',
      onProgress: (sent, total) {
        sawProgress = true;
        if (!abort.isCompleted) abort.complete();
      },
      abortTrigger: abort.future,
    );

    await expectLater(upload, throwsA(isA<ClientException>()));
    // It was aborted mid-flight, not refused: the body had started to go.
    expect(sawProgress, isTrue);
  });
}
