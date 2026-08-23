import 'package:http/http.dart' as http;

import 'package:synth_pet/personality/personality_service.dart';

/// Transport-agnostic server-backed conversation surface.
abstract class ChatBackend {
  Future<String> createConversation({
    required String agentId,
    String title = '',
    http.Client? client,
  });

  Future<String> runConversation({
    required String conversationId,
    required String message,
    List<String> attachmentIds = const [],
    void Function(String delta)? onChunk,
    void Function(String id, String name, Map<String, dynamic> args)?
    onToolCall,
    void Function(String id, String name, Map<String, dynamic> args,
        String result)? onToolResult,
    void Function(String delta)? onReasoning,
    http.Client? client,
  });

  Future<List<PersonalityAgent>> listAgents();

  Future<List<PersonalityConversation>> listConversations({
    int take = 50,
    int offset = 0,
  });

  Future<List<PersonalityMessage>> listMessages({
    required String conversationId,
    int take = 200,
    int offset = 0,
  });

  Future<String> uploadAttachment({
    required String filePath,
    String? contentType,
  });
}

/// Concrete [ChatBackend] backed by Personality Core's persisted conversation
/// and SSE run APIs.
class PersonalityCoreBackend implements ChatBackend {
  const PersonalityCoreBackend([
    this._service = const PersonalityCoreService(),
  ]);

  final PersonalityCoreService _service;

  @override
  Future<String> createConversation({
    required String agentId,
    String title = '',
    http.Client? client,
  }) => _service.createConversation(
    agentId: agentId,
    title: title,
    client: client,
  );

  @override
  Future<String> runConversation({
    required String conversationId,
    required String message,
    List<String> attachmentIds = const [],
    void Function(String delta)? onChunk,
    void Function(String id, String name, Map<String, dynamic> args)?
    onToolCall,
    void Function(String id, String name, Map<String, dynamic> args,
        String result)? onToolResult,
    void Function(String delta)? onReasoning,
    http.Client? client,
  }) => _service.runConversation(
    conversationId: conversationId,
    message: message,
    attachmentIds: attachmentIds,
    onChunk: onChunk,
    onToolCall: onToolCall,
    onToolResult: onToolResult,
    onReasoning: onReasoning,
    client: client,
  );

  @override
  Future<List<PersonalityAgent>> listAgents() => _service.listAgents();

  @override
  Future<List<PersonalityConversation>> listConversations({
    int take = 50,
    int offset = 0,
  }) => _service.listConversations(take: take, offset: offset);

  @override
  Future<List<PersonalityMessage>> listMessages({
    required String conversationId,
    int take = 200,
    int offset = 0,
  }) => _service.listMessages(
    conversationId: conversationId,
    take: take,
    offset: offset,
  );

  @override
  Future<String> uploadAttachment({
    required String filePath,
    String? contentType,
  }) => _service.uploadAttachment(filePath: filePath, contentType: contentType);
}
