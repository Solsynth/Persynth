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

  /// The account-owned group this thread belongs to, or null when it is
  /// ungrouped. A thread belongs to at most one group.
  final String? groupId;

  const SnPersonalityConversation({
    required this.id,
    required this.agentId,
    required this.title,
    this.lastMessageAt,
    this.groupId,
  });

  factory SnPersonalityConversation.fromJson(Map<String, dynamic> json) {
    final groupId = json['group_id']?.toString();
    return SnPersonalityConversation(
      id: json['id']?.toString() ?? '',
      agentId: json['agent_id']?.toString() ?? '',
      title: json['title']?.toString() ?? '',
      lastMessageAt: DateTime.tryParse(
        json['last_message_at']?.toString() ?? '',
      )?.toLocal(),
      groupId: groupId == null || groupId.isEmpty ? null : groupId,
    );
  }
}

/// A named collection of an account's threads
/// (`GET /personality/conversation-groups`).
///
/// What the agent learns while talking in a grouped conversation is pinned in
/// the memory store, so the group is the account's way of marking a thread
/// important. [conversationCount] counts the group's live threads.
@immutable
class SnConversationGroup {
  final String id;
  final String name;
  final String description;
  final int conversationCount;

  const SnConversationGroup({
    required this.id,
    required this.name,
    this.description = '',
    this.conversationCount = 0,
  });

  factory SnConversationGroup.fromJson(Map<String, dynamic> json) {
    final count = json['conversation_count'];
    return SnConversationGroup(
      id: json['id']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      description: json['description']?.toString() ?? '',
      conversationCount: count is int
          ? count
          : int.tryParse(count?.toString() ?? '') ?? 0,
    );
  }
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

/// One part of a multimodal user message: text the caller contributes
/// directly, or a drive file the model reads as an image.
///
/// Text travels as text — never as an uploaded file — which is what lets a
/// pasted document reach the model without the drive, and stay editable on the
/// caller's device until the turn is sent, [name] labels a text part as an
/// attached document, so the model reads it under the name the reader saw.
@immutable
class SnRunInputPart {
  const SnRunInputPart._({
    required this.type,
    this.text,
    this.name,
    this.attachmentId,
  });

  /// A block of text the caller sends directly, optionally named as a file.
  const SnRunInputPart.text(String text, {String name = ''})
    : this._(type: 'text', text: text, name: name);

  /// A drive file the model reads as an image.
  const SnRunInputPart.image(String attachmentId)
    : this._(type: 'image', attachmentId: attachmentId);

  final String type;
  final String? text;
  final String? name;
  final String? attachmentId;

  /// The parts the server stored with a persisted message.
  static List<SnRunInputPart> listFromJson(dynamic raw) {
    if (raw is! List) return const [];
    return [
      for (final entry in raw.whereType<Map>())
        if (entry['type'] != null)
          SnRunInputPart._(
            type: entry['type'].toString(),
            text: entry['text']?.toString(),
            name: entry['name']?.toString(),
            attachmentId: entry['attachment_id']?.toString(),
          ),
    ];
  }

  Map<String, dynamic> toJson() => {
    'type': type,
    if (text != null && text!.isNotEmpty) 'text': text,
    if (name != null && name!.isNotEmpty) 'name': name,
    if (attachmentId != null && attachmentId!.isNotEmpty)
      'attachment_id': attachmentId,
  };
}

/// One persisted message. Reasoning, tool calls and attachments ride under the
/// message's `metadata` bag rather than as top-level fields.
@immutable
class SnPersonalityMessage {
  final String role;
  final String content;
  final List<String> attachmentIds;
  final List<SnRunInputPart> inputParts;
  final String? reasoningContent;
  final List<SnPersonalityToolCall> toolCalls;
  final String? toolCallId;
  final String? toolName;

  const SnPersonalityMessage({
    required this.role,
    required this.content,
    this.attachmentIds = const [],
    this.inputParts = const [],
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
      inputParts: SnRunInputPart.listFromJson(meta['input_parts']),
      reasoningContent: reasoning.isEmpty ? null : reasoning,
      toolCalls: SnPersonalityToolCall.listFromJson(meta['tool_calls']),
      toolCallId: meta['tool_call_id']?.toString(),
      toolName: meta['tool_name']?.toString(),
    );
  }
}

// ---------------------------------------------------------------------------
// Run usage — what a turn spent, and what the conversation has spent in total
// ---------------------------------------------------------------------------

/// How much one run spent.
///
/// A tool-calling run calls the model once per round and the server reports the
/// sum, so [inputTokens] is the run's whole prompt cost rather than the last
/// call's. [contextUsedTokens] is the fullest single prompt the run sent —
/// what the model's context was actually filled with — measured against
/// [contextWindowTokens] when the server knows the model's ceiling. Without a
/// known window the server omits the ratio rather than guessing one, and the
/// UI should do the same.
@immutable
class SnRunUsage {
  const SnRunUsage({
    required this.inputTokens,
    required this.outputTokens,
    required this.totalTokens,
    required this.rounds,
    this.contextUsedTokens,
    this.contextWindowTokens,
    this.contextUsedRatio,
  });

  final int inputTokens;
  final int outputTokens;
  final int totalTokens;

  /// Model calls the run made. A tool-calling turn makes one per round.
  final int rounds;

  final int? contextUsedTokens;
  final int? contextWindowTokens;
  final double? contextUsedRatio;

  /// Whether a ratio can be shown at all.
  bool get hasContextWindow => (contextWindowTokens ?? 0) > 0;

  /// Reads a run's `usage` bag. A run the provider reported nothing for stores
  /// `{}`, which parses to null so callers render no footer instead of zeros.
  static SnRunUsage? fromJson(dynamic raw) {
    if (raw is! Map) return null;
    final json = Map<String, dynamic>.from(raw);
    final input = _usageInt(json['input_tokens']);
    final output = _usageInt(json['output_tokens']);
    final total = _usageInt(json['total_tokens']);
    if (input == 0 && output == 0 && total == 0) return null;

    final context = json['context'];
    final contextJson = context is Map
        ? Map<String, dynamic>.from(context)
        : const <String, dynamic>{};
    return SnRunUsage(
      inputTokens: input,
      outputTokens: output,
      totalTokens: total == 0 ? input + output : total,
      rounds: _usageInt(json['rounds']),
      contextUsedTokens: _positiveOrNull(contextJson['used_tokens']),
      contextWindowTokens: _positiveOrNull(contextJson['window_tokens']),
      contextUsedRatio: _usageDouble(contextJson['used_ratio']),
    );
  }
}

/// The token total across every run in one conversation
/// (`GET /personality/conversations/:id/usage`).
@immutable
class SnConversationUsage {
  const SnConversationUsage({
    required this.runs,
    required this.inputTokens,
    required this.outputTokens,
    required this.totalTokens,
    this.peakContextUsedTokens,
    this.contextWindowTokens,
  });

  /// Runs that recorded usage; runs the provider reported nothing for are not
  /// counted, so this can be smaller than the conversation's run count.
  final int runs;

  final int inputTokens;
  final int outputTokens;
  final int totalTokens;

  /// The fullest single prompt any run in the conversation sent.
  final int? peakContextUsedTokens;

  /// The largest resolved window seen across the conversation's runs.
  final int? contextWindowTokens;

  factory SnConversationUsage.fromJson(Map<String, dynamic> json) =>
      SnConversationUsage(
        runs: _usageInt(json['runs']),
        inputTokens: _usageInt(json['input_tokens']),
        outputTokens: _usageInt(json['output_tokens']),
        totalTokens: _usageInt(json['total_tokens']),
        peakContextUsedTokens: _positiveOrNull(json['peak_context_used_tokens']),
        contextWindowTokens: _positiveOrNull(json['context_window_tokens']),
      );
}

int _usageInt(dynamic raw) {
  if (raw is int) return raw;
  if (raw is num) return raw.toInt();
  return int.tryParse(raw?.toString() ?? '') ?? 0;
}

double? _usageDouble(dynamic raw) {
  if (raw is num) return raw.toDouble();
  if (raw is String) return double.tryParse(raw.trim());
  return null;
}

int? _positiveOrNull(dynamic raw) {
  final value = _usageInt(raw);
  return value > 0 ? value : null;
}

/// Reads a counter out of a small JSON envelope (`{"deleted": n}`), treating
/// anything missing or unparseable as none.
int _intField(dynamic data, String key) {
  if (data is! Map) return 0;
  return _usageInt(data[key]);
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

/// What the finished run spent, reported after its text.
///
/// `message.completed` carries the assistant text and `run.completed` follows
/// with the run's token usage, so this is the last event of a successful turn.
class PersonalityUsageReported extends PersonalityRunEvent {
  const PersonalityUsageReported(this.usage);
  final SnRunUsage usage;
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
      case 'run.completed':
        final usage = SnRunUsage.fromJson(json['usage']);
        return usage == null ? null : PersonalityUsageReported(usage);
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

/// The account's conversation groups, ordered by name.
@riverpod
Future<List<SnConversationGroup>> personalityConversationGroups(Ref ref) {
  return ref.watch(personalityApiProvider).listConversationGroups();
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

  /// Deletes one thread, and with it its messages and runs. What the agent
  /// learned from it stays in the memory store — removing memories is its own
  /// explicit action.
  Future<void> deleteConversation(String id) async {
    await _client.delete(
      '/personality/conversations/${Uri.encodeComponent(id)}',
    );
  }

  /// Deletes many threads in one call, returning how many were removed.
  ///
  /// Ids are trimmed, de-duplicated and capped by the server; ids that are not
  /// the account's live threads are skipped rather than failing the call, so
  /// the count is what actually went.
  Future<int> deleteConversations(List<String> ids) async {
    final resp = await _client.post(
      '/personality/conversations/batch-delete',
      data: {'ids': ids},
    );
    return _intField(resp.data, 'deleted');
  }

  /// Moves [ids] into [groupId], or clears their membership when it is null.
  /// Returns how many rows were assigned or cleared.
  Future<int> setConversationGroup(List<String> ids, String? groupId) async {
    final resp = await _client.post(
      '/personality/conversations/group',
      data: {'ids': ids, 'group_id': groupId ?? ''},
    );
    return _intField(resp.data, 'updated');
  }

  /// The account's conversation groups, ordered by name.
  Future<List<SnConversationGroup>> listConversationGroups() async {
    final resp = await _client.get('/personality/conversation-groups');
    final data = resp.data;
    if (data is! List) return const [];
    return [
      for (final e in data.whereType<Map>())
        SnConversationGroup.fromJson(Map<String, dynamic>.from(e)),
    ];
  }

  /// Creates a group the account owns.
  Future<SnConversationGroup> createConversationGroup({
    required String name,
    String description = '',
  }) async {
    final resp = await _client.post(
      '/personality/conversation-groups',
      data: {'name': name, 'description': description},
    );
    final data = resp.data;
    if (data is! Map) {
      throw const PersonalityException('Group creation returned no group.');
    }
    return SnConversationGroup.fromJson(Map<String, dynamic>.from(data));
  }

  /// Renames a group and/or replaces its description. Omitted fields are left
  /// alone; the server needs at least one of them.
  Future<SnConversationGroup> updateConversationGroup(
    String id, {
    String? name,
    String? description,
  }) async {
    final resp = await _client.patch(
      '/personality/conversation-groups/${Uri.encodeComponent(id)}',
      data: {
        'name': ?name,
        'description': ?description,
      },
    );
    final data = resp.data;
    if (data is! Map) {
      throw const PersonalityException('Group update returned no group.');
    }
    return SnConversationGroup.fromJson(Map<String, dynamic>.from(data));
  }

  /// Deletes a group. Its threads survive and become ungrouped, and the
  /// retention the group granted is released.
  Future<void> deleteConversationGroup(String id) async {
    await _client.delete(
      '/personality/conversation-groups/${Uri.encodeComponent(id)}',
    );
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
  ///
  /// [inputParts] carries text the caller contributes as a message part — a
  /// pasted document the model should read under its own name — alongside the
  /// drive files in [attachmentIds].
  ///
  /// [reasoningEffort] and [disableReasoning] are the run's reasoning
  /// controls, mirroring the OpenAI-compatible shape the providers accept:
  /// the effort is forwarded verbatim and [disableReasoning] turns the
  /// provider's thinking mode off, which wins over any effort. Both are read
  /// when the run starts, so a client that cares states them on every run.
  Stream<PersonalityRunEvent> runConversation({
    required String conversationId,
    required String message,
    List<String> attachmentIds = const [],
    List<SnRunInputPart> inputParts = const [],
    List<SnLocalTool> clientTools = const [],
    List<SnClientSkill> clientSkills = const [],
    List<String> overrides = const [],
    List<String> context = const [],
    String? reasoningEffort,
    bool disableReasoning = false,
    CancelToken? cancelToken,
  }) async* {
    final response = await _streamClient().post<ResponseBody>(
      '/personality/conversations/${Uri.encodeComponent(conversationId)}/runs',
      data: {
        'message': message,
        'stream': true,
        if (attachmentIds.isNotEmpty) 'attachment_ids': attachmentIds,
        if (inputParts.isNotEmpty)
          'input_parts': [for (final part in inputParts) part.toJson()],
        if (clientTools.isNotEmpty)
          'client_tools': [for (final tool in clientTools) tool.toOpenAiTool()],
        if (clientSkills.isNotEmpty)
          'client_skills': [for (final skill in clientSkills) skill.toJson()],
        if (overrides.isNotEmpty) 'overrides': overrides,
        if (context.isNotEmpty) 'context': context,
        if (reasoningEffort != null && reasoningEffort.trim().isNotEmpty)
          'reasoning_effort': reasoningEffort.trim(),
        if (disableReasoning) 'disable_reasoning': true,
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

  /// The conversation's token total, summed from every run in it.
  ///
  /// Cheaper and more consistent than walking the run list: the server totals
  /// the stored per-run usage, so the number never re-prices history against
  /// today's provider configuration.
  Future<SnConversationUsage> conversationUsage(String conversationId) async {
    final resp = await _client.get(
      '/personality/conversations/${Uri.encodeComponent(conversationId)}/usage',
    );
    final data = resp.data;
    if (data is! Map) {
      return const SnConversationUsage(
        runs: 0,
        inputTokens: 0,
        outputTokens: 0,
        totalTokens: 0,
      );
    }
    return SnConversationUsage.fromJson(Map<String, dynamic>.from(data));
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
