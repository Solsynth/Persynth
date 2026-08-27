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
      'server_tools': true,
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

  test('lists only pet agents and flags them', () async {
    late Request request;
    final service = PersonalityCoreService(
      tokenResolver: () async => 'token-123',
      client: MockClient((incoming) async {
        request = incoming;
        return Response(
          jsonEncode([
            {'id': 'mochi', 'name': 'Mochi', 'abilities': ['pet', 'memory']},
            {'id': 'assistant', 'name': 'Assistant', 'abilities': ['chat']},
          ]),
          200,
        );
      }),
    );

    final agents = await service.listAgents();

    expect(request.url.queryParameters['pet'], 'true');
    expect(agents, hasLength(2));
    expect(agents.first.isPet, isTrue);
    expect(agents.last.isPet, isFalse);
  });

  test('fetches pet affection and treats 404 as no session', () async {
    final requests = <Request>[];
    final service = PersonalityCoreService(
      tokenResolver: () async => 'token-123',
      client: MockClient((incoming) async {
        requests.add(incoming);
        if (incoming.url.path.endsWith('/pet/affection') &&
            incoming.url.queryParameters['agent_id'] == 'mochi') {
          return Response(
            jsonEncode({
              'agent_id': 'mochi',
              'affection': 62,
              'level': 'warm',
              'reason': 'The user gave me a treat.',
            }),
            200,
          );
        }
        return Response('{}', 404);
      }),
    );

    final affection = await service.getPetAffection(agentId: 'mochi');
    expect(affection, isNotNull);
    expect(affection!.affection, 62);
    expect(affection.level, 'warm');
    expect(affection.reason, 'The user gave me a treat.');
    expect(requests.first.url.path, '/personality/pet/affection');
    expect(requests.first.url.queryParameters['agent_id'], 'mochi');

    final missing = await service.getPetAffection(agentId: 'nobody');
    expect(missing, isNull);
  });

  test('deletes agent memories with DELETE', () async {
    late Request request;
    final service = PersonalityCoreService(
      tokenResolver: () async => 'token-123',
      client: MockClient((incoming) async {
        request = incoming;
        return Response('', 204);
      }),
    );

    await service.deleteAgentMemories(agentId: 'mochi');

    expect(request.method, 'DELETE');
    expect(request.url.path, '/personality/agents/mochi/memories');
  });
}
