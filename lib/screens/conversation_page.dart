import 'dart:async';
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
import 'package:synth_pet/widgets/message_markdown.dart';

// ---------------------------------------------------------------------------
// Bubble types
// ---------------------------------------------------------------------------
enum _BubbleKind { user, assistant, thinking, systemNote }

class _Bubble {
  _Bubble(
    this.kind,
    this.text, {
    this.streaming = false,
    this.attachmentIds = const [],
    this.attachmentPreviews = const [],
    this.toolCallId,
  });
  final _BubbleKind kind;
  String text;
  bool streaming;

  /// Drive file ids persisted with the message (server history).
  final List<String> attachmentIds;

  /// Local file paths for attachments picked in this session.
  final List<String> attachmentPreviews;

  /// Server tool-call id, used to update a running note with its result.
  final String? toolCallId;
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
          if (_bubbles.isNotEmpty &&
              _bubbles.last.kind == _BubbleKind.thinking) {
            _bubbles.removeLast();
          }
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
          if (_bubbles.isNotEmpty &&
              _bubbles.last.kind == _BubbleKind.thinking) {
            _bubbles.removeLast();
          }
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
        case ToolInvoked(:final id, :final name, :final result):
          if (result == 'running') {
            _bubbles.add(_Bubble(_BubbleKind.systemNote, name, toolCallId: id));
          } else {
            final index = _bubbles.lastIndexWhere(
              (b) => b.toolCallId != null && b.toolCallId == id,
            );
            if (index >= 0) {
              _bubbles[index].text = '$name · $result';
            } else {
              _bubbles.add(_Bubble(_BubbleKind.systemNote, '$name · $result'));
            }
          }
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
        case ErrorOccurred(:final message):
          if (_bubbles.isNotEmpty &&
              _bubbles.last.kind == _BubbleKind.thinking) {
            _bubbles.removeLast();
          }
          _error = message;
      }
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
    final kind = message.role == ConversationRole.assistant
        ? _BubbleKind.assistant
        : _BubbleKind.user;
    return [
      for (final part in message.content.split(RegExp(r'\n\s*\n')))
        if (part.trim().isNotEmpty)
          _Bubble(
            kind,
            part.trim(),
            attachmentIds: kind == _BubbleKind.user
                ? message.attachmentIds
                : const [],
          ),
    ];
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
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 14, 14, 14),
      color: cs.surfaceContainer,
      child: Row(
        children: [
          Expanded(
            child: Row(
              children: [
                Text(
                  _agents
                          .where((a) => a.id == _selectedAgentId)
                          .firstOrNull
                          ?.displayName ??
                      'Conversation',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                // The companion is picked before the conversation starts;
                // once messages exist the header gets out of the way.
                if (_agents.isNotEmpty && _bubbles.isEmpty) ...[
                  const SizedBox(width: 10),
                  DropdownButton<PersonalityAgent>(
                    value: _agents
                        .where((a) => a.id == _selectedAgentId)
                        .firstOrNull,
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
                  ),
                ],
              ],
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
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
      color: cs.surfaceContainer,
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
                      borderRadius: BorderRadius.circular(20),
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
                        if (_bubbles.isNotEmpty &&
                            _bubbles.last.kind == _BubbleKind.thinking) {
                          setState(() => _bubbles.removeLast());
                        }
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
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.start,
            children: [
              Flexible(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 9,
                  ),
                  constraints: BoxConstraints(
                    maxWidth: MediaQuery.of(context).size.width * 0.72,
                  ),
                  decoration: BoxDecoration(
                    color: cs.surfaceContainerHighest.withValues(alpha: 0.55),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Text(
                    '[thinking] ${bubble.text}${bubble.streaming ? '▍' : ''}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: cs.onSurfaceVariant,
                      fontStyle: FontStyle.italic,
                      height: 1.35,
                    ),
                  ),
                ),
              ),
            ],
          ),
        );

      case _BubbleKind.systemNote:
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Center(
            child: Text(
              bubble.text,
              style: theme.textTheme.labelSmall?.copyWith(
                color: cs.onSurfaceVariant,
              ),
            ),
          ),
        );
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
