import 'dart:async';

import 'package:http/http.dart' as http;

import 'package:synth_pet/conversation/conversation_event.dart';
import 'package:synth_pet/conversation/conversation_message.dart';
import 'package:synth_pet/conversation/personality_backend.dart';
import 'package:synth_pet/personality/personality_service.dart';

/// Stateful client for one server-persisted conversation.
///
/// Personality Core owns the conversation history, tool execution, and final
/// message persistence. This controller only forwards user turns and relays
/// the server's SSE events to the UI. Identity comes from the global Solar
/// auth service inside the backend; callers never pass access tokens.
class ConversationController {
  ConversationController({
    required this.backend,
    this.defaultAgentId = 'michan',
  }) : _agentId = defaultAgentId;

  final ChatBackend backend;
  final String defaultAgentId;
  String _agentId;

  Stream<ConversationEvent> get events => _events.stream;
  String? get conversationId => _conversationId;
  List<ConversationMessage> get messages => List.unmodifiable(_messages);

  final List<ConversationMessage> _messages = [];
  bool _busy = false;
  bool _aborted = false;
  String? _conversationId;
  http.Client? _activeClient;
  final _events = StreamController<ConversationEvent>.broadcast(sync: true);

  void _emit(ConversationEvent e) {
    if (!_events.isClosed) _events.add(e);
  }

  Future<List<PersonalityAgent>> loadAgents() => backend.listAgents();

  /// Uploads a local file to Solar Network drive; the returned id is usable
  /// as a run attachment.
  Future<String> uploadAttachment(String filePath) =>
      backend.uploadAttachment(filePath: filePath);

  void setAgent(String id) {
    if (_agentId == id) return;
    if (_busy) return;
    _agentId = id;
    _conversationId = null;
    _messages.clear();
  }

  /// Lists the account's persisted conversations, newest first.
  Future<List<PersonalityConversation>> listConversations() =>
      backend.listConversations();

  /// Loads a persisted conversation's history into memory so the next
  /// [send] continues that thread.
  Future<void> openConversation(String id) async {
    if (_busy || id.isEmpty) return;
    final history = await backend.listMessages(conversationId: id);
    _conversationId = id;
    _messages
      ..clear()
      ..addAll([
        for (final message in history)
          ConversationMessage(
            message.role == 'assistant'
                ? ConversationRole.assistant
                : ConversationRole.user,
            message.content,
            attachmentIds: message.attachmentIds,
          ),
      ]);
    _emit(const ConversationOpened());
  }

  /// Forgets the current thread; the next [send] starts a fresh one.
  void newConversation() {
    if (_busy) return;
    _conversationId = null;
    _messages.clear();
    _emit(const ConversationOpened());
  }

  Future<void> send(
    String input, {
    List<String> attachmentIds = const [],
  }) async {
    final text = input.trim();
    if (text.isEmpty && attachmentIds.isEmpty) return;
    if (_busy) return;

    _busy = true;
    _aborted = false;
    _activeClient = http.Client();
    _emit(const StatusChanged(true));
    _emit(const ThinkingStarted());

    try {
      var id = _conversationId;
      if (id == null) {
        id = await backend.createConversation(
          agentId: _agentId,
          client: _activeClient,
        );
        if (id.isEmpty) {
          throw const PersonalityCoreException(
            'Conversation create returned no id.',
          );
        }
        _conversationId = id;
      }

      _messages.add(
        ConversationMessage(
          ConversationRole.user,
          text,
          attachmentIds: attachmentIds,
        ),
      );
      var emittedChunk = false;
      final full = await backend.runConversation(
        conversationId: id,
        message: text,
        attachmentIds: attachmentIds,
        onChunk: (delta) {
          emittedChunk = true;
          _emit(ChunkReceived(delta));
        },
        onToolCall: (name, args) => _emit(ToolInvoked(name, args, 'running')),
        client: _activeClient,
      );
      if (_aborted) return;

      final reply = full.trim();
      if (reply.isNotEmpty) {
        _messages.add(ConversationMessage(ConversationRole.assistant, reply));
        if (!emittedChunk) await _revealStream(reply);
      }
      _emit(MessageCompleted(reply));
    } on Object catch (e) {
      if (_aborted) return;
      _emit(
        ErrorOccurred(e is PersonalityCoreException ? e.message : e.toString()),
      );
    } finally {
      _activeClient?.close();
      _activeClient = null;
      _busy = false;
      _emit(const StatusChanged(false));
    }
  }

  Future<void> _revealStream(String text) async {
    final words = text.split(' ');
    for (var i = 0; i < words.length; i++) {
      if (_aborted) return;
      _emit(ChunkReceived(i == 0 ? words[i] : ' ${words[i]}'));
      await Future.delayed(const Duration(milliseconds: 24));
    }
  }

  void abort() {
    _aborted = true;
    _activeClient?.close();
  }

  void dispose() {
    _activeClient?.close();
    _events.close();
  }
}
