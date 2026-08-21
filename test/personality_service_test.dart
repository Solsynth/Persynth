import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart';
import 'package:http/testing.dart';

import 'package:synth_pet/personality/personality_service.dart';

void main() {
  test('sends an OpenAI-compatible Personality Core chat request', () async {
    late Request request;
    final service = PersonalityCoreService(
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

    final reply = await service.chat(
      accessToken: 'token-123',
      agentId: 'mochi',
      prompt: 'Say hello.',
    );

    expect(
      request.url.toString(),
      endsWith('/personality/v1/chat/completions'),
    );
    expect(request.headers['authorization'], 'Bearer token-123');
    expect(jsonDecode(request.body), {
      'model': 'mochi',
      'stream': false,
      'messages': [
        {'role': 'user', 'content': 'Say hello.'},
      ],
    });
    expect(reply, 'Stay soft, little sheep.');
  });

  test('creates a persisted conversation and relays run SSE deltas', () async {
    final requests = <Request>[];
    final service = PersonalityCoreService(
      client: MockClient((incoming) async {
        requests.add(incoming);
        if (incoming.url.path.endsWith('/conversations')) {
          return Response(jsonEncode({'id': 'thread-1'}), 201);
        }
        return Response(
          [
            'event: run.started',
            'data: {"conversation_id":"thread-1"}',
            '',
            'event: message.delta',
            'data: {"delta":"Hello"}',
            '',
            'event: message.delta',
            'data: {"delta":" there"}',
            '',
            'event: message.completed',
            'data: {"content":"Hello there","message_id":"msg-1"}',
            '',
            'event: run.completed',
            'data: {"run_id":"run-1","message_id":"msg-1"}',
            '',
          ].join('\n'),
          200,
        );
      }),
    );

    final conversationId = await service.createConversation(
      accessToken: 'token-123',
      agentId: 'mochi',
    );
    final deltas = <String>[];
    final reply = await service.runConversation(
      accessToken: 'token-123',
      conversationId: conversationId,
      message: 'Say hello.',
      onChunk: deltas.add,
    );

    expect(conversationId, 'thread-1');
    expect(deltas, ['Hello', ' there']);
    expect(reply, 'Hello there');
    expect(requests[0].url.path, '/personality/conversations');
    expect(jsonDecode(requests[0].body), {'agent_id': 'mochi', 'title': ''});
    expect(requests[1].url.path, '/personality/conversations/thread-1/runs');
    expect(jsonDecode(requests[1].body), {
      'message': 'Say hello.',
      'stream': true,
    });
  });
}
