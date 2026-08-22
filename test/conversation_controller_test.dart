import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:synth_pet/conversation/conversation_compaction.dart';
import 'package:synth_pet/conversation/conversation_controller.dart';
import 'package:synth_pet/conversation/conversation_directive.dart';
import 'package:synth_pet/conversation/conversation_event.dart';
import 'package:synth_pet/conversation/conversation_message.dart';
import 'package:synth_pet/conversation/personality_backend.dart';
import 'package:synth_pet/personality/personality_service.dart';

class _StreamingBackend implements ChatBackend {
  int createCalls = 0;
  int runCalls = 0;
  List<String>? lastAttachmentIds;

  @override
  Future<String> createConversation({
    required String agentId,
    String title = '',
    http.Client? client,
  }) async {
    createCalls++;
    return 'conversation-1';
  }

  @override
  Future<String> runConversation({
    required String conversationId,
    required String message,
    List<String> attachmentIds = const [],
    void Function(String delta)? onChunk,
    void Function(String name, Map<String, dynamic> args)? onToolCall,
    http.Client? client,
  }) async {
    runCalls++;
    lastAttachmentIds = attachmentIds;
    onChunk?.call('Hi');
    onChunk?.call(' there!');
    return 'Hi there!';
  }

  @override
  Future<List<PersonalityAgent>> listAgents() async => const [];

  @override
  Future<List<PersonalityConversation>> listConversations({
    int take = 50,
    int offset = 0,
  }) async => const [];

  @override
  Future<List<PersonalityMessage>> listMessages({
    required String conversationId,
    int take = 200,
    int offset = 0,
  }) async => const [];

  @override
  Future<String> uploadAttachment({
    required String filePath,
    String? contentType,
  }) async => 'file-1';
}

class _NonStreamingBackend extends _StreamingBackend {
  @override
  Future<String> runConversation({
    required String conversationId,
    required String message,
    List<String> attachmentIds = const [],
    void Function(String delta)? onChunk,
    void Function(String name, Map<String, dynamic> args)? onToolCall,
    http.Client? client,
  }) async => 'Hello there friend';
}

/// Simulates a signed-out caller: the global identity provider has no token.
class _SignedOutBackend extends _StreamingBackend {
  @override
  Future<String> createConversation({
    required String agentId,
    String title = '',
    http.Client? client,
  }) =>
      throw const PersonalityCoreException('Sign in to start a conversation.');
}

class _HistoryBackend extends _StreamingBackend {
  @override
  Future<List<PersonalityMessage>> listMessages({
    required String conversationId,
    int take = 200,
    int offset = 0,
  }) async => [
    const PersonalityMessage(
      role: 'user',
      content: 'hello',
      attachmentIds: ['file-9'],
    ),
    const PersonalityMessage(role: 'assistant', content: 'hi there'),
  ];
}

void main() {
  group('ConversationController', () {
    test(
      'relays server chunks and reuses the persisted conversation',
      () async {
        final backend = _StreamingBackend();
        final controller = ConversationController(backend: backend);
        final events = <ConversationEvent>[];
        controller.events.listen(events.add);

        await controller.send('hello');
        await controller.send('again');

        expect(backend.createCalls, 1);
        expect(backend.runCalls, 2);
        expect(controller.conversationId, 'conversation-1');
        expect(events.whereType<ChunkReceived>().map((chunk) => chunk.delta), [
          'Hi',
          ' there!',
          'Hi',
          ' there!',
        ]);
        expect(
          events.whereType<MessageCompleted>().map((message) => message.text),
          ['Hi there!', 'Hi there!'],
        );
        expect(controller.messages.map((message) => message.role), [
          ConversationRole.user,
          ConversationRole.assistant,
          ConversationRole.user,
          ConversationRole.assistant,
        ]);
        expect(events.last, isA<StatusChanged>());
        expect((events.last as StatusChanged).busy, isFalse);
      },
    );

    test('emits an error when identity is unavailable', () async {
      final backend = _SignedOutBackend();
      final controller = ConversationController(backend: backend);
      final events = <ConversationEvent>[];
      controller.events.listen(events.add);

      await controller.send('hello');

      expect(controller.messages, isEmpty);
      expect(
        events.whereType<ErrorOccurred>().single.message,
        contains('Sign in'),
      );
    });

    test('reveals a non-streaming backend reply progressively', () async {
      final controller = ConversationController(
        backend: _NonStreamingBackend(),
      );
      final events = <ConversationEvent>[];
      controller.events.listen(events.add);

      await controller.send('hello');

      final chunks = events.whereType<ChunkReceived>().toList();
      expect(chunks, hasLength(greaterThan(1)));
      expect(
        events.whereType<MessageCompleted>().single.text,
        'Hello there friend',
      );
    });

    test('forwards attachment ids to the run and records them', () async {
      final backend = _StreamingBackend();
      final controller = ConversationController(backend: backend);
      final events = <ConversationEvent>[];
      controller.events.listen(events.add);

      await controller.send('look', attachmentIds: const ['file-1']);

      expect(backend.lastAttachmentIds, ['file-1']);
      expect(events.whereType<MessageCompleted>(), isNotEmpty);
      expect(controller.messages.first.attachmentIds, ['file-1']);
    });

    test(
      'openConversation loads history and emits ConversationOpened',
      () async {
        final controller = ConversationController(backend: _HistoryBackend());
        final events = <ConversationEvent>[];
        controller.events.listen(events.add);

        await controller.openConversation('conversation-1');

        expect(controller.conversationId, 'conversation-1');
        expect(controller.messages.map((m) => m.role), [
          ConversationRole.user,
          ConversationRole.assistant,
        ]);
        expect(controller.messages.first.attachmentIds, ['file-9']);
        expect(events.whereType<ConversationOpened>(), hasLength(1));

        controller.newConversation();
        expect(controller.conversationId, isNull);
        expect(controller.messages, isEmpty);
      },
    );
  });

  group('ConversationDirective.fromAssistantText', () {
    test('treats raw text as a plain reply with no tools', () {
      final directive = ConversationDirective.fromAssistantText(
        'Just chatting.',
      );
      expect(directive.reply, 'Just chatting.');
      expect(directive.toolCalls, isEmpty);
    });

    test('parses a JSON directive with tool calls', () {
      final directive = ConversationDirective.fromAssistantText(
        '{"reply":"Hi!","tools":[{"name":"remember","args":{"note":"buy milk"}}]}',
      );
      expect(directive.reply, 'Hi!');
      expect(directive.toolCalls, hasLength(1));
      expect(directive.toolCalls.first.name, 'remember');
      expect(directive.toolCalls.first.args, {'note': 'buy milk'});
    });

    test('parses a fenced json block', () {
      final directive = ConversationDirective.fromAssistantText(
        'Sure:\n```json\n{"reply":"ok","tools":[{"name":"clear","args":{}}]}\n```',
      );
      expect(directive.toolCalls.first.name, 'clear');
    });
  });

  group('CompactionPolicy', () {
    test('preserves the leading system message and trims oldest turns', () {
      final policy = CompactionPolicy(4);
      final messages = [
        ConversationMessage(ConversationRole.system, 'sys'),
        ConversationMessage(ConversationRole.user, 'u1'),
        ConversationMessage(ConversationRole.assistant, 'a1'),
        ConversationMessage(ConversationRole.user, 'u2'),
        ConversationMessage(ConversationRole.assistant, 'a2'),
        ConversationMessage(ConversationRole.user, 'u3'),
      ];
      final pruned = policy.apply(messages);
      expect(pruned.first.role, ConversationRole.system);
      expect(pruned.length, 4);
      expect(pruned.any((m) => m.content == 'u1'), isFalse);
      expect(pruned.any((m) => m.content == 'u3'), isTrue);
    });

    test('returns messages unchanged when under the limit', () {
      final policy = CompactionPolicy(40);
      final messages = [
        ConversationMessage(ConversationRole.system, 'sys'),
        ConversationMessage(ConversationRole.user, 'u1'),
      ];
      expect(policy.apply(messages), hasLength(2));
    });
  });
}
