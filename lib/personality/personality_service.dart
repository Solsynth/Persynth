import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart' show MediaType;

import 'package:synth_pet/auth/solar_auth_service.dart';

class PersonalityAgent {
  const PersonalityAgent({
    required this.id,
    required this.name,
    required this.description,
    this.isPet = false,
  });

  final String id;
  final String name;
  final String description;
  final bool isPet;

  String get displayName => name.isEmpty ? 'Unnamed agent' : name;

  factory PersonalityAgent.fromJson(Map<String, dynamic> json) {
    return PersonalityAgent(
      id: json['id']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      description: json['description']?.toString() ?? '',
      isPet: json['is_pet'] == true || json['abilities'] is List &&
          (json['abilities'] as List).contains('pet'),
    );
  }
}

/// A pet agent's affection state for the signed-in account.
class PetAffection {
  const PetAffection({
    required this.agentId,
    required this.affection,
    required this.level,
    this.reason,
  });

  final String agentId;
  final int affection;
  final String level;
  final String? reason;

  /// A stable 0-100 score; the server clamps it.
  double get fraction => (affection / 100).clamp(0, 1);

  factory PetAffection.fromJson(Map<String, dynamic> json) {
    final reason = json['reason']?.toString();
    return PetAffection(
      agentId: json['agent_id']?.toString() ?? '',
      affection: (json['affection'] as num?)?.toInt() ?? 50,
      level: json['level']?.toString() ?? 'familiar',
      reason: reason == null || reason.trim().isEmpty ? null : reason.trim(),
    );
  }
}

/// A persisted conversation thread on Personality Core.
class PersonalityConversation {
  const PersonalityConversation({
    required this.id,
    required this.agentId,
    required this.title,
    this.lastMessageAt,
  });

  final String id;
  final String agentId;
  final String title;
  final DateTime? lastMessageAt;

  String get displayName => title.trim().isEmpty ? 'Untitled' : title.trim();

  factory PersonalityConversation.fromJson(Map<String, dynamic> json) {
    final lastMessageAt = json['last_message_at']?.toString();
    return PersonalityConversation(
      id: json['id']?.toString() ?? '',
      agentId: json['agent_id']?.toString() ?? '',
      title: json['title']?.toString() ?? '',
      lastMessageAt: lastMessageAt == null || lastMessageAt.isEmpty
          ? null
          : DateTime.tryParse(lastMessageAt),
    );
  }
}

/// A persisted message loaded from a conversation's history.
class PersonalityMessage {
  const PersonalityMessage({
    required this.role,
    required this.content,
    this.attachmentIds = const [],
    this.reasoningContent,
    this.toolCalls = const [],
    this.toolCallId,
    this.toolName,
  });

  final String role;
  final String content;
  final List<String> attachmentIds;

  /// Assistant-only: the model's reasoning captured at generation time.
  final String? reasoningContent;

  /// Assistant-only: tool calls requested by this message.
  final List<PersonalityToolCall> toolCalls;

  /// Tool-role messages only.
  final String? toolCallId;
  final String? toolName;

  factory PersonalityMessage.fromJson(Map<String, dynamic> json) {
    final metadata = json['metadata'];
    Map<String, dynamic>? meta;
    if (metadata is Map) {
      meta = Map<String, dynamic>.from(metadata);
    }
    final attachmentIds = <String>[];
    final rawAttachments = meta?['attachment_ids'];
    if (rawAttachments is List) {
      attachmentIds.addAll(
        rawAttachments.map((id) => id.toString()).where((id) => id.isNotEmpty),
      );
    }
    final reasoningRaw = meta?['reasoning_content']?.toString() ?? '';
    final calls = <PersonalityToolCall>[];
    final rawCalls = meta?['tool_calls'];
    if (rawCalls is List) {
      for (final call in rawCalls) {
        if (call is! Map) continue;
        final function = call['function'];
        calls.add(
          PersonalityToolCall(
            id: call['id']?.toString() ?? '',
            name: function is Map ? function['name']?.toString() ?? '' : '',
            arguments:
                function is Map ? function['arguments']?.toString() ?? '' : '',
          ),
        );
      }
    }
    return PersonalityMessage(
      role: json['role']?.toString() ?? '',
      content: json['content']?.toString() ?? '',
      attachmentIds: attachmentIds,
      reasoningContent: reasoningRaw.trim().isEmpty ? null : reasoningRaw.trim(),
      toolCalls: calls,
      toolCallId: () {
        final v = meta?['tool_call_id']?.toString() ?? '';
        return v.isEmpty ? null : v;
      }(),
      toolName: () {
        final v = meta?['tool_name']?.toString() ?? '';
        return v.isEmpty ? null : v;
      }(),
    );
  }
}

/// A tool call captured in an assistant message's metadata.
class PersonalityToolCall {
  const PersonalityToolCall({
    required this.id,
    required this.name,
    required this.arguments,
  });

  final String id;
  final String name;
  final String arguments;
}

typedef PersonalityTokenResolver = Future<String?> Function();

class PersonalityCoreService {
  const PersonalityCoreService({this.client, this.tokenResolver});

  /// Resolves the caller's access token. Defaults to the global Solar identity
  /// provider so callers never thread tokens through individual calls.
  final PersonalityTokenResolver? tokenResolver;

  Future<String> _requireToken() async {
    final resolve = tokenResolver ?? SolarAuthService().accessToken;
    final token = await resolve();
    if (token == null || token.trim().isEmpty) {
      throw const PersonalityCoreException('Sign in to start a conversation.');
    }
    return token.trim();
  }

  static const productionBaseUrl = 'https://api.solian.app/personality';

  static const productionDriveBaseUrl = 'https://api.solian.app/drive';

  /// Lists the account's conversations, newest first.
  Future<List<PersonalityConversation>> listConversations({
    String baseUrl = productionBaseUrl,
    int take = 50,
    int offset = 0,
    http.Client? client,
  }) async {
    final requestClient = client ?? http.Client();
    try {
      final uri = Uri.parse(
        '${_root(baseUrl)}/conversations',
      ).replace(queryParameters: {'take': '$take', 'offset': '$offset'});
      final response = await requestClient.get(
        uri,
        headers: _headers(await _requireToken()),
      );
      final body = _decode(response.body, 'conversation-list');
      _checkResponse(response.statusCode, body);
      if (body is! List) {
        throw const PersonalityCoreException(
          'Invalid conversation-list response.',
        );
      }
      return [
        for (final item in body)
          if (item is Map<String, dynamic>)
            PersonalityConversation.fromJson(item)
          else if (item is Map)
            PersonalityConversation.fromJson(Map<String, dynamic>.from(item)),
      ].where((conversation) => conversation.id.isNotEmpty).toList();
    } finally {
      if (client == null) requestClient.close();
    }
  }

  /// Lists a conversation's messages ordered by sequence ascending.
  Future<List<PersonalityMessage>> listMessages({
    required String conversationId,
    String baseUrl = productionBaseUrl,
    int take = 200,
    int offset = 0,
    http.Client? client,
  }) async {
    final requestClient = client ?? http.Client();
    try {
      final uri = Uri.parse(
        '${_root(baseUrl)}/conversations/$conversationId/messages',
      ).replace(queryParameters: {'take': '$take', 'offset': '$offset'});
      final response = await requestClient.get(
        uri,
        headers: _headers(await _requireToken()),
      );
      final body = _decode(response.body, 'message-list');
      _checkResponse(response.statusCode, body);
      if (body is! List) {
        throw const PersonalityCoreException('Invalid message-list response.');
      }
      return [
        for (final item in body)
          if (item is Map<String, dynamic>)
            PersonalityMessage.fromJson(item)
          else if (item is Map)
            PersonalityMessage.fromJson(Map<String, dynamic>.from(item)),
      ];
    } finally {
      if (client == null) requestClient.close();
    }
  }

  /// Uploads a local file to Solar Network drive and returns its id for use
  /// as a run attachment.
  Future<String> uploadAttachment({
    required String filePath,
    String driveBaseUrl = productionDriveBaseUrl,
    String? contentType,
  }) async {
    final request =
        http.MultipartRequest(
            'POST',
            Uri.parse('${_root(driveBaseUrl)}/files/upload/direct'),
          )
          ..headers.addAll(_headers(await _requireToken()))
          ..files.add(
            await http.MultipartFile.fromPath(
              'file',
              filePath,
              contentType: contentType == null
                  ? null
                  : MediaType.parse(contentType),
            ),
          );
    final response = await request.send();
    final body = _decode(await response.stream.bytesToString(), 'file-upload');
    _checkResponse(response.statusCode, body);
    if (body is! Map || body['id'] is! String) {
      throw const PersonalityCoreException('Invalid file-upload response.');
    }
    return (body['id'] as String).trim();
  }

  final http.Client? client;

  Future<List<PersonalityAgent>> listAgents({
    String baseUrl = productionBaseUrl,
  }) async {
    final requestClient = client ?? http.Client();
    try {
      final uri = Uri.parse(
        '${_root(baseUrl)}/agents',
      ).replace(queryParameters: const {'pet': 'true'});
      final response = await requestClient.get(
        uri,
        headers: _headers(await _requireToken()),
      );
      final body = _decode(response.body, 'agent-list');
      _checkResponse(response.statusCode, body);
      if (body is! List) {
        throw const PersonalityCoreException('Invalid agent-list response.');
      }
      return [
        for (final item in body)
          if (item is Map<String, dynamic>)
            PersonalityAgent.fromJson(item)
          else if (item is Map)
            PersonalityAgent.fromJson(Map<String, dynamic>.from(item)),
      ].where((agent) => agent.id.isNotEmpty).toList();
    } finally {
      if (client == null) requestClient.close();
    }
  }
  /// Fetches a pet agent's affection toward the signed-in account.
  /// Returns null when the account has no pet session yet (the server 404s).
  Future<PetAffection?> getPetAffection({
    required String agentId,
    String baseUrl = productionBaseUrl,
  }) async {
    final requestClient = client ?? http.Client();
    try {
      final response = await requestClient.get(
        Uri.parse('${_root(baseUrl)}/pet/affection').replace(
          queryParameters: {'agent_id': agentId},
        ),
        headers: _headers(await _requireToken()),
      );
      if (response.statusCode == 404) return null;
      final body = _decode(response.body, 'pet-affection');
      _checkResponse(response.statusCode, body);
      if (body is! Map) {
        throw const PersonalityCoreException('Invalid pet-affection response.');
      }
      final parsed = PetAffection.fromJson(Map<String, dynamic>.from(body));
      return parsed.agentId.isEmpty ? null : parsed;
    } finally {
      if (client == null) requestClient.close();
    }
  }

  /// Purges the agent's memories and conversation history for the signed-in
  /// account. No-op when the agent is unknown.
  Future<void> deleteAgentMemories({
    required String agentId,
    String baseUrl = productionBaseUrl,
  }) async {
    final requestClient = client ?? http.Client();
    try {
      final response = await requestClient.delete(
        Uri.parse('${_root(baseUrl)}/agents/$agentId/memories'),
        headers: _headers(await _requireToken()),
      );
      if (response.statusCode >= 200 && response.statusCode < 300) return;
      _checkResponse(
        response.statusCode,
        response.body.isEmpty ? null : _decode(response.body, 'memory-delete'),
      );
    } finally {
      if (client == null) requestClient.close();
    }
  }

  Future<String> createConversation({
    required String agentId,
    String title = '',
    String baseUrl = productionBaseUrl,
    http.Client? client,
  }) async {
    final requestClient = client ?? this.client ?? http.Client();
    final ownsClient = client == null && this.client == null;
    try {
      final response = await requestClient.post(
        Uri.parse('${_root(baseUrl)}/conversations'),
        headers: {
          ..._headers(await _requireToken()),
          'Content-Type': 'application/json',
        },
        body: jsonEncode({'agent_id': agentId, 'title': title}),
      );
      final body = _decode(response.body, 'conversation-create');
      _checkResponse(response.statusCode, body);
      if (body is! Map || body['id'] is! String) {
        throw const PersonalityCoreException(
          'Invalid conversation-create response.',
        );
      }
      return (body['id'] as String).trim();
    } finally {
      if (ownsClient) requestClient.close();
    }
  }

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
    String baseUrl = productionBaseUrl,
    http.Client? client,
  }) async {
    final requestClient = client ?? this.client ?? http.Client();
    final ownsClient = client == null && this.client == null;
    try {
      final request =
          http.Request(
              'POST',
              Uri.parse('${_root(baseUrl)}/conversations/$conversationId/runs'),
            )
            ..headers.addAll({
              ..._headers(await _requireToken()),
              'Content-Type': 'application/json',
              'Accept': 'text/event-stream',
            })
            ..body = jsonEncode({
              'message': message,
              'stream': true,
              if (attachmentIds.isNotEmpty) 'attachment_ids': attachmentIds,
            });
      final response = await requestClient.send(request);
      _checkResponse(response.statusCode, null);

      final buffer = StringBuffer();
      String? completedContent;
      var event = '';
      var data = StringBuffer();

      void dispatch() {
        if (data.isEmpty) {
          event = '';
          return;
        }
        final payload = _decode(data.toString(), 'conversation-stream');
        if (payload is! Map) {
          event = '';
          data = StringBuffer();
          return;
        }
        switch (event) {
          case 'message.delta':
            final delta = payload['delta'];
            if (delta is String && delta.isNotEmpty) {
              buffer.write(delta);
              onChunk?.call(delta);
            }
            break;
          case 'reasoning.delta':
            final delta = payload['delta'];
            if (delta is String && delta.isNotEmpty) {
              onReasoning?.call(delta);
            }
            break;
          case 'tool_call.delta':
            final name = payload['name'];
            if (name is String && name.isNotEmpty) {
              final rawArguments = payload['arguments'];
              Map<String, dynamic> args = {};
              if (rawArguments is Map) {
                args = Map<String, dynamic>.from(rawArguments);
              } else if (rawArguments is String &&
                  rawArguments.trim().isNotEmpty) {
                try {
                  final decoded = jsonDecode(rawArguments);
                  if (decoded is Map) {
                    args = Map<String, dynamic>.from(decoded);
                  }
                } catch (_) {
                  // The server may report malformed tool arguments; keep the
                  // event visible without making the whole run fail.
                }
              }
              onToolCall?.call(payload['id']?.toString() ?? '', name, args);
            }
            break;
          case 'tool_call.completed':
            final name = payload['name'];
            final result = payload['result'];
            if (name is String && name.isNotEmpty && result is String) {
              final rawArguments = payload['arguments'];
              Map<String, dynamic> args = {};
              if (rawArguments is Map) {
                args = Map<String, dynamic>.from(rawArguments);
              } else if (rawArguments is String &&
                  rawArguments.trim().isNotEmpty) {
                try {
                  final decoded = jsonDecode(rawArguments);
                  if (decoded is Map) {
                    args = Map<String, dynamic>.from(decoded);
                  }
                } catch (_) {
                  // Malformed tool arguments; keep the completion visible.
                }
              }
              onToolResult?.call(
                payload['id']?.toString() ?? '',
                name,
                args,
                result,
              );
            }
            break;
          case 'message.completed':
            final content = payload['content'];
            if (content is String && content.trim().isNotEmpty) {
              completedContent = content.trim();
            }
            break;
          case 'run.failed':
            final error = payload['error'];
            throw PersonalityCoreException(
              error is String && error.isNotEmpty
                  ? error
                  : 'Conversation run failed.',
            );
        }
        event = '';
        data = StringBuffer();
      }

      final lines = response.stream
          .transform(utf8.decoder)
          .transform(const LineSplitter());
      await for (final line in lines) {
        if (line.startsWith('event:')) {
          event = line.substring(6).trim();
        } else if (line.startsWith('data:')) {
          if (data.isNotEmpty) data.write('\n');
          data.write(line.substring(5).trim());
        } else if (line.isEmpty) {
          dispatch();
        }
      }
      dispatch();
      return completedContent ?? buffer.toString().trim();
    } finally {
      if (ownsClient) requestClient.close();
    }
  }

  /// Calls the OpenAI-compatible endpoint. Kept for non-conversation callers.
  Future<String> chat({
    required String agentId,
    required String prompt,
    String baseUrl = productionBaseUrl,
  }) async {
    final requestClient = client ?? http.Client();
    try {
      final response = await requestClient.post(
        Uri.parse('${_root(baseUrl)}/v1/chat/completions'),
        headers: {
          ..._headers(await _requireToken()),
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'model': agentId,
          'stream': false,
          'server_tools': true,
          'messages': [
            {'role': 'user', 'content': prompt},
          ],
        }),
      );
      final body = _decode(response.body, 'chat');
      _checkResponse(response.statusCode, body);
      if (body is! Map) {
        throw const PersonalityCoreException('Invalid chat response.');
      }
      final choices = body['choices'];
      if (choices is! List || choices.isEmpty || choices.first is! Map) {
        throw const PersonalityCoreException('Chat response has no choices.');
      }
      final message = (choices.first as Map)['message'];
      final content = message is Map ? message['content'] : null;
      if (content is! String || content.trim().isEmpty) {
        throw const PersonalityCoreException('Chat response has no content.');
      }
      return content.trim();
    } finally {
      if (client == null) requestClient.close();
    }
  }

  Future<String> chatMessages({
    required String agentId,
    required List<Map<String, String>> messages,
    String baseUrl = productionBaseUrl,
    void Function(String delta)? onChunk,
    bool stream = true,
    http.Client? client,
  }) async {
    final requestClient = client ?? http.Client();
    try {
      final body = jsonEncode({
        'model': agentId,
        'stream': stream && onChunk != null,
        'messages': messages,
      });
      final request =
          http.Request(
              'POST',
              Uri.parse('${_root(baseUrl)}/v1/chat/completions'),
            )
            ..headers.addAll({
              ..._headers(await _requireToken()),
              'Content-Type': 'application/json',
            })
            ..body = body;

      if (stream && onChunk != null) {
        // SSE path: stream incremental deltas to the caller.
        final response = await requestClient.send(request);
        _checkResponse(response.statusCode, null);
        final raw = StringBuffer();
        final lines = response.stream
            .transform(utf8.decoder)
            .transform(const LineSplitter());
        final buffer = StringBuffer();
        var sawData = false;
        await for (final line in lines) {
          raw.write(line);
          if (!line.startsWith('data:')) continue;
          sawData = true;
          final payload = line.substring(5).trim();
          if (payload == '[DONE]') break;
          final chunk = _decode(payload, 'chat-stream');
          if (chunk is! Map) continue;
          final choices = chunk['choices'];
          if (choices is! List || choices.isEmpty) continue;
          final delta = (choices.first as Map)['delta'];
          final content = delta is Map ? delta['content'] : null;
          if (content is String && content.isNotEmpty) {
            buffer.write(content);
            onChunk(content);
          }
        }
        if (!sawData) {
          // Server ignored stream: fall back to a whole-body completion.
          final full = _decode(raw.toString(), 'chat');
          final content = _singleCompletionContent(full);
          if (content != null) {
            buffer.clear();
            buffer.write(content);
            onChunk(content);
          }
        }
        return buffer.toString().trim();
      }

      // Non-stream path (mirrors the existing chat() contract).
      final response = await requestClient.post(
        Uri.parse('${_root(baseUrl)}/v1/chat/completions'),
        headers: {
          ..._headers(await _requireToken()),
          'Content-Type': 'application/json',
        },
        body: body,
      );
      final bodyJson = _decode(response.body, 'chat');
      _checkResponse(response.statusCode, bodyJson);
      final content = _singleCompletionContent(bodyJson);
      if (content == null) {
        throw const PersonalityCoreException('Chat response has no content.');
      }
      return content;
    } finally {
      if (client == null) requestClient.close();
    }
  }

  /// Extracts the assistant text from a completed (non-streaming) chat body.
  static String? _singleCompletionContent(Object? body) {
    if (body is! Map) return null;
    final choices = body['choices'];
    if (choices is! List || choices.isEmpty) return null;
    final message = (choices.first as Map)['message'];
    final content = message is Map ? message['content'] : null;
    return content is String && content.trim().isNotEmpty
        ? content.trim()
        : null;
  }

  Map<String, String> _headers(String accessToken) {
    return {'Authorization': 'Bearer ${accessToken.trim()}'};
  }

  String _root(String baseUrl) {
    return baseUrl.trim().replaceFirst(RegExp(r'/+$'), '');
  }

  Object? _decode(String responseBody, String operation) {
    try {
      return jsonDecode(responseBody);
    } catch (_) {
      throw PersonalityCoreException('Invalid $operation response.');
    }
  }

  void _checkResponse(int statusCode, Object? body) {
    if (statusCode >= 200 && statusCode < 300) return;
    throw PersonalityCoreException(_errorMessage(body, statusCode));
  }

  String _errorMessage(Object? body, int statusCode) {
    if (body is Map) {
      final message = body['detail'] ?? body['message'];
      if (message != null && message.toString().isNotEmpty) {
        return message.toString();
      }
      if (body['error'] case final Map error) {
        final message = error['message'];
        if (message != null && message.toString().isNotEmpty) {
          return message.toString();
        }
      }
    }
    return 'Personality Core request failed (HTTP $statusCode).';
  }
}

class PersonalityCoreException implements Exception {
  const PersonalityCoreException(this.message);

  final String message;

  @override
  String toString() => message;
}

class PersonalityCoreConfig {
  const PersonalityCoreConfig({required this.agentId});

  factory PersonalityCoreConfig.fromEnvironment() {
    return const PersonalityCoreConfig(
      agentId: String.fromEnvironment(
        'PERSONALITY_CORE_AGENT',
        defaultValue: 'michan',
      ),
    );
  }

  final String agentId;
}
