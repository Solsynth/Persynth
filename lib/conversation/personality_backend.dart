import 'package:http/http.dart' as http;

import 'package:synth_pet/personality/personality_service.dart';

/// Transport-agnostic server-backed conversation surface.
abstract class ChatBackend {
  Future<String> createConversation({
    required String accessToken,
    required String agentId,
    String title = '',
    http.Client? client,
  });

  Future<String> runConversation({
    required String accessToken,
    required String conversationId,
    required String message,
    void Function(String delta)? onChunk,
    void Function(String name, Map<String, dynamic> args)? onToolCall,
    http.Client? client,
  });

  Future<List<PersonalityAgent>> listAgents({required String accessToken});
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
    required String accessToken,
    required String agentId,
    String title = '',
    http.Client? client,
  }) => _service.createConversation(
    accessToken: accessToken,
    agentId: agentId,
    title: title,
    client: client,
  );

  @override
  Future<String> runConversation({
    required String accessToken,
    required String conversationId,
    required String message,
    void Function(String delta)? onChunk,
    void Function(String name, Map<String, dynamic> args)? onToolCall,
    http.Client? client,
  }) => _service.runConversation(
    accessToken: accessToken,
    conversationId: conversationId,
    message: message,
    onChunk: onChunk,
    onToolCall: onToolCall,
    client: client,
  );

  @override
  Future<List<PersonalityAgent>> listAgents({required String accessToken}) =>
      _service.listAgents(accessToken: accessToken);
}
