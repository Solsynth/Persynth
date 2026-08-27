import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:auto_route/auto_route.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:island_ui_foundation/island_ui_foundation.dart';

import 'package:synth_pet/auth/solar_auth_service.dart';
import 'package:synth_pet/conversation/conversation_controller.dart';
import 'package:synth_pet/conversation/conversation_event.dart';
import 'package:synth_pet/conversation/conversation_message.dart';
import 'package:synth_pet/conversation/personality_backend.dart';
import 'package:synth_pet/personality/personality_service.dart';
import 'package:synth_pet/theme/app_theme.dart';
import 'package:synth_pet/widgets/message_markdown.dart';

// ---------------------------------------------------------------------------
// Bubble types
// ---------------------------------------------------------------------------
enum _BubbleKind { user, assistant, thinking, tool }

class _Bubble {
  _Bubble(
    this.kind,
    this.text, {
    this.streaming = false,
    this.attachmentIds = const [],
    this.attachmentPreviews = const [],
    this.toolCallId,
    this.args,
    this.toolResult,
    this.toolRunning = false,
    this.collapsed = false,
  });
  final _BubbleKind kind;
  String text;
  bool streaming;

  /// Drive file ids persisted with the message (server history).
  final List<String> attachmentIds;

  /// Local file paths for attachments picked in this session.
  final List<String> attachmentPreviews;

  /// Server tool-call id, used to update a running row with its result.
  final String? toolCallId;

  /// Tool invocation arguments, shown when a tool row is expanded.
  Map<String, dynamic>? args;

  /// Resolved tool result (`'running'` while pending, `'unknown tool'` on a
  /// miss, `'interrupted'` when the turn ended first).
  String? toolResult;

  /// True while the tool call has not resolved.
  bool toolRunning;

  /// Detail well hidden; a folded trace reads as one log line.
  bool collapsed = false;

  /// The user explicitly toggled this section; the auto-fold leaves it alone.
  bool touched = false;
}

/// A locally picked file awaiting upload.
class _PendingAttachment {
  _PendingAttachment(this.path, this.name);
  final String path;
  final String name;
}

// ---------------------------------------------------------------------------
// Presence orb — soft pulse that says "I'm here".
// ---------------------------------------------------------------------------
class _PresenceOrb extends StatefulWidget {
  const _PresenceOrb({required this.active});
  final bool active;

  @override
  State<_PresenceOrb> createState() => _PresenceOrbState();
}

class _PresenceOrbState extends State<_PresenceOrb>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: widget.active
        ? const Duration(milliseconds: 900)
        : const Duration(milliseconds: 1600),
  )..repeat(reverse: true);

  late final Animation<double> _pulse = Tween(
    begin: 0.82,
    end: 1.0,
  ).animate(CurvedAnimation(parent: _c, curve: Curves.easeInOutSine));

  @override
  void didUpdateWidget(covariant _PresenceOrb old) {
    super.didUpdateWidget(old);
    _c.duration = widget.active
        ? const Duration(milliseconds: 900)
        : const Duration(milliseconds: 1600);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;
    final bg = theme.colorScheme.surface;

    if (MediaQuery.of(context).disableAnimations) {
      return SizedBox(
        width: 14,
        height: 14,
        child: DecoratedBox(
          decoration: BoxDecoration(shape: BoxShape.circle, color: primary),
        ),
      );
    }
    return AnimatedBuilder(
      animation: _pulse,
      builder: (_, _) {
        final s = _pulse.value;
        return Container(
          width: 14,
          height: 14,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: RadialGradient(
              colors: [primary, bg],
              stops: const [0.0, 1.0],
            ),
            boxShadow: [
              BoxShadow(
                color: primary.withValues(alpha: 0.45 * s),
                blurRadius: 12 * s,
                spreadRadius: 1,
              ),
            ],
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Screen
// ---------------------------------------------------------------------------
@RoutePage()
class ConversationPage extends StatefulWidget {
  const ConversationPage({super.key, this.controller});

  /// Test seam: injects a controller with a fake backend.
  final ConversationController? controller;

  @override
  State<ConversationPage> createState() => _ConversationPageState();
}

class _ConversationPageState extends State<ConversationPage> {
  late final _controller =
      widget.controller ??
      ConversationController(
        backend: PersonalityCoreBackend(const PersonalityCoreService()),
        defaultAgentId: PersonalityCoreConfig.fromEnvironment().agentId,
      );

  final List<_PendingAttachment> _pending = [];
  bool _uploading = false;
  final List<_Bubble> _bubbles = [];
  final _inputController = TextEditingController();
  final _scrollController = ScrollController();
  late final StreamSubscription<ConversationEvent> _subscription;

  List<PersonalityAgent> _agents = const [];
  String? _selectedAgentId;
  bool _busy = false;
  String? _error;
  bool _authError = false;

  // ---- lifecycle -----------------------------------------------------------

  @override
  void initState() {
    super.initState();
    _subscription = _controller.events.listen(_onEvent);
    _loadInitial();
  }

  @override
  void dispose() {
    _subscription.cancel();
    _inputController.dispose();
    _scrollController.dispose();
    _controller.dispose();
    super.dispose();
  }

  // ---- data ----------------------------------------------------------------

  Future<void> _loadInitial() async {
    setState(() => _authError = false);
    final token = await SolarAuthService().accessToken();
    if (token == null) {
      if (mounted) setState(() => _authError = true);
      return;
    }
    final agents = await _controller.loadAgents();
    final defaultId = PersonalityCoreConfig.fromEnvironment().agentId;
    final selected = agents.isEmpty
        ? defaultId
        : (agents.any((a) => a.id == defaultId) ? defaultId : agents.first.id);
    setState(() {
      _agents = agents;
      _selectedAgentId = selected;
    });
    _controller.setAgent(selected);
  }

  Future<void> _signIn() async {
    await SolarAuthService().signIn();
    await _loadInitial();
  }

  // ---- events --------------------------------------------------------------

  void _onEvent(ConversationEvent e) {
    setState(() {
      switch (e) {
        case ThinkingStarted():
          _busy = true;
        case ThinkingChunk(:final delta):
          final last = _bubbles.isNotEmpty ? _bubbles.last : null;
          if (last == null || last.kind == _BubbleKind.assistant) break;
          if (last.kind == _BubbleKind.thinking) {
            last.text += delta;
          } else {
            _bubbles.add(_Bubble(_BubbleKind.thinking, delta, streaming: true));
          }
          _scrollToEnd();
        case ChunkReceived(:final delta):
          // The reply is starting; reasoning is over. The trace stays behind,
          // folded, instead of vanishing with the reply.
          _finalizeThinking();
          final last = _bubbles.isNotEmpty ? _bubbles.last : null;
          if (last == null || last.kind != _BubbleKind.assistant) {
            _bubbles.add(
              _Bubble(_BubbleKind.assistant, delta, streaming: true),
            );
          } else {
            last.text += delta;
          }
          _splitStreamingBubble();
          _scrollToEnd();
        case MessageCompleted(:final text):
          _finalizeThinking();
          // Swap the accumulated streaming bubble for the final, split
          // message. Thinking and tool traces stay in the log, folded.
          if (_bubbles.isNotEmpty &&
              _bubbles.last.kind == _BubbleKind.assistant) {
            _bubbles.removeLast();
          }
          // The agent marks message boundaries with a blank line.
          for (final part in text.split(RegExp(r'\n\s*\n'))) {
            final trimmed = part.trim();
            if (trimmed.isEmpty) continue;
            _bubbles.add(_Bubble(_BubbleKind.assistant, trimmed));
          }
          _scrollToEnd();
        case ToolInvoked(:final id, :final name, :final args, :final result):
          _onToolInvoked(id, name, args, result);
          _scrollToEnd();
        case ConversationOpened():
          _bubbles
            ..clear()
            ..addAll([
              for (final m in _controller.messages) ..._bubblesFromMessage(m),
            ]);
          _scrollToEnd();
        case StatusChanged(:final busy):
          _busy = busy;
          if (!busy) {
            _finalizeThinking();
            _settleRunningTools();
          }
        case ErrorOccurred(:final message):
          _finalizeThinking();
          _error = message;
      }
    });
  }

  void _onToolInvoked(
    String id,
    String name,
    Map<String, dynamic> args,
    String result,
  ) {
    if (result == 'running') {
      _bubbles.add(
        _Bubble(
          _BubbleKind.tool,
          name,
          toolCallId: id,
          args: args,
          toolRunning: true,
        ),
      );
      return;
    }
    final index = _bubbles.lastIndexWhere(
      (b) => b.toolCallId != null && b.toolCallId == id,
    );
    if (index >= 0) {
      final bubble = _bubbles[index];
      bubble
        ..toolRunning = false
        ..toolResult = result
        ..args = args;
      // Settled machinery folds away unless the user pinned it open.
      if (!bubble.touched) bubble.collapsed = true;
    } else {
      _bubbles.add(
        _Bubble(
          _BubbleKind.tool,
          name,
          toolCallId: id,
          args: args,
          toolResult: result,
        ),
      );
    }
  }

  /// The reply has started or the turn ended; reasoning is over. Fold the
  /// trace unless the user pinned it open.
  void _finalizeThinking() {
    for (final bubble in _bubbles) {
      if (bubble.kind == _BubbleKind.thinking && bubble.streaming) {
        bubble.streaming = false;
        if (!bubble.touched) bubble.collapsed = true;
      }
    }
  }

  /// A turn ended while a tool row still showed `running` (abort or error);
  /// log it as interrupted rather than leaving it spinning forever.
  void _settleRunningTools() {
    for (final bubble in _bubbles) {
      if (bubble.kind == _BubbleKind.tool && bubble.toolRunning) {
        bubble.toolRunning = false;
        bubble.toolResult ??= 'interrupted';
        if (!bubble.touched) bubble.collapsed = true;
      }
    }
  }

  void _toggleTrace(_Bubble bubble) {
    setState(() {
      bubble
        ..touched = true
        ..collapsed = !bubble.collapsed;
    });
  }

  /// The agent marks message boundaries with a blank line; while streaming,
  /// promote every completed segment into its own bubble.
  void _splitStreamingBubble() {
    final last = _bubbles.isNotEmpty ? _bubbles.last : null;
    if (last == null || last.kind != _BubbleKind.assistant || !last.streaming) {
      return;
    }
    final parts = last.text.split(RegExp(r'\n\s*\n'));
    if (parts.length < 2) return;
    last.text = parts.removeLast().trim();
    _bubbles.addAll([
      for (final part in parts)
        if (part.trim().isNotEmpty) _Bubble(_BubbleKind.assistant, part.trim()),
    ]);
  }

  List<_Bubble> _bubblesFromMessage(ConversationMessage message) {
    switch (message.role) {
      case ConversationRole.assistant:
        final bubbles = <_Bubble>[];
        // Replayed reasoning reads exactly like the live thinking trace.
        if (message.reasoningContent != null &&
            message.reasoningContent!.trim().isNotEmpty) {
          bubbles.add(
            _Bubble(
              _BubbleKind.thinking,
              message.reasoningContent!,
              collapsed: true,
            ),
          );
        }
        // Persisted tool calls restore as settled tool rows.
        for (final call in message.toolCalls) {
          Map<String, dynamic>? args;
          try {
            final decoded = jsonDecode(call.arguments);
            if (decoded is Map<String, dynamic>) args = decoded;
          } catch (_) {}
          bubbles.add(
            _Bubble(
              _BubbleKind.tool,
              call.name,
              toolCallId: call.id,
              args: args,
              toolResult: 'earlier turn',
              collapsed: true,
            ),
          );
        }
        for (final part in message.content.split(RegExp(r'\n\s*\n'))) {
          if (part.trim().isNotEmpty) {
            bubbles.add(_Bubble(_BubbleKind.assistant, part.trim()));
          }
        }
        return bubbles;
      case ConversationRole.tool:
        // Tool results belong to the call above; skip orphaned rows so they
        // never resurface as user messages.
        return const [];
      case ConversationRole.system:
        return const [];
      case ConversationRole.user:
        return [
          for (final part in message.content.split(RegExp(r'\n\s*\n')))
            if (part.trim().isNotEmpty)
              _Bubble(
                _BubbleKind.user,
                part.trim(),
                attachmentIds: message.attachmentIds,
              ),
        ];
    }
  }

  Future<void> _send() async {
    final text = _inputController.text.trim();
    if ((text.isEmpty && _pending.isEmpty) || _busy || _authError) return;

    final pending = List<_PendingAttachment>.of(_pending);
    setState(() {
      _bubbles.add(
        _Bubble(
          _BubbleKind.user,
          text,
          attachmentPreviews: [for (final a in pending) a.path],
        ),
      );
      _error = null;
      _inputController.clear();
      _pending.clear();
      _uploading = true;
    });
    _scrollToEnd();
    try {
      final attachmentIds = <String>[];
      for (final attachment in pending) {
        attachmentIds.add(await _controller.uploadAttachment(attachment.path));
      }
      await _controller.send(text, attachmentIds: attachmentIds);
    } on PersonalityCoreException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  Future<void> _pickAttachments() async {
    final files = await FilePicker.pickFiles(type: FileType.image);
    if (files.isEmpty) return;
    setState(() {
      _pending.addAll([
        for (final file in files)
          if (file.path != null) _PendingAttachment(file.path!, file.name),
      ]);
    });
  }

  Future<void> _showConversationPicker() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => SheetScaffold(
        titleText: 'Conversations',
        heightFactor: 0.7,
        actions: [
          TextButton.icon(
            onPressed: () {
              _controller.newConversation();
              Navigator.of(context).pop();
            },
            icon: const Icon(Icons.add, size: 18),
            label: const Text('New'),
          ),
        ],
        child: _ConversationPickerSheet(controller: _controller),
      ),
    );
  }

  void _startNewConversation() {
    if (_busy) return;
    _controller.newConversation();
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  // ---- build ---------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ColoredBox(
      color: theme.colorScheme.surface,
      child: SafeArea(
        child: Column(
          children: [
            _buildHeader(theme),
            if (_authError)
              _buildAuthGate(theme)
            else ...[
              if (_error != null) _buildErrorBanner(theme),
              Expanded(
                child: ListView.builder(
                  controller: _scrollController,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 14,
                  ),
                  itemCount: _bubbles.length,
                  itemBuilder: (_, i) => _buildBubble(_bubbles[i], theme),
                ),
              ),
              _buildFooter(theme),
            ],
          ],
        ),
      ),
    );
  }

  // ---- header --------------------------------------------------------------

  Widget _buildHeader(ThemeData theme) {
    final cs = theme.colorScheme;
    final selectedAgent =
        _agents.where((a) => a.id == _selectedAgentId).firstOrNull;
    // No bar of its own: the title sits on the content sheet like the other
    // pages, so the sheet's rounded shoulder stays visible.
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 14, 14, 14),
      child: Row(
        children: [
          Expanded(
            child: _agents.isNotEmpty && _bubbles.isEmpty
                // Picking the companion: the dropdown's own button already
                // shows the name, so no separate title duplicates it.
                ? DropdownButton<PersonalityAgent>(
                    value: selectedAgent,
                    underline: const SizedBox.shrink(),
                    isDense: true,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: cs.onSurfaceVariant,
                    ),
                    items: [
                      for (final agent in _agents)
                        DropdownMenuItem(
                          value: agent,
                          child: Text(agent.displayName),
                        ),
                    ],
                    onChanged: (agent) {
                      if (agent == null) return;
                      setState(() => _selectedAgentId = agent.id);
                      _controller.setAgent(agent.id);
                    },
                  )
                : Text(
                    selectedAgent?.displayName ?? 'Conversation',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
          ),
          if (!_authError) ...[
            IconButton(
              icon: const Icon(Icons.add_comment_outlined),
              tooltip: 'New chat',
              onPressed: _busy ? null : _startNewConversation,
            ),
            IconButton(
              icon: const Icon(Icons.forum_outlined),
              tooltip: 'Conversations',
              onPressed: _busy ? null : _showConversationPicker,
            ),
          ],
          if (_authError && !_busy)
            FilledButton.icon(
              onPressed: _signIn,
              icon: const Icon(Icons.login),
              label: const Text('Sign in'),
            ),
        ],
      ),
    );
  }

  // ---- auth gate -----------------------------------------------------------

  Widget _buildAuthGate(ThemeData theme) {
    final cs = theme.colorScheme;
    return Expanded(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const _PresenceOrb(active: false),
              const SizedBox(height: 18),
              Text(
                'Sign in to talk',
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Connect your Solar account to start a conversation '
                'with your companion.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: cs.onSurfaceVariant,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 22),
              FilledButton.icon(
                onPressed: _signIn,
                icon: const Icon(Icons.login),
                label: const Text('Sign in'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ---- error banner --------------------------------------------------------

  Widget _buildErrorBanner(ThemeData theme) {
    final cs = theme.colorScheme;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: cs.errorContainer,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              _error!,
              style: TextStyle(color: cs.onErrorContainer, fontSize: 12.5),
            ),
          ),
          GestureDetector(
            onTap: () => setState(() => _error = null),
            child: Icon(Icons.close, color: cs.onErrorContainer, size: 18),
          ),
        ],
      ),
    );
  }

  // ---- footer (input) ------------------------------------------------------

  Widget _buildFooter(ThemeData theme) {
    final cs = theme.colorScheme;
    final busy = _busy || _uploading;
    // No dock of its own: the input sits directly on the content sheet, a
    // single filled pill field, so the sheet reads like the other pages.
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_pending.isNotEmpty) ...[
            _buildPendingStrip(theme),
            const SizedBox(height: 8),
          ],
          Row(
            children: [
              IconButton(
                icon: Icon(Icons.image_outlined, color: cs.onSurfaceVariant),
                tooltip: 'Attach images',
                onPressed: busy || _authError ? null : _pickAttachments,
              ),
              Expanded(
                child: TextField(
                  controller: _inputController,
                  onSubmitted: (_) => _send(),
                  enabled: !_authError,
                  cursorColor: cs.primary,
                  decoration: InputDecoration(
                    hintText: 'Message the companion…',
                    hintStyle: TextStyle(color: cs.onSurfaceVariant),
                    filled: true,
                    fillColor: cs.surfaceContainerLowest,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(24),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              FilledButton(
                // The send button doubles as the stop control while a turn
                // runs or attachments upload.
                onPressed: _authError
                    ? null
                    : busy
                    ? () {
                        _controller.abort();
                        setState(() {
                          _finalizeThinking();
                          _settleRunningTools();
                        });
                      }
                    : _send,
                style: FilledButton.styleFrom(
                  shape: const CircleBorder(),
                  padding: const EdgeInsets.all(10),
                ),
                child: Icon(
                  busy ? Icons.stop_rounded : Icons.arrow_upward_rounded,
                  size: 20,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildPendingStrip(ThemeData theme) {
    final cs = theme.colorScheme;
    return SizedBox(
      height: 64,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: _pending.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (_, i) {
          final attachment = _pending[i];
          return Stack(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Image.file(
                  File(attachment.path),
                  width: 64,
                  height: 64,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => Container(
                    width: 64,
                    height: 64,
                    color: cs.surfaceContainerHighest,
                    child: Icon(Icons.insert_drive_file, color: cs.outline),
                  ),
                ),
              ),
              Positioned(
                top: 0,
                right: 0,
                child: GestureDetector(
                  onTap: () => setState(() => _pending.removeAt(i)),
                  child: Container(
                    padding: const EdgeInsets.all(2),
                    decoration: BoxDecoration(
                      color: cs.surface.withValues(alpha: 0.85),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(Icons.close, size: 12, color: cs.onSurface),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  // ---- bubbles -------------------------------------------------------------

  Widget _buildBubble(_Bubble bubble, ThemeData theme) {
    final cs = theme.colorScheme;
    switch (bubble.kind) {
      case _BubbleKind.user:
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              Flexible(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 11,
                  ),
                  constraints: BoxConstraints(
                    maxWidth: MediaQuery.of(context).size.width * 0.72,
                  ),
                  decoration: BoxDecoration(
                    color: cs.inverseSurface,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _buildBubbleAttachments(bubble, theme),
                      if (bubble.text.isNotEmpty) ...[
                        Text(
                          bubble.text,
                          style: TextStyle(
                            color: cs.onInverseSurface,
                            fontSize: 14,
                            height: 1.35,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        );

      case _BubbleKind.assistant:
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.start,
            children: [
              Flexible(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 11,
                  ),
                  constraints: BoxConstraints(
                    maxWidth: MediaQuery.of(context).size.width * 0.72,
                  ),
                  decoration: BoxDecoration(
                    color: cs.surfaceContainerLowest,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: MessageMarkdown(
                    text: bubble.streaming ? '${bubble.text}▍' : bubble.text,
                    textStyle: const TextStyle(fontSize: 14, height: 1.35),
                  ),
                ),
              ),
            ],
          ),
        );

      case _BubbleKind.thinking:
        return _buildThinkingBubble(bubble, theme);

      case _BubbleKind.tool:
        return _buildToolBubble(bubble, theme);
    }
  }

  Widget _buildBubbleAttachments(_Bubble bubble, ThemeData theme) {
    final previews = bubble.attachmentPreviews;
    final ids = bubble.attachmentIds;
    if (previews.isEmpty && ids.isEmpty) return const SizedBox.shrink();
    final cs = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          for (final path in previews)
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.file(
                File(path),
                width: 88,
                height: 88,
                fit: BoxFit.cover,
              ),
            ),
          for (final id in ids)
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.network(
                '${PersonalityCoreService.productionDriveBaseUrl}/files/$id',
                width: 88,
                height: 88,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => Container(
                  width: 88,
                  height: 88,
                  color: cs.surfaceContainerHighest,
                  child: Icon(Icons.attach_file, color: cs.outline, size: 18),
                ),
              ),
            ),
        ],
      ),
    );
  }

  // ---- machinery traces ----------------------------------------------------

  /// The terminal-voice style shared by thinking and tool traces: Plex Mono
  /// at trace size, tone taken from the palette, never a hardcoded color.
  static TextStyle _traceStyle({
    required Color color,
    double size = 12,
    FontWeight weight = FontWeight.w400,
  }) => TextStyle(
    fontFamily: SynthPetFonts.display,
    fontSize: size,
    height: 1.45,
    fontWeight: weight,
    color: color,
  );

  /// Reasoning types itself out live, then folds to a log line — `thought` —
  /// with its first line as the summary.
  Widget _buildThinkingBubble(_Bubble bubble, ThemeData theme) {
    final cs = theme.colorScheme;
    final streaming = bubble.streaming;
    final snippet = bubble.text.trim().split('\n').first;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: _TraceSection(
        label: Text(
          streaming ? 'thinking' : 'thought',
          style: _traceStyle(
            color: cs.onSurfaceVariant,
            weight: FontWeight.w600,
          ),
        ),
        expanded: !bubble.collapsed,
        onTap: () => _toggleTrace(bubble),
        summary: bubble.collapsed && snippet.isNotEmpty
            ? Text(
                snippet,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: _traceStyle(color: cs.onSurfaceVariant),
              )
            : null,
        well: SelectableText(
          '${bubble.text}${streaming ? '▍' : ''}',
          style: _traceStyle(color: cs.onSurfaceVariant, size: 11.5),
        ),
      ),
    );
  }

  /// One tool call as a log line: ember cursor while it runs, the resolved
  /// result as the summary, arguments and full result in the well.
  Widget _buildToolBubble(_Bubble bubble, ThemeData theme) {
    final cs = theme.colorScheme;
    final running = bubble.toolRunning;
    final failed = bubble.toolResult == 'unknown tool';
    final summary = bubble.toolResult?.replaceAll(RegExp(r'\s+'), ' ').trim();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: _TraceSection(
        leading: running
            ? _TraceDot(character: '▍', color: cs.primary, pulse: true)
            : failed
            ? _TraceDot(character: '!', color: cs.error)
            : null,
        label: Text(
          bubble.text,
          style: _traceStyle(color: cs.onSurface, weight: FontWeight.w600),
        ),
        expanded: !bubble.collapsed,
        onTap: () => _toggleTrace(bubble),
        summary: !bubble.collapsed || summary == null || summary.isEmpty
            ? null
            : Text(
                summary,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: _traceStyle(
                  color: failed ? cs.error : cs.onSurfaceVariant,
                ),
              ),
        well: _ToolWell(bubble: bubble, theme: theme),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Machinery traces — the companion's engine-room log: thinking and tool
// calls, in the same terminal voice as the pet itself.
// ---------------------------------------------------------------------------

/// One collapsible machinery trace: a single log line with a detail well
/// that folds out beneath it. Live sections sit open; settled ones fold.
class _TraceSection extends StatelessWidget {
  const _TraceSection({
    required this.label,
    required this.expanded,
    required this.onTap,
    required this.well,
    this.leading,
    this.summary,
  });

  /// The trace's name or verb, in the terminal voice.
  final Text label;

  /// Leading state marker slot; null leaves a quiet gap so rows align.
  final Widget? leading;

  /// One-line trailing summary shown when folded.
  final Widget? summary;

  final bool expanded;
  final VoidCallback onTap;

  /// Detail well shown when expanded.
  final Widget well;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final reduced = MediaQuery.disableAnimationsOf(context);
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: MediaQuery.of(context).size.width * 0.72,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
              child: Row(
                children: [
                  SizedBox(
                    width: 16,
                    child: Center(child: leading ?? const SizedBox.shrink()),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    expanded ? '▾' : '▸',
                    style: TextStyle(
                      fontFamily: SynthPetFonts.display,
                      fontSize: 10,
                      height: 1,
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(width: 6),
                  label,
                  if (summary != null) ...[
                    const SizedBox(width: 8),
                    Flexible(child: summary!),
                  ],
                ],
              ),
            ),
          ),
          AnimatedCrossFade(
            firstChild: const SizedBox(width: double.infinity),
            secondChild: Padding(
              padding: const EdgeInsets.fromLTRB(4, 0, 4, 6),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: cs.surfaceContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: well,
              ),
            ),
            crossFadeState: expanded
                ? CrossFadeState.showSecond
                : CrossFadeState.showFirst,
            duration: reduced
                ? Duration.zero
                : const Duration(milliseconds: 180),
            sizeCurve: Curves.easeOutCubic,
          ),
        ],
      ),
    );
  }
}

/// A leading state marker: the ember block cursor pulses while a tool runs;
/// the brick `!` marks a failed call. Settled rows carry no marker.
class _TraceDot extends StatefulWidget {
  const _TraceDot({
    required this.character,
    required this.color,
    this.pulse = false,
  });

  final String character;
  final Color color;
  final bool pulse;

  @override
  State<_TraceDot> createState() => _TraceDotState();
}

class _TraceDotState extends State<_TraceDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);

  late final Animation<double> _pulse = Tween(
    begin: 0.35,
    end: 1.0,
  ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOutSine));

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final quiet = !widget.pulse || MediaQuery.disableAnimationsOf(context);
    final style = TextStyle(
      fontFamily: SynthPetFonts.display,
      fontSize: 12,
      height: 1,
      color: widget.color,
    );
    if (quiet) return Text(widget.character, style: style);
    return AnimatedBuilder(
      animation: _pulse,
      builder: (_, child) => Opacity(opacity: _pulse.value, child: child),
      child: Text(widget.character, style: style),
    );
  }
}

/// The expanded detail of a tool call: arguments in secondary tone, resolved
/// result in primary tone, separated by tone rather than a rule.
class _ToolWell extends StatelessWidget {
  const _ToolWell({required this.bubble, required this.theme});

  final _Bubble bubble;
  final ThemeData theme;

  String get _argsText {
    final args = bubble.args;
    if (args == null || args.isEmpty) return '';
    return [
      for (final entry in args.entries)
        '${entry.key}: '
            '${entry.value is String ? entry.value : jsonEncode(entry.value)}',
    ].join('\n');
  }

  @override
  Widget build(BuildContext context) {
    final cs = theme.colorScheme;
    final result = bubble.toolResult;
    final argsText = _argsText;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (argsText.isNotEmpty) ...[
          SelectableText(
            argsText,
            style: TextStyle(
              fontFamily: SynthPetFonts.display,
              fontSize: 11.5,
              height: 1.5,
              color: cs.onSurfaceVariant,
            ),
          ),
          if (result != null && result.isNotEmpty) const SizedBox(height: 8),
        ],
        if (result != null && result.isNotEmpty)
          SelectableText(
            result,
            style: TextStyle(
              fontFamily: SynthPetFonts.display,
              fontSize: 11.5,
              height: 1.5,
              color: result == 'unknown tool' ? cs.error : cs.onSurface,
            ),
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Conversation picker sheet
// ---------------------------------------------------------------------------
class _ConversationPickerSheet extends StatefulWidget {
  const _ConversationPickerSheet({required this.controller});

  final ConversationController controller;

  @override
  State<_ConversationPickerSheet> createState() =>
      _ConversationPickerSheetState();
}

class _ConversationPickerSheetState extends State<_ConversationPickerSheet> {
  late final Future<List<PersonalityConversation>> _future = widget.controller
      .listConversations();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: FutureBuilder<List<PersonalityConversation>>(
            future: _future,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const Center(
                  child: CircularProgressIndicator(strokeWidth: 2),
                );
              }
              if (snapshot.hasError) {
                return Center(
                  child: Text(
                    'Could not load conversations.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                );
              }
              final conversations = snapshot.data ?? const [];
              if (conversations.isEmpty) {
                return Center(
                  child: Text(
                    'No past conversations yet.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                );
              }
              return ListView.separated(
                shrinkWrap: true,
                itemCount: conversations.length,
                separatorBuilder: (_, _) =>
                    Divider(height: 1, color: cs.outlineVariant),
                itemBuilder: (_, i) {
                  final conversation = conversations[i];
                  final subtitle = conversation.lastMessageAt == null
                      ? conversation.agentId
                      : MaterialLocalizations.of(
                          context,
                        ).formatFullDate(conversation.lastMessageAt!);
                  return ListTile(
                    dense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 20),
                    leading: Icon(
                      Icons.forum_outlined,
                      size: 20,
                      color: cs.onSurfaceVariant,
                    ),
                    title: Text(
                      conversation.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(subtitle, maxLines: 1),
                    onTap: () async {
                      Navigator.of(context).pop();
                      await widget.controller.openConversation(conversation.id);
                    },
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }
}
