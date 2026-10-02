import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart';
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

  test('uploads pasted text as a text file', () async {
    late Request captured;
    final service = PersonalityCoreService(
      tokenResolver: () async => 'token-123',
      client: MockClient((incoming) async {
        captured = incoming;
        return Response(jsonEncode({'id': 'file-text-1'}), 200);
      }),
    );

    final id = await service.uploadTextAttachment(
      name: 'Pasted text 2026-10-02 143005.txt',
      content: 'the quick brown fox',
    );

    expect(captured.url.path, '/drive/files/upload/direct');
    expect(id, 'file-text-1');
    // The drive decides the file is text from the part's name and type, which
    // is what makes the server inline it instead of treating it as an image.
    final body = latin1.decode(captured.bodyBytes);
    expect(body, contains('name="file"'));
    expect(body, contains('filename="Pasted text 2026-10-02 143005.txt"'));
    expect(body, contains('content-type: text/plain'));
    expect(body, contains('the quick brown fox'));
  });
}
