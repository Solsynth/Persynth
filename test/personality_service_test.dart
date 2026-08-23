import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart';
import 'package:http/testing.dart';

import 'package:synth_pet/personality/personality_service.dart';

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
      'messages': [
        {'role': 'user', 'content': 'Say hello.'},
      ],
    });
    expect(reply, 'Stay soft, little sheep.');
  });

  test('relays reasoning and tool call SSE events', () async {
    final service = PersonalityCoreService(
      tokenResolver: () async => 'token-123',
      client: MockClient((incoming) async {
        return Response(
          [
            'event: reasoning.delta',
            'data: {"delta":"thinking..."}',
            '',
            'event: tool_call.delta',
            'data: {"id":"call-1","name":"remember","arguments":{"note":"buy milk"}}',
            '',
            'event: tool_call.completed',
            'data: {"id":"call-1","name":"remember","arguments":{"note":"buy milk"},"result":"Saved note: buy milk."}',
            '',
            'event: message.delta',
            'data: {"delta":"Done."}',
            '',
            'event: message.completed',
            'data: {"content":"Done.","message_id":"msg-1"}',
            '',
          ].join('\n'),
          200,
        );
      }),
    );

    final reasoning = <String>[];
    String? toolCallId;
    String? toolName;
    Map<String, dynamic>? toolArgs;
    String? toolResult;
    final reply = await service.runConversation(
      conversationId: 'thread-1',
      message: 'go',
      onReasoning: reasoning.add,
      onToolCall: (id, name, args) {
        toolCallId = id;
        toolName = name;
        toolArgs = args;
      },
      onToolResult: (id, name, args, result) {
        toolCallId = id;
        toolName = name;
        toolArgs = args;
        toolResult = result;
      },
    );

    expect(reasoning, ['thinking...']);
    expect(toolCallId, 'call-1');
    expect(toolName, 'remember');
    expect(toolArgs, {'note': 'buy milk'});
    expect(toolResult, 'Saved note: buy milk.');
    expect(reply, 'Done.');
  });

  test('creates a persisted conversation and relays run SSE deltas', () async {
    final requests = <Request>[];
    final service = PersonalityCoreService(
      tokenResolver: () async => 'token-123',
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

    final conversationId = await service.createConversation(agentId: 'mochi');
    final deltas = <String>[];
    final reply = await service.runConversation(
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
