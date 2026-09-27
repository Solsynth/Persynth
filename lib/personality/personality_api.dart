import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:persynth/personality/local_tool.dart';
import 'package:persynth/personality/personality_network.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'personality_api.g.dart';

// ---------------------------------------------------------------------------
// Models — local client-side mirrors of the PersonalityCore backend
// (`/personality`). Kept dependency-free (plain fromJson) since these are not
// part of the typed solar_network_sdk surface.
// ---------------------------------------------------------------------------

class SnPersonalityAgent {
  final String id;
  final String name;
  final String? description;
  final String? model;
  final List<String> abilities;
  final String? systemPrompt;
  final bool enabled;

  const SnPersonalityAgent({
    required this.id,
    required this.name,
    this.description,
    this.model,
    this.abilities = const [],
    this.systemPrompt,
    this.enabled = false,
  });

  factory SnPersonalityAgent.fromJson(Map<String, dynamic> json) =>
      SnPersonalityAgent(
        id: json['id'] as String,
        name: json['name'] as String,
        description: json['description']?.toString(),
        model: json['model']?.toString(),
        abilities:
            (json['abilities'] as List?)?.map((e) => e.toString()).toList() ??
            const [],
        systemPrompt: json['system_prompt']?.toString(),
        enabled: json['enabled'] is bool ? json['enabled'] : false,
      );
}

/// One capability the client can load on request.
///
/// Sent with every run so the server can offer it in `list_skills` next to its
/// own skills — one catalogue for the model to ask about, whichever side of
/// the wire the tools end up running on.
@immutable
class SnClientSkill {
  const SnClientSkill({required this.name, required this.description});

  /// The name the model activates it under, e.g. `local_device`.
  final String name;

  /// One line describing the capability, in the third person.
  final String description;

  Map<String, dynamic> toJson() => {
    'name': name,
    'description': description,
  };
}

/// One persisted thread (`GET /personality/conversations`), newest first.
@immutable
class SnPersonalityConversation {
  final String id;
  final String agentId;
  final String title;
  final DateTime? lastMessageAt;

  const SnPersonalityConversation({
    required this.id,
    required this.agentId,
    required this.title,
    this.lastMessageAt,
  });

  factory SnPersonalityConversation.fromJson(Map<String, dynamic> json) =>
      SnPersonalityConversation(
        id: json['id']?.toString() ?? '',
        agentId: json['agent_id']?.toString() ?? '',
        title: json['title']?.toString() ?? '',
        lastMessageAt: DateTime.tryParse(
          json['last_message_at']?.toString() ?? '',
        )?.toLocal(),
      );
}

/// A tool the assistant asked for while answering (metadata of a message).
@immutable
class SnPersonalityToolCall {
  final String id;
  final String name;

  /// Raw JSON arguments string, exactly as persisted by the backend.
  final String arguments;

  const SnPersonalityToolCall({
    required this.id,
    required this.name,
    required this.arguments,
  });

  /// Reads `metadata.tool_calls`, which nests the OpenAI `function` envelope:
  /// `[{"id": ..., "function": {"name": ..., "arguments": ...}}]`.
  static List<SnPersonalityToolCall> listFromJson(dynamic raw) {
    if (raw is! List) return const [];
    final calls = <SnPersonalityToolCall>[];
    for (final entry in raw) {
      if (entry is! Map) continue;
      final fn = entry['function'];
      calls.add(
        SnPersonalityToolCall(
          id: entry['id']?.toString() ?? '',
          name: fn is Map ? fn['name']?.toString() ?? '' : '',
          arguments: fn is Map ? fn['arguments']?.toString() ?? '' : '',
        ),
      );
    }
    return calls;
  }
}

/// One persisted message. Reasoning, tool calls and attachments ride under the
/// message's `metadata` bag rather than as top-level fields.
@immutable
class SnPersonalityMessage {
  final String role;
  final String content;
  final List<String> attachmentIds;
  final String? reasoningContent;
  final List<SnPersonalityToolCall> toolCalls;
  final String? toolCallId;
  final String? toolName;

  const SnPersonalityMessage({
    required this.role,
    required this.content,
    this.attachmentIds = const [],
    this.reasoningContent,
    this.toolCalls = const [],
    this.toolCallId,
    this.toolName,
  });

  factory SnPersonalityMessage.fromJson(Map<String, dynamic> json) {
    final rawMeta = json['metadata'];
    final meta = rawMeta is Map
        ? Map<String, dynamic>.from(rawMeta)
        : const <String, dynamic>{};
    final reasoning = meta['reasoning_content']?.toString().trim() ?? '';
    final rawAttachments = meta['attachment_ids'];
    return SnPersonalityMessage(
      role: json['role']?.toString() ?? 'user',
      content: json['content']?.toString() ?? '',
      attachmentIds: rawAttachments is List
          ? [
              for (final id in rawAttachments)
                if (id.toString().isNotEmpty) id.toString(),
            ]
          : const [],
      reasoningContent: reasoning.isEmpty ? null : reasoning,
      toolCalls: SnPersonalityToolCall.listFromJson(meta['tool_calls']),
      toolCallId: meta['tool_call_id']?.toString(),
      toolName: meta['tool_name']?.toString(),
    );
  }
}

// ---------------------------------------------------------------------------
// Run events — the `POST /personality/conversations/:id/runs` SSE grammar
// ---------------------------------------------------------------------------

/// One event of a streamed assistant turn.
sealed class PersonalityRunEvent {
  const PersonalityRunEvent();
}

class PersonalityMessageDelta extends PersonalityRunEvent {
  const PersonalityMessageDelta(this.delta);
  final String delta;
}

class PersonalityReasoningDelta extends PersonalityRunEvent {
  const PersonalityReasoningDelta(this.delta);
  final String delta;
}

class PersonalityToolCallStarted extends PersonalityRunEvent {
  const PersonalityToolCallStarted({
    required this.id,
    required this.name,
    required this.arguments,
  });

  final String id;
  final String name;
  final Map<String, dynamic> arguments;
}

/// The run paused on a client-owned tool call: this device must execute the
/// tool and resume the run with the result (POST
/// /conversations/:id/runs/:runId/tool-results).
class PersonalityToolCallClient extends PersonalityRunEvent {
  const PersonalityToolCallClient({
    required this.runId,
    required this.id,
    required this.name,
    required this.arguments,
  });

  final String runId;
  final String id;
  final String name;
  final Map<String, dynamic> arguments;
}

class PersonalityToolCallCompleted extends PersonalityRunEvent {
  const PersonalityToolCallCompleted({
    required this.id,
    required this.name,
    required this.arguments,
    required this.result,
  });

  final String id;
  final String name;
  final Map<String, dynamic> arguments;
  final String result;
}

/// The persisted assistant text; the authoritative version of the deltas.
class PersonalityRunCompleted extends PersonalityRunEvent {
  const PersonalityRunCompleted(this.content);
  final String content;
}

class PersonalityRunFailed extends PersonalityRunEvent {
  const PersonalityRunFailed(this.error);
  final String error;
}

/// A Personality request failed; [message] is server-authored when available.
class PersonalityException implements Exception {
  const PersonalityException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// A short, user-facing message for a failed Personality request.
String personalityErrorMessage(Object error) {
  if (error is PersonalityException) return error.message;
  if (error is DioException) {
    final data = error.response?.data;
    if (data is Map && data['message'] != null) {
      return data['message'].toString();
    }
    return error.message ?? error.toString();
  }
  return error.toString();
}

/// Whether [error] is Solar Network refusing the request itself: no session,
/// an expired one, or an account without the right to what was asked for.
///
/// The distinction matters to the UI. A refused request is not a hiccup the
/// user can retry past, so the surfaces show an unauthorized status — with the
/// sign-in — instead of an error banner over a dead composer.
bool isPersonalityUnauthorized(Object error) {
  if (error is DioException) {
    final status = error.response?.statusCode;
    return status == 401 || status == 403;
  }
  return false;
}

/// Parses the run endpoint's `text/event-stream` framing into events.
///
/// `event:` names the type, `data:` carries one JSON payload, and a blank line
/// dispatches. Unknown events and malformed payloads are dropped rather than
/// failing the turn, matching the web and watchOS clients.
Stream<PersonalityRunEvent> parsePersonalityRunEvents(
  Stream<List<int>> bytes,
) async* {
  String? eventName;
  final dataLines = <String>[];

  PersonalityRunEvent? dispatch() {
    final event = eventName;
    eventName = null;
    if (dataLines.isEmpty) return null;
    final payload = dataLines.join('\n');
    dataLines.clear();

    dynamic decoded;
    try {
      decoded = jsonDecode(payload);
    } catch (_) {
      return null;
    }
    if (decoded is! Map) return null;
    final json = Map<String, dynamic>.from(decoded);

    switch (event) {
      case 'message.delta':
        final delta = json['delta'];
        return delta is String && delta.isNotEmpty
            ? PersonalityMessageDelta(delta)
            : null;
      case 'reasoning.delta':
        final delta = json['delta'];
        return delta is String && delta.isNotEmpty
            ? PersonalityReasoningDelta(delta)
            : null;
      case 'tool_call.delta':
        final name = json['name'];
        if (name is! String || name.isEmpty) return null;
        return PersonalityToolCallStarted(
          id: json['id']?.toString() ?? '',
          name: name,
          arguments: parsePersonalityToolArguments(json['arguments']),
        );
      case 'tool_call.client':
        final name = json['name'];
        final id = json['id']?.toString() ?? '';
        final runId = json['run_id']?.toString() ?? '';
        if (name is! String || name.isEmpty || id.isEmpty || runId.isEmpty) {
          return null;
        }
        return PersonalityToolCallClient(
          runId: runId,
          id: id,
          name: name,
          arguments: parsePersonalityToolArguments(json['arguments']),
        );
      case 'tool_call.completed':
        final name = json['name'];
        final result = json['result'];
        if (name is! String || name.isEmpty || result is! String) return null;
        return PersonalityToolCallCompleted(
          id: json['id']?.toString() ?? '',
          name: name,
          arguments: parsePersonalityToolArguments(json['arguments']),
          result: result,
        );
      case 'message.completed':
        final content = json['content'];
        if (content is! String || content.trim().isEmpty) return null;
        return PersonalityRunCompleted(content.trim());
      case 'run.failed':
        final error = json['error'];
        return PersonalityRunFailed(
          error is String && error.isNotEmpty
              ? error
              : 'Conversation run failed.',
        );
      default:
        return null;
    }
  }

  await for (final line
      in bytes.transform(utf8.decoder).transform(const LineSplitter())) {
    if (line.isEmpty) {
      final event = dispatch();
      if (event != null) yield event;
      continue;
    }
    if (line.startsWith('event:')) {
      eventName = line.substring(6).trim();
      continue;
    }
    if (line.startsWith('data:')) {
      dataLines.add(line.substring(5).trim());
    }
  }

  // A closed stream may end without the trailing blank line.
  final trailing = dispatch();
  if (trailing != null) yield trailing;
}

/// Tool arguments arrive either as a JSON object or as a JSON string.
Map<String, dynamic> parsePersonalityToolArguments(dynamic raw) {
  if (raw is Map) return Map<String, dynamic>.from(raw);
  if (raw is String && raw.trim().isNotEmpty) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (_) {
      // Malformed arguments: keep the trace visible without failing the turn.
    }
  }
  return const {};
}

// ---------------------------------------------------------------------------
// Client
// ---------------------------------------------------------------------------

// `personalityApiProvider` (the PersonalityApi instance) and
// `personalityApiClientProvider` (the authenticated Dio) live in
// `lib/personality/personality_network.dart`.

@riverpod
Future<List<SnPersonalityAgent>> personalityAgents(Ref ref) async {
  final dio = ref.read(personalityApiClientProvider);
  final resp = await dio.get('/personality/agents');
  final data = resp.data;
  if (data is List) {
    return [
      for (final e in data)
        SnPersonalityAgent.fromJson(e as Map<String, dynamic>),
    ];
  }
  return const [];
}

/// The account's threads, newest first.
@riverpod
Future<List<SnPersonalityConversation>> personalityConversations(Ref ref) {
  return ref.watch(personalityApiProvider).listConversations();
}

/// The account's personality threads and messages, plus the run stream that
/// drives one assistant turn.
class PersonalityApi {
  const PersonalityApi(this._client);

  final Dio _client;

  /// A copy of the API client with streaming timeouts disabled: a run may idle
  /// for minutes between deltas while a tool executes.
  Dio _streamClient() {
    final dio = Dio(
      _client.options.copyWith(
        receiveTimeout: Duration.zero,
        sendTimeout: Duration.zero,
      ),
    );
    dio.interceptors.addAll(_client.interceptors);
    return dio;
  }

  Future<List<SnPersonalityConversation>> listConversations({
    int take = 50,
    int offset = 0,
  }) async {
    final resp = await _client.get(
      '/personality/conversations',
      queryParameters: {'take': take, 'offset': offset},
    );
    final data = resp.data;
    if (data is! List) return const [];
    return [
      for (final e in data.whereType<Map>())
        SnPersonalityConversation.fromJson(Map<String, dynamic>.from(e)),
    ];
  }

  /// Messages of one thread, ordered by sequence ascending.
  Future<List<SnPersonalityMessage>> listMessages(
    String conversationId, {
    int take = 200,
    int offset = 0,
  }) async {
    final resp = await _client.get(
      '/personality/conversations/${Uri.encodeComponent(conversationId)}/messages',
      queryParameters: {'take': take, 'offset': offset},
    );
    final data = resp.data;
    if (data is! List) return const [];
    return [
      for (final e in data.whereType<Map>())
        SnPersonalityMessage.fromJson(Map<String, dynamic>.from(e)),
    ];
  }

  Future<String> createConversation({
    required String agentId,
    String title = '',
  }) async {
    final resp = await _client.post(
      '/personality/conversations',
      data: {'agent_id': agentId, 'title': title},
    );
    final data = resp.data;
    final id = data is Map ? data['id']?.toString() : null;
    if (id == null || id.isEmpty) {
      throw const PersonalityException('Conversation creation returned no id.');
    }
    return id;
  }

  /// Starts one assistant turn and relays its streamed events. [cancelToken]
  /// aborts the turn; the caller keeps whatever text already arrived.
  ///
  /// [context] is system prompt text the caller contributes for this run:
  /// the server appends it after the agent's own prompt, so a client-side
  /// capability can say what its tools mean without the deployment having to
  /// know about it. [clientSkills] names the capabilities the caller could
  /// still load, so the server's `list_skills` can offer them beside its own.
  ///
  /// [overrides] names the server-owned tools the caller has replaced. The
  /// server leaves its own copies out of the tool list and stops advertising
  /// the skills they belong to, so the model is offered one tool per job.
  Stream<PersonalityRunEvent> runConversation({
    required String conversationId,
    required String message,
    List<String> attachmentIds = const [],
    List<SnLocalTool> clientTools = const [],
    List<SnClientSkill> clientSkills = const [],
    List<String> overrides = const [],
    List<String> context = const [],
    CancelToken? cancelToken,
  }) async* {
    final response = await _streamClient().post<ResponseBody>(
      '/personality/conversations/${Uri.encodeComponent(conversationId)}/runs',
      data: {
        'message': message,
        'stream': true,
        if (attachmentIds.isNotEmpty) 'attachment_ids': attachmentIds,
        if (clientTools.isNotEmpty)
          'client_tools': [for (final tool in clientTools) tool.toOpenAiTool()],
        if (clientSkills.isNotEmpty)
          'client_skills': [for (final skill in clientSkills) skill.toJson()],
        if (overrides.isNotEmpty) 'overrides': overrides,
        if (context.isNotEmpty) 'context': context,
      },
      cancelToken: cancelToken,
      options: Options(
        responseType: ResponseType.stream,
        receiveTimeout: Duration.zero,
        sendTimeout: Duration.zero,
        headers: {'Accept': 'text/event-stream'},
      ),
    );

    final body = response.data;
    if (body == null) {
      throw const PersonalityException('Conversation stream unavailable.');
    }
    yield* parsePersonalityRunEvents(body.stream.cast<List<int>>());
  }

  /// Resumes a streamed run paused on a client-owned tool call. The result
  /// string is persisted as a tool message and replayed on the run stream
  /// (`tool_call.completed`) exactly like a server tool result.
  ///
  /// [clientTools] are definitions to add to the run before it continues: what
  /// a call to `load_skill` just made callable. The server keeps
  /// them for the rest of the run, so a capability the model loaded mid-turn
  /// is usable in the same turn instead of only from the next message.
  ///
  /// [overrides] carries the same addition for the server tools a newly loaded
  /// plugin replaces: its tools are on the run from here, so the server's own
  /// copies have to leave it in the same step.
  Future<void> submitClientToolResult({
    required String conversationId,
    required String runId,
    required String toolCallId,
    required String result,
    List<SnLocalTool> clientTools = const [],
    List<String> overrides = const [],
  }) async {
    await _client.post(
      '/personality/conversations/${Uri.encodeComponent(conversationId)}/runs/'
      '${Uri.encodeComponent(runId)}/tool-results',
      data: {
        'tool_call_id': toolCallId,
        'result': result,
        if (clientTools.isNotEmpty)
          'client_tools': [for (final tool in clientTools) tool.toOpenAiTool()],
        if (overrides.isNotEmpty) 'overrides': overrides,
      },
    );
  }
}
