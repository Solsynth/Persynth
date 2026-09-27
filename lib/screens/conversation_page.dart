import 'dart:convert';

import 'package:auto_route/auto_route.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:gap/gap.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:island_ui_foundation/island_ui_foundation.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:persynth/auth/solar_auth_controller.dart';
import 'package:persynth/auth/solar_sign_in_panel.dart';
import 'package:persynth/personality/insight_chat_controller.dart';
import 'package:persynth/personality/personality_api.dart';
import 'package:persynth/personality/personality_service.dart';
import 'package:persynth/router.dart';
import 'package:persynth/widgets/message_markdown.dart';

/// Insight: a live conversation with a personality agent, with the account's
/// other threads in a responsive sidebar.
///
/// Port of FloatLand's `pages/pet/index.vue` thread log (user bubbles, streamed
/// replies, reasoning traces, tool traces) rendered with this app's chat
/// chrome.
@RoutePage()
class ConversationPage extends HookConsumerWidget {
  const ConversationPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final chat = ref.watch(insightChatControllerProvider);
    final controller = ref.read(insightChatControllerProvider.notifier);
    final authStatus = ref.watch(
      solarAuthStateProvider.select((state) => state.status),
    );
    // A session the server no longer honours — or none at all — is a status of
    // this screen, not a banner over it: nothing here can send until the
    // account is signed in again, so the chat surface is replaced by the
    // sign-in that fixes it. A sign-in under way is one of those states: the
    // panel holding its code stays where the reader is, which is the point.
    final unauthorized =
        authStatus != SolarAuthStatus.signedIn || chat.unauthorized;
    final agents =
        ref.watch(personalityAgentsProvider).value ??
        const <SnPersonalityAgent>[];
    // The desktop chat sends on Enter.
    const enterToSend = true;
    final uploading = useState(false);

    final inputController = useTextEditingController();
    final focusNode = useFocusNode();
    final wideScreen = isWideScreen(context);
    // Drives the ResponsiveSidebar: an open panel when wide, an on-demand sheet
    // when narrow (so a phone never lands on an unexpected sheet).
    final showConversations = useState(wideScreen);

    final agentId = chat.agentId ?? (agents.isEmpty ? null : agents.first.id);
    final agentName = _agentLabel(agents, agentId);

    void handleSend() {
      if (chat.busy) return;
      final text = inputController.text;
      if (text.trim().isEmpty && chat.pendingAttachments.isEmpty) return;
      inputController.clear();
      focusNode.requestFocus();
      controller.send(text);
    }

    Future<void> pickAttachments() async {
      if (uploading.value) return;
      final messenger = ScaffoldMessenger.of(context);
      final picked = await FilePicker.pickFiles(type: FileType.image);
      if (!context.mounted || picked.isEmpty) return;
      uploading.value = true;
      try {
        final ids = <String>[];
        final uploader = PersonalityCoreService();
        for (final file in picked) {
          final path = file.path;
          if (path == null || path.isEmpty) continue;
          try {
            ids.add(await uploader.uploadAttachment(filePath: path));
          } catch (error) {
            messenger.showSnackBar(
              SnackBar(content: Text('Failed to attach ${file.name}: $error')),
            );
          }
        }
        if (ids.isNotEmpty && context.mounted) {
          controller.attachFiles(ids);
        }
      } finally {
        uploading.value = false;
      }
    }

    final mainContent = Column(
      children: [
        if (!unauthorized && chat.error != null)
          _ErrorBanner(
            message: chat.error!,
            onDismiss: controller.dismissError,
          ),
        Expanded(
          child: unauthorized
              ? _UnauthorizedState(
                  // Without a session, what ended is the session; the refusal
                  // copy belongs to one that is still there and was turned away.
                  signedOut: authStatus != SolarAuthStatus.signedIn,
                  agentName: agentName,
                  // A refusal that does not hold is the reader's to dismiss;
                  // without a session there is nothing here to retry.
                  onRetry: chat.unauthorized
                      ? controller.clearUnauthorized
                      : null,
                )
              : _InsightThread(
                  bubbles: chat.bubbles,
                  agentName: agentName,
                  onToggleTrace: controller.toggleTrace,
                ),
        ),
        if (!unauthorized)
          _Composer(
            controller: inputController,
            focusNode: focusNode,
            attachments: chat.pendingAttachments,
            busy: chat.busy,
            enterToSend: enterToSend,
            onSend: handleSend,
            onStop: controller.stop,
            onPickAttachments: uploading.value ? null : pickAttachments,
            onRemoveAttachment: controller.removePendingAttachment,
          ),
      ],
    );

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 16,
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _StatusDot(busy: chat.busy),
            const Gap(8),
            Flexible(
              child: chat.bubbles.isEmpty && agents.isNotEmpty
                  ? DropdownButtonHideUnderline(
                      child: DropdownButton<String>(
                        value: agentId,
                        isDense: true,
                        borderRadius: BorderRadius.circular(12),
                        onChanged: chat.busy
                            ? null
                            : (value) {
                                if (value != null) {
                                  controller.selectAgent(value);
                                }
                              },
                        items: [
                          for (final agent in agents)
                            DropdownMenuItem(
                              value: agent.id,
                              child: Text(
                                agent.name.trim().isEmpty
                                    ? 'Unnamed agent'
                                    : agent.name.trim(),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.titleSmall?.copyWith(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                        ],
                      ),
                    )
                  : Text(
                      agentName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Conversations',
            onPressed: () {
              showConversations.value = !showConversations.value;
            },
            icon: Icon(
              Symbols.forum_rounded,
              color: wideScreen && showConversations.value
                  ? scheme.primary
                  : null,
            ),
          ),
          IconButton(
            tooltip: 'New chat',
            onPressed: chat.busy ? null : controller.newConversation,
            icon: const Icon(Symbols.edit_square_rounded),
          ),
          IconButton(
            tooltip: 'Settings',
            onPressed: () => context.router.push(const SettingsRoute()),
            icon: const Icon(Symbols.tune_rounded),
          ),
          const Gap(4),
        ],
      ),
      body: ResponsiveSidebar(
        showSidebar: showConversations,
        sidebarWidth: 320,
        minWideSidebarWidth: 260,
        maxWideSidebarWidth: 400,
        minMainContentWidth: 360,
        mainContent: mainContent,
        sidebarContent: _ConversationList(
          activeId: chat.conversationId,
          onSelect: controller.openConversation,
        ),
        drawerBuilder: (sheetContext) => SheetScaffold(
          titleText: 'Conversations',
          onClose: () => Navigator.of(sheetContext).pop(),
          child: _ConversationList(
            activeId: chat.conversationId,
            onSelect: (id) {
              Navigator.pop(sheetContext);
              controller.openConversation(id);
            },
          ),
        ),
      ),
    );
  }
}

String _agentLabel(List<SnPersonalityAgent> agents, String? agentId) {
  if (agentId == null) return 'Conversation';
  for (final agent in agents) {
    if (agent.id != agentId) continue;
    final name = agent.name.trim();
    return name.isEmpty ? 'Unnamed agent' : name;
  }
  return 'Conversation';
}

/// The live status of the companion: idle (green) or answering (pulsing).
class _StatusDot extends StatefulWidget {
  const _StatusDot({required this.busy});

  final bool busy;

  @override
  State<_StatusDot> createState() => _StatusDotState();
}

class _StatusDotState extends State<_StatusDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );

  @override
  void initState() {
    super.initState();
    if (widget.busy) _controller.repeat();
  }

  @override
  void didUpdateWidget(covariant _StatusDot oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.busy && !_controller.isAnimating) {
      _controller.repeat();
    } else if (!widget.busy && _controller.isAnimating) {
      _controller.stop();
      _controller.value = 0;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox.square(
      dimension: 10,
      child: Stack(
        alignment: Alignment.center,
        children: [
          if (widget.busy)
            AnimatedBuilder(
              animation: _controller,
              builder: (context, child) => Container(
                width: 10 * (0.4 + _controller.value * 0.6),
                height: 10 * (0.4 + _controller.value * 0.6),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: scheme.primary.withValues(
                    alpha: 0.6 - _controller.value * 0.6,
                  ),
                ),
              ),
            ),
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: widget.busy ? scheme.primary : Colors.green,
            ),
          ),
        ],
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message, required this.onDismiss});

  final String message;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Material(
        color: scheme.errorContainer,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        child: Padding(
          padding: const EdgeInsets.only(left: 12, right: 4),
          child: Row(
            children: [
              Icon(
                Symbols.error_rounded,
                size: 18,
                color: scheme.onErrorContainer,
              ),
              const Gap(8),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    message,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onErrorContainer,
                    ),
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Close',
                iconSize: 16,
                onPressed: onDismiss,
                icon: Icon(
                  Symbols.close_rounded,
                  color: scheme.onErrorContainer,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The chat's unauthorized status: what stands in the thread's place when
/// Solar Network will not answer for this session.
///
/// It takes the composer with it — there is nothing to send until the account
/// is signed in again — and carries the sign-in itself, so an expired session
/// costs the reader the turn they were on rather than the whole screen.
class _UnauthorizedState extends StatelessWidget {
  const _UnauthorizedState({
    required this.signedOut,
    required this.agentName,
    this.onRetry,
  });

  /// Whether there is no session at all, as opposed to one the server refused.
  final bool signedOut;

  /// The companion the conversation was with, for the copy.
  final String agentName;

  /// Dismisses the status when the refusal did not hold. Null when there is no
  /// session to retry with.
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Icon(
                Symbols.lock_rounded,
                size: 44,
                color: scheme.onSurfaceVariant,
              ),
              const Gap(12),
              Text(
                'Unauthorized',
                textAlign: TextAlign.center,
                style: theme.textTheme.titleMedium,
              ),
              const Gap(6),
              Text(
                signedOut
                    ? 'Your Solar Network session ended. Sign in to keep '
                          'talking to $agentName.'
                    : 'Solar Network refused the last request. Sign in again '
                          'to keep talking to $agentName.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const Gap(20),
              const SolarSignInPanel(),
              if (onRetry != null) ...[
                const Gap(8),
                TextButton(
                  onPressed: onRetry,
                  child: const Text('Try again'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _InsightThread extends StatelessWidget {
  const _InsightThread({
    required this.bubbles,
    required this.agentName,
    required this.onToggleTrace,
  });

  final List<InsightBubble> bubbles;
  final String agentName;
  final void Function(int index) onToggleTrace;

  @override
  Widget build(BuildContext context) {
    if (bubbles.isEmpty) {
      return _EmptyState(
        icon: Symbols.auto_awesome_rounded,
        title: 'Insight',
        description: 'Send a message to start a conversation with $agentName.',
      );
    }

    // Reversed: the newest row sits at the bottom edge, so a growing streamed
    // reply stays in view without fighting the reader's scroll position.
    return ListView.builder(
      reverse: true,
      padding: const EdgeInsets.fromLTRB(12, 16, 12, 8),
      itemCount: bubbles.length,
      itemBuilder: (context, index) {
        final bubbleIndex = bubbles.length - 1 - index;
        return Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: _BubbleRow(
              bubble: bubbles[bubbleIndex],
              onToggleTrace: () => onToggleTrace(bubbleIndex),
            ),
          ),
        );
      },
    );
  }
}

class _BubbleRow extends StatelessWidget {
  const _BubbleRow({required this.bubble, required this.onToggleTrace});

  final InsightBubble bubble;
  final VoidCallback onToggleTrace;

  @override
  Widget build(BuildContext context) {
    switch (bubble.kind) {
      case InsightBubbleKind.user:
        return _UserBubble(bubble: bubble);
      case InsightBubbleKind.assistant:
        return _AssistantBubble(bubble: bubble);
      case InsightBubbleKind.thinking:
        return _TraceRow(bubble: bubble, onToggle: onToggleTrace);
      case InsightBubbleKind.tool:
        return _ToolTraceRow(bubble: bubble, onToggle: onToggleTrace);
    }
  }
}

/// User turn, styled like the chat room's own bubbles.
class _UserBubble extends StatelessWidget {
  const _UserBubble({required this.bubble});

  final InsightBubble bubble;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Align(
        alignment: Alignment.centerRight,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Material(
            color: scheme.primaryContainer.withValues(alpha: 0.5),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (bubble.attachments.isNotEmpty)
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        for (final fileId in bubble.attachments)
                          _AttachmentThumbnail(fileId: fileId),
                      ],
                    ),
                  if (bubble.text.isNotEmpty)
                    Padding(
                      padding: EdgeInsets.only(
                        top: bubble.attachments.isEmpty ? 0 : 8,
                      ),
                      child: Text(
                        bubble.text,
                        style: TextStyle(
                          color: scheme.onPrimaryContainer,
                          fontSize: 14,
                          height: 1.45,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Assistant reply, on the chat room's remote-message surface.
class _AssistantBubble extends StatelessWidget {
  const _AssistantBubble({required this.bubble});

  final InsightBubble bubble;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Align(
        alignment: Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: Material(
            color: scheme.surfaceContainer,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  MessageMarkdown(text: bubble.text),
                  if (bubble.streaming)
                    const Padding(
                      padding: EdgeInsets.only(top: 6),
                      child: _BlinkingCaret(),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _BlinkingCaret extends StatefulWidget {
  const _BlinkingCaret();

  @override
  State<_BlinkingCaret> createState() => _BlinkingCaretState();
}

class _BlinkingCaretState extends State<_BlinkingCaret>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween<double>(begin: 1, end: 0.15).animate(_controller),
      child: SizedBox(
        width: 8,
        height: 14,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.primary,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
      ),
    );
  }
}

/// Assistant reasoning, folded into one log line until opened.
class _TraceRow extends StatelessWidget {
  const _TraceRow({required this.bubble, required this.onToggle});

  final InsightBubble bubble;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final detailStyle = theme.textTheme.labelSmall?.copyWith(
      fontSize: 11.5,
      height: 1.5,
      color: scheme.onSurfaceVariant,
      fontFamily: 'IBM Plex Mono',
    );
    final snippet = bubble.text.trim().split('\n').first;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onToggle,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    _TraceChevron(collapsed: bubble.collapsed),
                    const Gap(6),
                    Icon(
                      Symbols.psychology_rounded,
                      size: 14,
                      color: scheme.onSurfaceVariant,
                    ),
                    const Gap(4),
                    Text(
                      bubble.streaming ? 'thinking' : 'thought',
                      style: theme.textTheme.labelSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    if (bubble.collapsed && snippet.isNotEmpty) ...[
                      const Gap(6),
                      Expanded(
                        child: Text(
                          snippet,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: detailStyle,
                        ),
                      ),
                    ],
                  ],
                ),
                _TraceDetail(
                  collapsed: bubble.collapsed,
                  child: SelectableText(bubble.text, style: detailStyle),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ToolTraceRow extends StatelessWidget {
  const _ToolTraceRow({required this.bubble, required this.onToggle});

  final InsightBubble bubble;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final detailStyle = theme.textTheme.labelSmall?.copyWith(
      fontSize: 11.5,
      height: 1.5,
      color: scheme.onSurfaceVariant,
      fontFamily: 'IBM Plex Mono',
    );
    final labelStyle = theme.textTheme.labelSmall?.copyWith(
      color: scheme.outline,
      letterSpacing: 0.5,
    );
    final args = bubble.toolArgs;
    final result = bubble.toolResult;
    final failed = result == kPersonalityToolResultUnknownTool;
    final resultLabel = result == null ? '' : _toolResultLabel(result);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onToggle,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    _TraceChevron(collapsed: bubble.collapsed),
                    const Gap(6),
                    if (bubble.toolRunning)
                      const SizedBox.square(
                        dimension: 12,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    else if (failed)
                      Icon(Symbols.error_rounded, size: 14, color: scheme.error)
                    else
                      Icon(
                        Symbols.build_rounded,
                        size: 14,
                        color: scheme.onSurfaceVariant,
                      ),
                    const Gap(6),
                    Text(
                      bubble.text,
                      style: theme.textTheme.labelSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (bubble.collapsed && resultLabel.isNotEmpty) ...[
                      const Gap(6),
                      Expanded(
                        child: Text(
                          resultLabel.replaceAll(RegExp(r'\s+'), ' ').trim(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: detailStyle,
                        ),
                      ),
                    ],
                  ],
                ),
                _TraceDetail(
                  collapsed: bubble.collapsed,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (args != null && args.isNotEmpty) ...[
                        Text('arguments', style: labelStyle),
                        const Gap(2),
                        SelectableText(
                          _formatToolArgs(args),
                          style: detailStyle,
                        ),
                      ],
                      if (resultLabel.isNotEmpty) ...[
                        const Gap(8),
                        Text('result', style: labelStyle),
                        const Gap(2),
                        SelectableText(resultLabel, style: detailStyle),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _TraceChevron extends StatelessWidget {
  const _TraceChevron({required this.collapsed});

  final bool collapsed;

  @override
  Widget build(BuildContext context) {
    return AnimatedRotation(
      turns: collapsed ? 0 : 0.25,
      duration: const Duration(milliseconds: 180),
      child: Icon(
        Symbols.chevron_right_rounded,
        size: 16,
        color: Theme.of(context).colorScheme.outline,
      ),
    );
  }
}

/// The folded-away half of a trace row.
class _TraceDetail extends StatelessWidget {
  const _TraceDetail({required this.collapsed, required this.child});

  final bool collapsed;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AnimatedCrossFade(
      duration: const Duration(milliseconds: 180),
      firstChild: const SizedBox(width: double.infinity, height: 0),
      secondChild: Padding(
        padding: const EdgeInsets.only(left: 22, top: 6, right: 8),
        child: child,
      ),
      crossFadeState: collapsed
          ? CrossFadeState.showFirst
          : CrossFadeState.showSecond,
    );
  }
}

String _toolResultLabel(String result) {
  switch (result) {
    case kPersonalityToolResultInterrupted:
      return 'interrupted';
    case kPersonalityToolResultEarlierTurn:
      return 'earlier turn';
    case kPersonalityToolResultUnknownTool:
      return 'unknown tool';
    default:
      return result;
  }
}

String _formatToolArgs(Map<String, dynamic> args) {
  try {
    return const JsonEncoder.withIndent('  ').convert(args);
  } catch (_) {
    return args.toString();
  }
}

/// The composer, wearing the chat room's rounded elevated surface.
class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.focusNode,
    required this.attachments,
    required this.busy,
    required this.enterToSend,
    required this.onSend,
    required this.onStop,
    required this.onPickAttachments,
    required this.onRemoveAttachment,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final List<String> attachments;
  final bool busy;
  final bool enterToSend;
  final VoidCallback onSend;
  final VoidCallback onStop;
  final VoidCallback? onPickAttachments;
  final void Function(int index) onRemoveAttachment;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        12,
        8,
        12,
        12 + MediaQuery.paddingOf(context).bottom,
      ),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: Material(
            elevation: 0,
            color: scheme.surfaceContainerHighest,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(24),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (attachments.isNotEmpty) ...[
                    const Gap(4),
                    SizedBox(
                      height: 64,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        itemCount: attachments.length,
                        separatorBuilder: (_, _) => const Gap(8),
                        itemBuilder: (context, index) => _PendingAttachment(
                          fileId: attachments[index],
                          onRemove: () => onRemoveAttachment(index),
                        ),
                      ),
                    ),
                  ],
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      IconButton(
                        tooltip: 'Attach images',
                        onPressed: busy || onPickAttachments == null
                            ? null
                            : onPickAttachments,
                        icon: const Icon(Symbols.attach_file_rounded),
                      ),
                      Expanded(
                        child: TextField(
                          controller: controller,
                          focusNode: focusNode,
                          maxLines: 5,
                          minLines: 1,
                          textCapitalization: TextCapitalization.sentences,
                          textInputAction: enterToSend
                              ? TextInputAction.send
                              : TextInputAction.newline,
                          onSubmitted: enterToSend ? (_) => onSend() : null,
                          onTapOutside: (_) =>
                              FocusManager.instance.primaryFocus?.unfocus(),
                          decoration: InputDecoration(
                            hintText: 'Message the companion…',
                            border: InputBorder.none,
                            focusedBorder: InputBorder.none,
                            isDense: true,
                            // The composer is the field's surface; a second
                            // fill would paint a box inside it.
                            filled: false,
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 12,
                            ),
                          ),
                        ),
                      ),
                      ValueListenableBuilder<TextEditingValue>(
                        valueListenable: controller,
                        builder: (context, value, _) {
                          final canSend =
                              value.text.trim().isNotEmpty ||
                              attachments.isNotEmpty;
                          return IconButton.filled(
                            tooltip: busy ? 'Stop' : 'Send',
                            onPressed: busy
                                ? onStop
                                : (canSend ? onSend : null),
                            icon: Icon(
                              busy
                                  ? Symbols.stop_circle_rounded
                                  : Symbols.send_rounded,
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PendingAttachment extends StatelessWidget {
  const _PendingAttachment({required this.fileId, required this.onRemove});

  final String fileId;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox.square(
      dimension: 60,
      child: Stack(
        children: [
          Positioned.fill(
            child: _AttachmentThumbnail(fileId: fileId, size: 60),
          ),
          Positioned(
            top: 0,
            right: 0,
            child: IconButton(
              tooltip: 'Delete',
              iconSize: 12,
              visualDensity: VisualDensity.compact,
              style: IconButton.styleFrom(
                backgroundColor: scheme.surfaceContainerHighest,
                minimumSize: const Size(20, 20),
                padding: EdgeInsets.zero,
              ),
              onPressed: onRemove,
              icon: const Icon(Symbols.close_rounded),
            ),
          ),
        ],
      ),
    );
  }
}

class _AttachmentThumbnail extends StatelessWidget {
  const _AttachmentThumbnail({required this.fileId, this.size = 96});

  final String fileId;
  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Icon(
        Symbols.image_rounded,
        size: size * 0.4,
        color: scheme.onSurfaceVariant,
      ),
    );
  }
}

class _ConversationList extends ConsumerWidget {
  const _ConversationList({required this.activeId, required this.onSelect});

  final String? activeId;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    // Watched here rather than captured by the host, so the wide-screen panel
    // and the sheet always render current data.
    final conversationsAsync = ref.watch(personalityConversationsProvider);
    final conversations =
        conversationsAsync.value ?? const <SnPersonalityConversation>[];
    final loading = conversationsAsync.isLoading;
    final error = conversationsAsync.hasError
        ? 'Failed to load conversations: '
              '${personalityErrorMessage(conversationsAsync.error!)}'
        : null;
    final agentNames = {
      for (final agent
          in ref.watch(personalityAgentsProvider).value ??
              const <SnPersonalityAgent>[])
        agent.id: agent.name.trim().isEmpty
            ? 'Unnamed agent'
            : agent.name.trim(),
    };

    if (error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                error,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(color: scheme.error),
              ),
              const Gap(8),
              TextButton(
                onPressed: () =>
                    ref.invalidate(personalityConversationsProvider),
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    if (conversations.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: loading
              ? const CircularProgressIndicator()
              : Text(
                  'No conversations yet',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
        ),
      );
    }

    // Rows follow the chat list: a Material surface that tints when selected,
    // with the timestamp trailing the title.
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      itemCount: conversations.length,
      itemBuilder: (context, index) {
        final conversation = conversations[index];
        final selected = conversation.id == activeId;
        final title = conversation.title.trim();
        final lastMessageAt = conversation.lastMessageAt;
        return Material(
          color: selected
              ? scheme.secondaryContainer.withValues(alpha: 0.55)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => onSelect(conversation.id),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          title.isEmpty ? 'Untitled' : title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w600,
                            letterSpacing: -0.1,
                            height: 1.2,
                          ),
                        ),
                      ),
                      if (lastMessageAt != null) ...[
                        const Gap(8),
                        Text(
                          _formatRelative(lastMessageAt),
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: scheme.onSurfaceVariant.withValues(
                              alpha: 0.85,
                            ),
                            fontWeight: FontWeight.w500,
                            height: 1.2,
                          ),
                        ),
                      ],
                    ],
                  ),
                  const Gap(3),
                  Text(
                    agentNames[conversation.agentId] ?? 'Conversation',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant.withValues(alpha: 0.85),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// A quiet centered placeholder: icon over a title and a one-line hint.
class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.icon,
    required this.title,
    this.description,
  });

  final IconData icon;
  final String title;
  final String? description;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 44, color: scheme.onSurfaceVariant),
            const Gap(10),
            Text(title, style: theme.textTheme.titleSmall),
            if (description != null) ...[
              const Gap(4),
              Text(
                description!,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

String _two(int value) => value.toString().padLeft(2, '0');

/// A tiny relative-time label for conversation timestamps.
String _formatRelative(DateTime time) {
  final local = time.toLocal();
  final now = DateTime.now();
  final diff = now.difference(local);
  if (diff.inSeconds < 60) return 'just now';
  if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
  if (diff.inHours < 24 && now.day == local.day) {
    return '${diff.inHours}h ago';
  }
  if (diff.inDays < 7) return '${diff.inDays}d ago';
  return '${local.year}-${_two(local.month)}-${_two(local.day)}';
}
