import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:auto_route/auto_route.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
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
import 'package:persynth/personality/personality_network.dart';
import 'package:persynth/personality/personality_service.dart';
import 'package:persynth/personality/reasoning_settings.dart';
import 'package:persynth/router.dart';
import 'package:persynth/theme/app_theme.dart';
import 'package:persynth/widgets/drive_image.dart';
import 'package:persynth/widgets/media_lightbox.dart';
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

    final inputController = useTextEditingController();
    final focusNode = useFocusNode();
    // The paste detector needs the text as it was before the field last
    // changed; the guard swallows the change it makes while taking a pasted
    // block back out of the field.
    final lastInput = useRef('');
    final restoringInput = useRef(false);
    final wideScreen = isWideScreen(context);
    // Drives the ResponsiveSidebar: an open panel when wide, an on-demand sheet
    // when narrow (so a phone never lands on an unexpected sheet).
    final showConversations = useState(wideScreen);

    final agentId = chat.agentId ?? (agents.isEmpty ? null : agents.first.id);
    final agentName = _agentLabel(agents, agentId);
    final conversationUsage = chat.conversationUsage;

    void handleSend() {
      if (chat.busy) return;
      // The send button is disabled while a queued file is still going up, or
      // after one failed; Enter has to hold the same line, or a turn could leave
      // without the attachment it was written for.
      if (chat.attachmentsUploading || chat.attachmentsFailed) return;
      final text = inputController.text;
      if (text.trim().isEmpty && chat.pendingAttachments.isEmpty) return;
      inputController.clear();
      focusNode.requestFocus();
      controller.send(text);
    }

    /// A block pasted whole into the field becomes an attachment instead: the
    /// composer keeps the message, the document keeps the document — and stays
    /// editable, since the text has not left this device yet.
    void handleInputChanged(String value) {
      final previous = lastInput.value;
      lastInput.value = value;
      if (restoringInput.value) {
        restoringInput.value = false;
        return;
      }
      final inserted = _insertedBlock(previous, value);
      if (inserted == null ||
          inserted.text.length < kPasteTextAttachmentChars) {
        return;
      }
      restoringInput.value = true;
      inputController.value = TextEditingValue(
        text: previous,
        selection: TextSelection.collapsed(offset: inserted.start),
      );
      controller.attachText(inserted.text);
    }

    Future<void> editTextAttachment(int index) async {
      if (index < 0 || index >= chat.pendingAttachments.length) return;
      final attachment = chat.pendingAttachments[index];
      if (!attachment.isText) return;
      final edited = await showDialog<String>(
        context: context,
        builder: (_) => _TextAttachmentDialog(
          name: attachment.name,
          text: attachment.text ?? '',
        ),
      );
      if (edited == null || !context.mounted) return;
      controller.updatePendingText(index, edited);
    }

    /// Picks images and hands them to the queue, which uploads them and reports
    /// on each tile as it goes. Nothing here waits for the network: the reader
    /// sees the files they chose, and a second pick joins the first.
    Future<void> pickAttachments() async {
      final picked = await FilePicker.pickFiles(type: FileType.image);
      if (picked.isEmpty || !context.mounted) return;
      controller.queueImages([
        for (final file in picked)
          if (file.path case final path?)
            InsightPickedImage(
              name: file.name,
              path: path,
              byteSize: file.lengthSync(),
              contentType: _imageContentType(file.extension),
            ),
      ]);
    }

    /// Opens the attach sheet and carries out what it hands back: a file the
    /// drive already holds is linked by id, and nothing leaves this device; the
    /// reader's own device is a pick, which uploads as it always has.
    Future<void> attach() async {
      final selection = await showModalBottomSheet<_AttachSelection>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        builder: (sheetContext) =>
            _AttachmentSheet(onClose: () => Navigator.of(sheetContext).pop()),
      );
      if (selection == null || !context.mounted) return;
      final file = selection.file;
      if (file == null) {
        await pickAttachments();
        return;
      }
      controller.linkCloudFile(fileId: file.id, name: file.displayName);
    }

    // On a narrow screen there is no room for a docked panel, so the thread
    // list becomes an on-demand sheet. It is opened with Flutter's own bottom
    // sheet rather than the sidebar's: `ResponsiveSidebar` builds its sheet on
    // the `material_ui` fork and asks for that fork's `MaterialLocalizations`,
    // which this app — a Flutter `MaterialApp` — never installs, so its sheet
    // fails to open. The wide panel still uses the sidebar.
    void openConversationsSheet() {
      showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        builder: (sheetContext) => SheetScaffold(
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
      );
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
                  busy: chat.busy,
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
            usage: conversationUsage,
            onSend: handleSend,
            onStop: controller.stop,
            onInputChanged: handleInputChanged,
            onAttach: attach,
            onEditAttachment: chat.busy ? null : editTextAttachment,
            onRemoveAttachment: chat.busy
                ? null
                : controller.removePendingAttachment,
            onRetryAttachment: chat.busy ? null : controller.retryAttachment,
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
              if (wideScreen) {
                showConversations.value = !showConversations.value;
              } else {
                openConversationsSheet();
              }
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
      // The docked panel is a wide-screen affordance; on a narrow screen the
      // header button opens the thread list as a sheet instead (see
      // `openConversationsSheet`).
      body: wideScreen
          ? ResponsiveSidebar(
              sidebarElevation: 0,
              showSidebar: showConversations,
              sidebarWidth: 320,
              minWideSidebarWidth: 260,
              maxWideSidebarWidth: 400,
              minMainContentWidth: 360,
              mainContent: ColoredBox(
                color: Theme.of(context).colorScheme.surfaceContainer,
                child: ClipRRect(
                  borderRadius: const BorderRadius.only(
                    topRight: Radius.circular(12),
                    topLeft: Radius.circular(12),
                  ),
                  child: Material(
                    color: Theme.of(context).colorScheme.surface,
                    child: mainContent,
                  ),
                ),
              ),
              sidebarContent: _ConversationList(
                activeId: chat.conversationId,
                onSelect: controller.openConversation,
              ),
            )
          : mainContent,
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
                TextButton(onPressed: onRetry, child: const Text('Try again')),
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
    required this.busy,
    required this.onToggleTrace,
  });

  final List<InsightBubble> bubbles;
  final String agentName;

  /// A turn is in flight: its rows are already streaming in, and the
  /// indicator below them holds the assistant's slot until the turn ends.
  final bool busy;

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
    // reply stays in view without fighting the reader's scroll position. The
    // turn indicator is that newest row while a turn runs — one for the whole
    // turn, not one trailing each message.
    return ListView.builder(
      reverse: true,
      padding: const EdgeInsets.fromLTRB(12, 16, 12, 8),
      itemCount: bubbles.length + (busy ? 1 : 0),
      itemBuilder: (context, index) {
        final Widget row;
        if (busy && index == 0) {
          row = const _TurnIndicator();
        } else {
          final bubbleIndex = bubbles.length - 1 - (busy ? index - 1 : index);
          row = _BubbleRow(
            bubble: bubbles[bubbleIndex],
            onToggleTrace: () => onToggleTrace(bubbleIndex),
          );
        }
        return Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: row,
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

/// The [Hero] tags pictures travel under, split by the surface they were
/// tapped on: the same attachment can sit on the composer's strip and in the
/// sent bubble within one frame, and tags have to stay unique per route.
const String _kStripSurface = 'strip';
const String _kBubbleSurface = 'sent';

/// The pictures of [attachments] a lightbox can show, in the order they ride
/// the turn, each pinned to the tag its thumbnail carries.
///
/// A picture is read from the file on this device while the device still has
/// it, and from the drive otherwise — the same choice the tile makes, made
/// again here so the viewer opens on the bytes the reader was looking at. An
/// attachment with neither is left out: an upload that has not come back has
/// nothing to show yet.
List<MediaLightboxItem> _lightboxImages(
  List<InsightAttachment> attachments, {
  required String surface,
  required String? token,
  required String driveBaseUrl,
}) {
  final bearer = token?.trim() ?? '';
  final items = <MediaLightboxItem>[];
  for (final attachment in attachments) {
    if (attachment.isText) continue;
    final path = attachment.localPath?.trim() ?? '';
    final fileId = attachment.fileId?.trim() ?? '';
    final ImageProvider? provider;
    if (path.isNotEmpty && !kIsWeb && File(path).existsSync()) {
      provider = FileImage(File(path));
    } else if (fileId.isNotEmpty && bearer.isNotEmpty) {
      provider = NetworkImage(
        PersonalityCoreService.driveFileUrl(driveBaseUrl, fileId),
        headers: {'Authorization': 'Bearer $bearer'},
      );
    } else {
      provider = null;
    }
    if (provider == null) continue;
    items.add(
      MediaLightboxItem(
        provider: provider,
        name: attachment.name,
        heroTag: '$surface:${attachment.id}',
      ),
    );
  }
  return items;
}

/// Opens [attachments] in the lightbox at the picture [attachmentId] names,
/// growing out of the thumbnail carrying that surface's tag.
void _openAttachmentLightbox(
  BuildContext context,
  WidgetRef ref, {
  required List<InsightAttachment> attachments,
  required String surface,
  required int attachmentId,
}) {
  final items = _lightboxImages(
    attachments,
    surface: surface,
    token: ref.read(solarAccessTokenProvider).value,
    driveBaseUrl: ref.read(personalityDriveBaseUrlProvider),
  );
  final index = items.indexWhere(
    (item) => item.heroTag == '$surface:$attachmentId',
  );
  if (index < 0) return;
  showMediaLightbox(context, items: items, initialIndex: index);
}

/// User turn, styled like the chat room's own bubbles.
class _UserBubble extends ConsumerWidget {
  const _UserBubble({required this.bubble});

  /// The square a sent image is shown in — the same one the composer's strip
  /// uses, so a picture looks the same before and after it is sent.
  static const double _sentImageSize = 96;

  final InsightBubble bubble;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
                        for (final attachment in bubble.attachments)
                          if (attachment.isText)
                            _TextAttachmentChip(attachment: attachment)
                          else
                            Tooltip(
                              message: attachment.name,
                              child: GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onTap: () => _openAttachmentLightbox(
                                  context,
                                  ref,
                                  attachments: bubble.attachments,
                                  surface: _kBubbleSurface,
                                  attachmentId: attachment.id,
                                ),
                                child: SizedBox.square(
                                  dimension: _sentImageSize,
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(12),
                                    child: Hero(
                                      tag:
                                          '$_kBubbleSurface:${attachment.id}',
                                      child: _AttachmentPicture(
                                        attachment: attachment,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
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
                children: [MessageMarkdown(text: bubble.text)],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A token count short enough for a one-line footer: `512`, `12.4k`, `57.5k`,
/// `128k`, `1.2M`. A tenth is kept while it still says something.
String _formatTokens(int value) {
  if (value < 1000) return '$value';
  final thousands = value / 1000;
  if (thousands < 1000) return _scaled(thousands, 'k');
  return _scaled(value / 1000000, 'M');
}

/// A share of the context window: precise while it is small, coarse once it is
/// not.
String _formatPercent(double ratio) {
  final percent = ratio * 100;
  if (percent < 1) return '${percent.toStringAsFixed(2)}%';
  if (percent < 10) return '${percent.toStringAsFixed(1)}%';
  return '${percent.toStringAsFixed(0)}%';
}

/// `12.43` with `k` is `12.4k`; `1.0` is just `1k`.
String _scaled(double value, String suffix) {
  final text = value.toStringAsFixed(value < 100 ? 1 : 0);
  final trimmed = text.endsWith('.0')
      ? text.substring(0, text.length - 2)
      : text;
  return '$trimmed$suffix';
}

/// The numbers beside the context meter: the fullest prompt the conversation
/// has sent against the model's window, then its running total. The window is
/// only stated when the server knows it; without one the prompt size still
/// says something.
String _contextSummary(SnConversationUsage usage) {
  final parts = <String>[];
  final used = usage.peakContextUsedTokens;
  final window = usage.contextWindowTokens;
  if (used != null && window != null && window > 0) {
    parts.add('${_formatTokens(used)} / ${_formatTokens(window)}');
  } else if (used != null) {
    parts.add('context ${_formatTokens(used)}');
  }
  if (usage.totalTokens > 0) {
    parts.add('${_formatTokens(usage.totalTokens)} tok');
  }
  if (usage.runs > 0) {
    parts.add('${usage.runs} ${usage.runs == 1 ? 'run' : 'runs'}');
  }
  return parts.join(' · ');
}

/// The MIME type a picked image is stored as, from the extension the picker
/// reported. The drive records it, and the server hands it to the model with
/// the image part, so it is worth stating exactly; an extension this does not
/// know sends nothing and leaves the file server to sniff it.
String? _imageContentType(String? extension) =>
    switch (extension?.toLowerCase()) {
      'png' => 'image/png',
      'jpg' || 'jpeg' => 'image/jpeg',
      'gif' => 'image/gif',
      'webp' => 'image/webp',
      'avif' => 'image/avif',
      'heic' => 'image/heic',
      'heif' => 'image/heif',
      'bmp' => 'image/bmp',
      'tif' || 'tiff' => 'image/tiff',
      _ => null,
    };

/// The full sentence behind the meter, for the pointer that hovers it and the
/// reader a screen reader announces it to.
String _contextTooltip(SnConversationUsage usage) {
  final parts = <String>[];
  final used = usage.peakContextUsedTokens;
  final window = usage.contextWindowTokens;
  if (used != null && window != null && window > 0) {
    final percent = _formatPercent(used / window);
    parts.add(
      'Context ${_formatTokens(used)} of ${_formatTokens(window)} tokens '
      '($percent)',
    );
  } else if (used != null) {
    parts.add('Context ${_formatTokens(used)} tokens');
  }
  if (usage.totalTokens > 0) {
    parts.add('${_formatTokens(usage.totalTokens)} tokens spent total');
  }
  if (usage.runs > 0) {
    parts.add('${usage.runs} ${usage.runs == 1 ? 'run' : 'runs'}');
  }
  return parts.isEmpty ? 'No usage recorded yet' : parts.join('\n');
}

/// The turn in flight: the assistant's slot in the log, holding the typing
/// dots until the turn ends — one indicator per turn, not one trailing each
/// row, so a turn that reasons, calls tools and then answers reads as one
/// continuous piece of work.
///
/// The dots are Solian's: a 1.2s cycle where each dot grows, darkens and lifts
/// just ahead of the next, so the row ripples instead of blinking as one.
class _TurnIndicator extends StatefulWidget {
  const _TurnIndicator();

  @override
  State<_TurnIndicator> createState() => _TurnIndicatorState();
}

class _TurnIndicatorState extends State<_TurnIndicator>
    with SingleTickerProviderStateMixin {
  static const _dotCount = 3;

  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// Where dot [index] sits in its own cycle: starts later than the dot before
  /// it, so the phase is what moves along the row.
  double _phase(int index, double offset) =>
      (_controller.value - index * offset) % 1.0;

  /// Size and darkness: up over the first 55% of the cycle, down over the rest.
  double _progress(int index) {
    final phase = _phase(index, 0.14);
    return phase < 0.55
        ? Curves.easeOutCubic.transform(phase / 0.55)
        : 1 - Curves.easeInCubic.transform((phase - 0.55) / 0.45);
  }

  /// The bounce: a single pixel, offset from [index]'s size cycle.
  double _lift(int index) {
    final phase = _phase(index, 0.16);
    return phase < 0.5
        ? Curves.easeOut.transform(phase / 0.5)
        : 1 - Curves.easeIn.transform((phase - 0.5) / 0.5);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dot = scheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Semantics(
          label: 'Waiting for the reply',
          child: Material(
            color: scheme.surfaceContainer,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            // The padding lands on a one-line reply's height, so the slot the
            // dots hold is the slot the reply will fill.
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
              child: SizedBox(
                width: 28,
                height: 12,
                child: AnimatedBuilder(
                  animation: _controller,
                  builder: (context, child) => Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: List.generate(_dotCount, (index) {
                      final progress = _progress(index);
                      final size = 3.4 + progress * 1.8;
                      return Transform.translate(
                        offset: Offset(0, -_lift(index)),
                        child: Container(
                          margin: const EdgeInsets.symmetric(horizontal: 1.5),
                          width: size,
                          height: size,
                          decoration: BoxDecoration(
                            color: Color.lerp(
                              dot.withValues(alpha: 0.32),
                              dot,
                              progress,
                            ),
                            shape: BoxShape.circle,
                          ),
                        ),
                      );
                    }),
                  ),
                ),
              ),
            ),
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
      fontFamily: PersynthFonts.mono,
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
      fontFamily: PersynthFonts.mono,
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
///
/// Under the input sits the instrument strip — the reasoning-effort pill on the
/// left and the conversation's context ring on the right. They are the two
/// dials for how the companion is about to think, set where the message is
/// written rather than buried in settings.
class _Composer extends ConsumerWidget {
  const _Composer({
    required this.controller,
    required this.focusNode,
    required this.attachments,
    required this.busy,
    required this.enterToSend,
    required this.usage,
    required this.onSend,
    required this.onStop,
    required this.onInputChanged,
    required this.onAttach,
    required this.onEditAttachment,
    required this.onRemoveAttachment,
    required this.onRetryAttachment,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final List<InsightAttachment> attachments;
  final bool busy;
  final bool enterToSend;

  /// The conversation's running tokens and context, or null before one exists.
  final SnConversationUsage? usage;

  final VoidCallback onSend;
  final VoidCallback onStop;
  final ValueChanged<String> onInputChanged;

  /// Opens the attach sheet: a file on this device to upload, or one the drive
  /// already holds to link.
  final VoidCallback? onAttach;

  /// Opens one queued text attachment for editing.
  final void Function(int index)? onEditAttachment;

  /// Drops one queued attachment, aborting its upload if it is still going up.
  /// Null while the turn that owns the queue is in flight.
  final void Function(int index)? onRemoveAttachment;

  /// Sends a failed attachment up again. Null while a turn is in flight.
  final void Function(int index)? onRetryAttachment;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
                          attachment: attachments[index],
                          onOpen: () => _openAttachmentLightbox(
                            context,
                            ref,
                            attachments: attachments,
                            surface: _kStripSurface,
                            attachmentId: attachments[index].id,
                          ),
                          onRemove: onRemoveAttachment == null
                              ? null
                              : () => onRemoveAttachment!(index),
                          onEdit: onEditAttachment == null
                              ? null
                              : () => onEditAttachment!(index),
                          onRetry: onRetryAttachment == null
                              ? null
                              : () => onRetryAttachment!(index),
                        ),
                      ),
                    ),
                  ],
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      IconButton(
                        tooltip: 'Attach',
                        onPressed: busy || onAttach == null ? null : onAttach,
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
                          onChanged: onInputChanged,
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
                          // A file still going up, or one that failed, keeps the
                          // turn here: what was written and what would be sent
                          // have to be the same thing.
                          final uploading = attachments
                              .where((attachment) => attachment.isUploading)
                              .length;
                          final failed = attachments.any(
                            (attachment) => attachment.hasFailed,
                          );
                          final canSend =
                              !failed &&
                              uploading == 0 &&
                              (value.text.trim().isNotEmpty ||
                                  attachments.any(
                                    (attachment) => attachment.isSendable,
                                  ));
                          return IconButton.filled(
                            tooltip: busy
                                ? 'Stop'
                                : uploading > 0
                                ? 'Waiting for ${uploading == 1 ? 'an attachment' : '$uploading attachments'}…'
                                : failed
                                ? 'An attachment failed to upload'
                                : 'Send',
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
                  const Gap(2),
                  _ComposerFooter(usage: usage),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The strip under the input: how hard the companion thinks, and how full its
/// context is. The reasoning pill is the one thing here that is a control; the
/// context readout is a report.
class _ComposerFooter extends StatelessWidget {
  const _ComposerFooter({required this.usage});

  final SnConversationUsage? usage;

  @override
  Widget build(BuildContext context) {
    final usage = this.usage;
    // A total the server reported but never filled is not a status worth
    // showing, so an empty reading leaves the right side blank.
    final hasUsage =
        usage != null &&
        (usage.totalTokens > 0 ||
            usage.runs > 0 ||
            usage.peakContextUsedTokens != null);
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 0, 8, 4),
      child: Row(
        children: [
          const _ReasoningControl(),
          const SizedBox(width: 12),
          Expanded(
            child: Align(
              alignment: Alignment.centerRight,
              child: hasUsage
                  ? _ContextStatus(usage: usage)
                  : const SizedBox.shrink(),
            ),
          ),
        ],
      ),
    );
  }
}

/// The reasoning-effort pill, living where the message is written rather than
/// in settings: the level is a property of the turn about to be sent.
///
/// Three levels, because this strip has room for a dial, not a menu: `Low`,
/// `Medium` and `High` are the choices a reader can hold in mind, and the
/// wider set the backend documents is still stored under its own token for
/// anything that wrote one. No level lit is the model's own default — which is
/// also where tapping the lit level again returns, so the untouched state is
/// never lost once the pill has been touched.
class _ReasoningControl extends ConsumerWidget {
  const _ReasoningControl();

  /// The levels the pill offers, in the order it shows them.
  static const _levels = [
    ReasoningSetting.low,
    ReasoningSetting.medium,
    ReasoningSetting.high,
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final setting = ref.watch(reasoningSettingProvider);
    // A level the pill does not offer — the model's default, or an `off` a
    // previous build stored — leaves the pill unlit and says so in the tooltip
    // rather than lighting a level the run would not be sent.
    final active = _levels.contains(setting) ? setting : null;

    void choose(ReasoningSetting level) => ref
        .read(reasoningSettingProvider.notifier)
        .set(level == active ? ReasoningSetting.modelDefault : level);

    return Tooltip(
      message: active == null
          ? 'Reasoning effort: ${setting.label}'
          : 'Reasoning effort: ${setting.label}\n'
                'Tap again for the model default',
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Padding(
          padding: const EdgeInsets.all(2),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.only(left: 5, right: 4),
                child: Icon(
                  Symbols.psychology_rounded,
                  size: 14,
                  color: scheme.onSurfaceVariant,
                ),
              ),
              for (final level in _levels)
                _ReasoningSegment(
                  label: level.label,
                  selected: level == active,
                  onTap: () => choose(level),
                ),
              const SizedBox(width: 4),
            ],
          ),
        ),
      ),
    );
  }
}

/// One level in the [ReasoningControl] pill: the lit one wears the accent's
/// tint, the rest stay at rest so the pill's colour keeps meaning the reader
/// made a choice.
class _ReasoningSegment extends StatelessWidget {
  const _ReasoningSegment({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);

    return Semantics(
      selected: selected,
      button: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: AnimatedContainer(
          duration: reduceMotion
              ? Duration.zero
              : const Duration(milliseconds: 160),
          curve: Curves.easeOut,
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
          decoration: BoxDecoration(
            color: selected ? scheme.primaryContainer : Colors.transparent,
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              fontSize: 11,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
              color: selected
                  ? scheme.onPrimaryContainer
                  : scheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }
}

/// The conversation's memory gauge: a ring for the fullest context the model
/// has seen, then the numbers behind it. Quiet at rest; the ring warms to the
/// accent as the window fills, and to the error tone at its end.
class _ContextStatus extends StatelessWidget {
  const _ContextStatus({required this.usage});

  final SnConversationUsage usage;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final used = usage.peakContextUsedTokens;
    final window = usage.contextWindowTokens;
    final hasWindow = used != null && window != null && window > 0;

    return Tooltip(
      message: _contextTooltip(usage),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (hasWindow) ...[_ContextRing(ratio: used / window), const Gap(8)],
          Flexible(
            child: Text(
              _contextSummary(usage),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(
                fontSize: 11,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The conversation's memory gauge: a ring for the fullest context the model
/// has seen, filled clockwise from the top. It carries no numbers of its own;
/// the label beside it does. Quiet at rest; the arc warms to the accent as the
/// window fills, and to the error tone at its end.
class _ContextRing extends StatelessWidget {
  const _ContextRing({required this.ratio});

  final double ratio;

  /// Big enough to read a share off, small enough to sit on a one-line footer.
  static const _diameter = 20.0;
  static const _stroke = 2.4;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fill = switch (ratio.clamp(0.0, 1.0)) {
      >= 0.95 => scheme.error,
      >= 0.8 => scheme.primary,
      _ => scheme.onSurfaceVariant,
    };
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    return SizedBox.square(
      dimension: _diameter,
      child: TweenAnimationBuilder<double>(
        tween: Tween<double>(begin: 0, end: ratio.clamp(0.0, 1.0)),
        duration: reduceMotion
            ? Duration.zero
            : const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
        builder: (context, value, _) => CustomPaint(
          painter: _ContextRingPainter(
            value: value,
            // The composer's own surface is a hairline tone away from
            // `outlineVariant`, so the track is the fill's colour thinned until
            // it reads as a ring rather than a hole.
            track: scheme.onSurfaceVariant.withValues(alpha: 0.28),
            fill: fill,
            stroke: _stroke,
          ),
        ),
      ),
    );
  }
}

/// The ring itself: a full track with the filled share of it drawn from the
/// top clockwise, so a nearly empty window still reads as a ring rather than a
/// dot.
class _ContextRingPainter extends CustomPainter {
  const _ContextRingPainter({
    required this.value,
    required this.track,
    required this.fill,
    required this.stroke,
  });

  /// The share of the window to sweep, 0…1.
  final double value;
  final Color track;
  final Color fill;
  final double stroke;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = (size.shortestSide - stroke) / 2;
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..color = track,
    );
    if (value <= 0) return;
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -math.pi / 2,
      2 * math.pi * value,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..strokeCap = StrokeCap.round
        ..color = fill,
    );
  }

  @override
  bool shouldRepaint(_ContextRingPainter oldDelegate) =>
      oldDelegate.value != value ||
      oldDelegate.track != track ||
      oldDelegate.fill != fill ||
      oldDelegate.stroke != stroke;
}

/// One queued attachment on the composer's strip: a text card, or an image with
/// whatever its upload has to say drawn over it.
class _PendingAttachment extends StatelessWidget {
  const _PendingAttachment({
    required this.attachment,
    required this.onRemove,
    this.onEdit,
    this.onRetry,
    this.onOpen,
  });

  /// The tile's height, and the width of an image in it.
  static const double _size = 60;

  final InsightAttachment attachment;
  final VoidCallback? onRemove;

  /// Opens the text for editing. Null for a picked image, which has nothing to
  /// edit here.
  final VoidCallback? onEdit;

  /// Sends a failed attachment up again, from the tile itself: the file is
  /// still queued, so the way out is next to the problem.
  final VoidCallback? onRetry;

  /// Opens the picture in the lightbox. Null for a text attachment, which has
  /// no picture to open.
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: attachment.isText ? 190 : _size,
      height: _size,
      child: Stack(
        children: [
          Positioned.fill(
            child: attachment.isText
                ? _TextAttachmentCard(attachment: attachment, onTap: onEdit)
                : _ImageAttachmentTile(
                    attachment: attachment,
                    onRetry: onRetry,
                    onOpen: onOpen,
                  ),
          ),
          Positioned(
            top: 0,
            right: 0,
            child: IconButton(
              tooltip: 'Delete',
              iconSize: 12,
              visualDensity: VisualDensity.compact,
              style: IconButton.styleFrom(
                backgroundColor: Theme.of(
                  context,
                ).colorScheme.surfaceContainerHighest,
                minimumSize: const Size(20, 20),
                padding: EdgeInsets.zero,
                // Without this the button keeps a 48-pixel tap target, which on
                // a 60-pixel tile covers the tile it sits on.
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
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

/// A picked or linked image on the composer's strip. The picture is the file
/// on this device while there is one — what was picked is what is shown, with
/// no request standing between the reader and their own file — and the drive's
/// copy once the file is only an id, which is all a linked file ever is. The
/// upload draws on top: how far it has got while it goes, and a retry once it
/// has failed.
class _ImageAttachmentTile extends StatelessWidget {
  const _ImageAttachmentTile({
    required this.attachment,
    this.onRetry,
    this.onOpen,
  });

  final InsightAttachment attachment;
  final VoidCallback? onRetry;

  /// Opens the picture in the lightbox, which is what a tap on a tile that is
  /// not asking to be retried does.
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final failed = attachment.hasFailed;
    return Tooltip(
      message: failed
          ? '${attachment.name} did not upload: '
                '${attachment.error ?? 'unknown error'}\nTap to try again'
          : attachment.isUploading
          ? 'Uploading ${attachment.name}'
          : attachment.name,
      child: Material(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: failed ? onRetry : onOpen,
          child: Container(
            decoration: failed
                ? BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: scheme.error, width: 1.5),
                  )
                : null,
            child: Stack(
              fit: StackFit.expand,
              children: [
                Hero(
                  tag: '$_kStripSurface:${attachment.id}',
                  child: _AttachmentPicture(attachment: attachment),
                ),
                if (attachment.isUploading)
                  _UploadProgressOverlay(progress: attachment.progress),
                if (failed)
                  Positioned.fill(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: scheme.surface.withValues(alpha: 0.55),
                      ),
                      child: Center(
                        child: Icon(
                          Symbols.refresh_rounded,
                          size: 20,
                          color: scheme.error,
                        ),
                      ),
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

/// What an upload in flight shows on its tile: how much of the file has gone,
/// or a moving bar while the count is still unknown.
class _UploadProgressOverlay extends StatelessWidget {
  const _UploadProgressOverlay({required this.progress});

  final double? progress;

  @override
  Widget build(BuildContext context) {
    final progress = this.progress;
    return Positioned.fill(
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.45),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (progress != null)
              Text(
                '${(progress * 100).round()}%',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: LinearProgressIndicator(
                value: progress,
                minHeight: 2,
                borderRadius: BorderRadius.circular(2),
                backgroundColor: Colors.white24,
                color: Colors.white,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A queued text attachment, on the composer's attachment strip: the document's
/// name, its size, and a tap that opens it for editing.
class _TextAttachmentCard extends StatelessWidget {
  const _TextAttachmentCard({required this.attachment, this.onTap});

  final InsightAttachment attachment;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Tooltip(
      message: onTap == null ? attachment.name : 'Edit ${attachment.name}',
      child: Material(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 6, 22, 6),
            child: Row(
              children: [
                Icon(
                  Symbols.description_rounded,
                  size: 18,
                  color: scheme.onSurfaceVariant,
                ),
                const Gap(8),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        attachment.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelMedium,
                      ),
                      Text(
                        '${_formatCharacters(attachment.characterCount)}'
                        '${onTap == null ? '' : ' · Edit'}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall?.copyWith(
                          fontSize: 11,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
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

/// A text attachment on a sent turn: the same file the model read, shown by
/// the name it was stored under.
class _TextAttachmentChip extends StatelessWidget {
  const _TextAttachmentChip({required this.attachment});

  final InsightAttachment attachment;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final characters = attachment.characterCount;
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 6, 12, 6),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Symbols.description_rounded,
            size: 16,
            color: scheme.onSurfaceVariant,
          ),
          const Gap(8),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 300),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  attachment.name.isEmpty ? 'Text attachment' : attachment.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: scheme.onPrimaryContainer,
                  ),
                ),
                if (characters > 0)
                  Text(
                    _formatCharacters(characters),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      fontSize: 11,
                      color: scheme.onPrimaryContainer.withValues(alpha: 0.75),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The editor behind a queued text attachment: the pasted block, whole, and a
/// way back to the message field.
class _TextAttachmentDialog extends HookWidget {
  const _TextAttachmentDialog({required this.name, required this.text});

  final String name;
  final String text;

  @override
  Widget build(BuildContext context) {
    final controller = useTextEditingController(text: text);
    return AlertDialog(
      title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520, maxHeight: 420),
        child: TextField(
          controller: controller,
          autofocus: true,
          maxLines: null,
          expands: true,
          textAlignVertical: TextAlignVertical.top,
          keyboardType: TextInputType.multiline,
          decoration: const InputDecoration(border: OutlineInputBorder()),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(controller.text),
          child: const Text('Save'),
        ),
      ],
    );
  }
}

/// An image attachment's picture wherever it is shown — the composer's strip
/// and a sent turn both wear it, so a picture looks the same on either side of
/// the send.
///
/// The file on this device wins while there is one: it is the picture the
/// reader picked, it costs nothing to draw, and a preview that had to come back
/// over the network would be a slower, blurrier copy of it. What is left when
/// there is no such file — a linked cloud file, or a turn replayed from the
/// server — is the drive's own copy, drawn from the id.
class _AttachmentPicture extends StatelessWidget {
  const _AttachmentPicture({required this.attachment});

  final InsightAttachment attachment;

  @override
  Widget build(BuildContext context) {
    final path = attachment.localPath;
    if (path == null || path.isEmpty) {
      return DriveImage(fileId: attachment.fileId ?? '');
    }
    if (kIsWeb) {
      // A picked file on the web is a blob, not a path.
      return Image.network(path, fit: BoxFit.cover);
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final side = constraints.biggest.shortestSide;
        final ratio = MediaQuery.devicePixelRatioOf(context);
        return Image.file(
          File(path),
          fit: BoxFit.cover,
          // The picture is drawn at the size of its box: painting it from a
          // full-resolution file would decode megabytes for a thumbnail.
          cacheWidth: side.isFinite ? (side * ratio).round() : null,
          errorBuilder: (context, _, _) =>
              DriveImage(fileId: attachment.fileId ?? ''),
        );
      },
    );
  }
}

/// What the attach sheet handed back: a file the drive already holds, or the
/// reader's own device to pick one from.
@immutable
class _AttachSelection {
  const _AttachSelection.device() : file = null;

  const _AttachSelection.cloud(PersonalityDriveFile this.file);

  /// The file to link, or null when the pick is the reader's own device.
  final PersonalityDriveFile? file;
}

/// The attach sheet: a file on this device to upload, or one the drive already
/// holds to link.
///
/// Linking is the point of the second half. A file uploaded for an earlier
/// message is already in the drive; attaching it again would push the same
/// bytes over the same link for a second time, so the turn references the id
/// the file already has instead. The list is the account's own drive, newest
/// first and searchable by name — which is how a file from months ago is found
/// by what it was called, rather than by paging back to it — and a file the
/// list does not show can be linked by its id.
class _AttachmentSheet extends HookConsumerWidget {
  const _AttachmentSheet({required this.onClose});

  final VoidCallback onClose;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final query = useState('');
    // Typing is not a question: the drive is asked again once the reader has
    // stopped, so a name typed out is one request rather than one per letter.
    final asked = useState('');
    useEffect(() {
      final timer = Timer(
        const Duration(milliseconds: 300),
        () => asked.value = query.value,
      );
      return timer.cancel;
    }, [query.value]);

    final files = ref.watch(driveImageFilesProvider(asked.value));
    final images = files.value ?? const <PersonalityDriveFile>[];

    return SheetScaffold(
      heightFactor: 0.7,
      titleText: 'Attach',
      onClose: onClose,
      actions: [
        IconButton(
          tooltip: 'Link a file by id',
          onPressed: () => _linkById(context, ref),
          icon: const Icon(Symbols.tag_rounded),
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ListTile(
            leading: const Icon(Symbols.photo_library_rounded),
            title: const Text('Photo from this device'),
            subtitle: const Text(
              'Upload it to the drive and send it with the message',
            ),
            onTap: () =>
                Navigator.of(context).pop(const _AttachSelection.device()),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: TextField(
              onChanged: (value) => query.value = value,
              decoration: InputDecoration(
                isDense: true,
                hintText: 'Search your drive',
                prefixIcon: const Icon(Symbols.search_rounded, size: 18),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),
          Expanded(
            child: files.hasError
                ? _SheetFailure(
                    message: personalityErrorMessage(files.error!),
                    onRetry: () =>
                        ref.invalidate(driveImageFilesProvider(asked.value)),
                  )
                : files.isLoading && !files.hasValue
                ? const Center(child: CircularProgressIndicator())
                : images.isEmpty
                ? _EmptyState(
                    icon: Symbols.image_search_rounded,
                    title: asked.value.isEmpty
                        ? 'No images in your drive'
                        : 'Nothing matches “${asked.value}”',
                    description:
                        'A message can carry an image already in '
                        'your drive, whatever it was uploaded for.',
                  )
                : GridView.builder(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
                    gridDelegate:
                        const SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: 160,
                          mainAxisSpacing: 10,
                          crossAxisSpacing: 10,
                          childAspectRatio: 0.88,
                        ),
                    itemCount: images.length,
                    itemBuilder: (context, index) {
                      final file = images[index];
                      return _CloudFileTile(
                        file: file,
                        onTap: () => Navigator.of(
                          context,
                        ).pop(_AttachSelection.cloud(file)),
                      );
                    },
                  ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Text(
              'Linked files are sent by id: nothing is uploaded again, and the '
              'drive keeps the copy the message reads.',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Asks the drive for the file behind an id and links it: the id the reader
  /// pasted is resolved before it becomes an attachment, so the tile wears the
  /// name the drive keeps rather than the paste.
  Future<void> _linkById(BuildContext context, WidgetRef ref) async {
    final file = await showDialog<PersonalityDriveFile>(
      context: context,
      builder: (_) => const _LinkByIdDialog(),
    );
    if (file == null || !context.mounted) return;
    Navigator.of(context).pop(_AttachSelection.cloud(file));
  }
}

/// One file in the attach sheet's grid: its picture, its name, and what the
/// drive says it weighs. Tapping it links the file and closes the sheet.
class _CloudFileTile extends StatelessWidget {
  const _CloudFileTile({required this.file, required this.onTap});

  final PersonalityDriveFile file;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final size = file.byteSize;
    return Tooltip(
      message: 'Link ${file.displayName}',
      child: Material(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: DriveImage(fileId: file.id)),
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      file.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelMedium,
                    ),
                    if (size != null && size > 0)
                      Text(
                        _formatBytes(size),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall?.copyWith(
                          fontSize: 11,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The way to a file the listing does not show: the reader pastes a drive file
/// id, the drive answers with the file it names, and that file is what gets
/// linked.
class _LinkByIdDialog extends HookConsumerWidget {
  const _LinkByIdDialog();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = useTextEditingController();
    final busy = useState(false);
    final error = useState<String?>(null);

    Future<void> link() async {
      final id = controller.text.trim();
      if (id.isEmpty) {
        error.value = 'Paste the file id first.';
        return;
      }
      busy.value = true;
      error.value = null;
      try {
        final file = await ref
            .read(personalityCoreServiceProvider)
            .driveFile(
              id,
              driveBaseUrl: ref.read(personalityDriveBaseUrlProvider),
            );
        if (!context.mounted) return;
        Navigator.of(context).pop(file);
      } catch (e) {
        busy.value = false;
        error.value = personalityErrorMessage(e);
      }
    }

    return AlertDialog(
      title: const Text('Link a file by id'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: TextField(
          controller: controller,
          autofocus: true,
          onSubmitted: (_) => link(),
          decoration: InputDecoration(
            labelText: 'File id',
            helperText: 'The id from the file’s page in the drive',
            errorText: error.value,
            errorMaxLines: 3,
            border: const OutlineInputBorder(),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: busy.value ? null : link,
          child: busy.value
              ? const SizedBox.square(
                  dimension: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Link'),
        ),
      ],
    );
  }
}

/// What a failed drive listing leaves in the sheet: why, and the retry.
class _SheetFailure extends StatelessWidget {
  const _SheetFailure({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Could not read your drive: $message',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
            const Gap(8),
            TextButton(onPressed: onRetry, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }
}

/// What one row's overflow menu asked for.
enum _RowAction { moveToGroup, removeFromGroup, delete }

/// The move-to-group picker's answer: the group to move into, or null for
/// "ungrouped". Distinct from a dismissed picker, which is a null result.
class _GroupChoice {
  const _GroupChoice(this.groupId);

  final String? groupId;
}

/// The key of the collapsible tile that holds the archived groups.
const String _archivedSectionKey = '__archived__';

/// What a group tile's overflow menu asked for.
enum _GroupAction { rename, archive, unarchive, delete }

/// The account's threads, with collapsible group tiles entwined in the list.
///
/// Selection is local to this widget: the wide-screen panel and the sheet each
/// hold their own, and both feed the same controller when a thread is opened.
class _ConversationList extends HookConsumerWidget {
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
    final groups =
        ref.watch(personalityConversationGroupsProvider).value ??
        const <SnConversationGroup>[];
    final groupNames = {for (final group in groups) group.id: group.name};
    final agentNames = {
      for (final agent
          in ref.watch(personalityAgentsProvider).value ??
              const <SnPersonalityAgent>[])
        agent.id: agent.name.trim().isEmpty
            ? 'Unnamed agent'
            : agent.name.trim(),
    };

    final activeGroups = [
      for (final group in groups)
        if (!group.archived) group,
    ];
    final archivedGroups = [
      for (final group in groups)
        if (group.archived) group,
    ];

    // The loaded page is split here rather than on the server: each group's
    // threads, and the ones no (known) group holds.
    final grouped = <String, List<SnPersonalityConversation>>{};
    final ungrouped = <SnPersonalityConversation>[];
    for (final conversation in conversations) {
      final id = conversation.groupId;
      if (id != null && groupNames.containsKey(id)) {
        (grouped[id] ??= []).add(conversation);
      } else {
        ungrouped.add(conversation);
      }
    }

    final selected = useState<Set<String>>(const <String>{});
    final selecting = selected.value.isNotEmpty;

    // Expanded sections, keyed by group id; `_archivedSectionKey` is the tile
    // that holds the archived groups. Every section starts collapsed.
    final expanded = useState<Set<String>>(const <String>{});

    void toggleSection(String key) {
      final next = Set<String>.of(expanded.value);
      if (!next.add(key)) next.remove(key);
      expanded.value = next;
    }

    // The group holding the open thread opens itself, and so does the archived
    // tile when that thread lives in an archived group.
    useEffect(() {
      String? openGroupId;
      for (final conversation in conversations) {
        if (conversation.id == activeId) {
          openGroupId = conversation.groupId;
          break;
        }
      }
      if (openGroupId == null) return null;
      SnConversationGroup? openGroup;
      for (final group in groups) {
        if (group.id == openGroupId) {
          openGroup = group;
          break;
        }
      }
      if (openGroup == null) return null;
      final next = Set<String>.of(expanded.value);
      var changed = next.add(openGroup.id);
      if (openGroup.archived) {
        changed = next.add(_archivedSectionKey) || changed;
      }
      if (changed) expanded.value = next;
      return null;
    }, [activeId, groups, conversations]);

    // Both providers feed this list, so every mutation refetches both, and the
    // selection never survives one.
    void refresh() {
      ref.invalidate(personalityConversationsProvider);
      ref.invalidate(personalityConversationGroupsProvider);
      selected.value = const <String>{};
    }

    Future<void> assignGroup(List<String> ids, String? groupId) async {
      final api = ref.read(personalityApiProvider);
      try {
        await api.setConversationGroup(ids, groupId);
        if (!context.mounted) return;
        refresh();
        showSnackBar(groupId == null ? 'Removed from group' : 'Moved to group');
      } catch (e) {
        showSnackBar(personalityErrorMessage(e));
      }
    }

    Future<void> moveToGroup(List<String> ids) async {
      final choice = await _pickConversationGroup(context, activeGroups);
      if (choice == null) return;
      await assignGroup(ids, choice.groupId);
    }

    Future<void> deleteConversations(List<String> ids) async {
      final many = ids.length > 1;
      final confirmed = await _confirmDialog(
        context,
        title: many
            ? 'Delete ${ids.length} conversations?'
            : 'Delete conversation?',
        message:
            'The threads and their messages are removed. What the agent '
            'learned in them stays in memory.',
        confirmLabel: 'Delete',
      );
      if (confirmed != true || !context.mounted) return;
      final api = ref.read(personalityApiProvider);
      final controller = ref.read(insightChatControllerProvider.notifier);
      try {
        if (many) {
          await api.deleteConversations(ids);
        } else {
          await api.deleteConversation(ids.single);
        }
        for (final id in ids) {
          controller.conversationRemoved(id);
        }
        if (!context.mounted) return;
        refresh();
        showSnackBar(
          many ? '${ids.length} conversations deleted' : 'Conversation deleted',
        );
      } catch (e) {
        showSnackBar(personalityErrorMessage(e));
      }
    }

    Future<void> runRowAction(
      _RowAction action,
      SnPersonalityConversation conversation,
    ) async {
      switch (action) {
        case _RowAction.moveToGroup:
          await moveToGroup([conversation.id]);
        case _RowAction.removeFromGroup:
          await assignGroup([conversation.id], null);
        case _RowAction.delete:
          await deleteConversations([conversation.id]);
      }
    }

    // Group mutations refetch both providers and drop the selection, exactly as
    // the row mutations do; only the success line differs.
    Future<void> runGroupMutation(
      Future<void> Function() action,
      String success,
    ) async {
      try {
        await action();
        if (!context.mounted) return;
        refresh();
        showSnackBar(success);
      } catch (e) {
        showSnackBar(personalityErrorMessage(e));
      }
    }

    void setGroupArchived(SnConversationGroup group, bool archived) {
      final api = ref.read(personalityApiProvider);
      runGroupMutation(
        () => api.updateConversationGroup(group.id, archived: archived),
        archived ? 'Archived — its memories stay pinned' : 'Group restored',
      );
    }

    Future<void> renameGroup(SnConversationGroup group) async {
      final name = await _promptGroupName(
        context,
        title: 'Rename group',
        initial: group.name,
      );
      if (name == null) return;
      final api = ref.read(personalityApiProvider);
      await runGroupMutation(
        () => api.updateConversationGroup(group.id, name: name),
        'Group renamed',
      );
    }

    Future<void> deleteGroup(SnConversationGroup group) async {
      final confirmed = await _confirmDialog(
        context,
        title: 'Delete ${group.name}?',
        message:
            'Its conversations stay; they become ungrouped. Memories the '
            'group pinned stop being pinned.',
        confirmLabel: 'Delete',
      );
      if (confirmed != true) return;
      final api = ref.read(personalityApiProvider);
      await runGroupMutation(
        () => api.deleteConversationGroup(group.id),
        'Group deleted',
      );
    }

    Future<void> createGroup() async {
      final name = await _promptGroupName(context, title: 'New group');
      if (name == null) return;
      final api = ref.read(personalityApiProvider);
      await runGroupMutation(
        () => api.createConversationGroup(name: name),
        'Group created',
      );
    }

    Future<void> runGroupAction(
      _GroupAction action,
      SnConversationGroup group,
    ) async {
      switch (action) {
        case _GroupAction.rename:
          await renameGroup(group);
        case _GroupAction.archive:
          setGroupArchived(group, true);
        case _GroupAction.unarchive:
          setGroupArchived(group, false);
        case _GroupAction.delete:
          await deleteGroup(group);
      }
    }

    final Widget body;
    if (error != null) {
      body = Center(
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
    } else if (loading && conversations.isEmpty && groups.isEmpty) {
      body = Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: const CircularProgressIndicator(),
        ),
      );
    } else {
      // One row, flat or indented under the group that claims it.
      Widget row(SnPersonalityConversation conversation, {double indent = 0}) {
        final inSelection = selected.value.contains(conversation.id);
        final active = conversation.id == activeId;
        final title = conversation.title.trim();
        final groupId = conversation.groupId;
        final groupName = groupId == null ? null : groupNames[groupId];
        final lastMessageAt = conversation.lastMessageAt;

        void toggle() {
          final next = Set<String>.of(selected.value);
          if (!next.add(conversation.id)) next.remove(conversation.id);
          selected.value = next;
        }

        final tile = Material(
          color: inSelection
              ? scheme.primaryContainer.withValues(alpha: 0.5)
              : active
              ? scheme.secondaryContainer.withValues(alpha: 0.55)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: selecting ? toggle : () => onSelect(conversation.id),
            onLongPress: selecting
                ? null
                : () => selected.value = {...selected.value, conversation.id},
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
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
                      if (!selecting)
                        _ConversationRowMenu(
                          grouped: groupId != null,
                          onSelected: (action) =>
                              runRowAction(action, conversation),
                        ),
                    ],
                  ),
                  const Gap(3),
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          agentNames[conversation.agentId] ?? 'Conversation',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant.withValues(
                              alpha: 0.85,
                            ),
                          ),
                        ),
                      ),
                      if (groupName != null) ...[
                        const Gap(6),
                        Icon(
                          Symbols.folder_rounded,
                          size: 12,
                          color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
                        ),
                        const Gap(3),
                        Flexible(
                          child: Text(
                            groupName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant.withValues(
                                alpha: 0.85,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
        return indent == 0
            ? tile
            : Padding(
                padding: EdgeInsets.only(left: indent),
                child: tile,
              );
      }

      // A group tile: tapping it folds its conversations in and out. The
      // overflow menu renames, archives and deletes it.
      Widget groupTile(SnConversationGroup group, {double indent = 0}) {
        final isExpanded = expanded.value.contains(group.id);
        final description = group.description.trim();
        final tile = ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 12),
          leading: Icon(
            isExpanded ? Symbols.folder_open_rounded : Symbols.folder_rounded,
            color: scheme.onSurfaceVariant,
          ),
          title: Text(
            group.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          subtitle: Text(
            description.isNotEmpty
                ? description
                : group.conversationCount == 1
                ? '1 conversation'
                : '${group.conversationCount} conversations',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          trailing: PopupMenuButton<_GroupAction>(
            tooltip: 'Group actions',
            icon: const Icon(Symbols.more_vert),
            onSelected: (action) => runGroupAction(action, group),
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: _GroupAction.rename,
                child: Text('Rename'),
              ),
              PopupMenuItem(
                value: group.archived
                    ? _GroupAction.unarchive
                    : _GroupAction.archive,
                child: Text(group.archived ? 'Unarchive' : 'Archive'),
              ),
              const PopupMenuItem(
                value: _GroupAction.delete,
                child: Text('Delete'),
              ),
            ],
          ),
          onTap: () => toggleSection(group.id),
        );
        return indent == 0
            ? tile
            : Padding(
                padding: EdgeInsets.only(left: indent),
                child: tile,
              );
      }

      // The muted tile that gathers every archived group, itself collapsible.
      Widget archivedTile() {
        final isExpanded = expanded.value.contains(_archivedSectionKey);
        return ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 12),
          leading: Icon(
            isExpanded ? Symbols.folder_open_rounded : Symbols.folder_rounded,
            color: scheme.onSurfaceVariant,
          ),
          title: Text(
            'Archived',
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w600,
              color: scheme.onSurfaceVariant,
            ),
          ),
          subtitle: Text(
            archivedGroups.length == 1
                ? '1 group'
                : '${archivedGroups.length} groups',
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          onTap: () => toggleSection(_archivedSectionKey),
        );
      }

      Widget newGroupTile() => ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 12),
        leading: Icon(Symbols.create_new_folder_rounded, color: scheme.primary),
        title: Text(
          'New group',
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w600,
            color: scheme.primary,
          ),
        ),
        onTap: () => createGroup(),
      );

      List<SnPersonalityConversation> inGroup(String id) =>
          grouped[id] ?? const <SnPersonalityConversation>[];

      body = ListView(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        children: [
          if (conversations.isEmpty && groups.isEmpty)
            Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                'No conversations yet',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          for (final group in activeGroups) ...[
            groupTile(group),
            if (expanded.value.contains(group.id))
              for (final conversation in inGroup(group.id))
                row(conversation, indent: 16),
          ],
          if (activeGroups.isEmpty)
            for (final conversation in ungrouped) row(conversation)
          else ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
              child: Text(
                'Ungrouped',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant.withValues(alpha: 0.9),
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.4,
                ),
              ),
            ),
            for (final conversation in ungrouped) row(conversation),
          ],
          if (archivedGroups.isNotEmpty) ...[
            archivedTile(),
            if (expanded.value.contains(_archivedSectionKey))
              for (final group in archivedGroups) ...[
                groupTile(group, indent: 16),
                if (expanded.value.contains(group.id))
                  for (final conversation in inGroup(group.id))
                    row(conversation, indent: 32),
              ],
          ],
          if (!selecting) newGroupTile(),
        ],
      );
    }

    // Rows follow the chat list: a Material surface that tints when selected,
    // with the timestamp trailing the title.
    return Column(
      children: [
        if (selecting)
          Material(
            color: scheme.surfaceContainerHighest,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              child: Row(
                children: [
                  IconButton(
                    tooltip: 'Exit selection',
                    onPressed: () => selected.value = const <String>{},
                    icon: const Icon(Symbols.close),
                  ),
                  Text(
                    '${selected.value.length} selected',
                    style: theme.textTheme.labelLarge,
                  ),
                  const Spacer(),
                  IconButton(
                    tooltip: 'Move to group',
                    onPressed: () => moveToGroup(selected.value.toList()),
                    icon: const Icon(Symbols.playlist_add),
                  ),
                  IconButton(
                    tooltip: 'Delete',
                    onPressed: () =>
                        deleteConversations(selected.value.toList()),
                    icon: const Icon(Symbols.delete_outline),
                  ),
                ],
              ),
            ),
          ),
        const Divider(height: 1),
        Expanded(child: body),
      ],
    );
  }
}

/// A row's overflow menu: move, un-set the group, or delete.
class _ConversationRowMenu extends StatelessWidget {
  const _ConversationRowMenu({required this.grouped, required this.onSelected});

  final bool grouped;
  final ValueChanged<_RowAction> onSelected;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<_RowAction>(
      tooltip: 'Conversation actions',
      icon: const Icon(Symbols.more_vert),
      onSelected: onSelected,
      itemBuilder: (context) => [
        const PopupMenuItem(
          value: _RowAction.moveToGroup,
          child: Text('Move to group…'),
        ),
        if (grouped)
          const PopupMenuItem(
            value: _RowAction.removeFromGroup,
            child: Text('Remove from group'),
          ),
        const PopupMenuItem(value: _RowAction.delete, child: Text('Delete')),
      ],
    );
  }
}

/// The move-to-group picker: each group, plus the choice to ungroup. A null
/// result means the reader dismissed it without choosing.
Future<_GroupChoice?> _pickConversationGroup(
  BuildContext context,
  List<SnConversationGroup> groups,
) {
  return showDialog<_GroupChoice>(
    context: context,
    builder: (context) => SimpleDialog(
      title: const Text('Move to group'),
      children: [
        for (final group in groups)
          SimpleDialogOption(
            onPressed: () => Navigator.of(context).pop(_GroupChoice(group.id)),
            child: Text(group.name),
          ),
        SimpleDialogOption(
          onPressed: () => Navigator.of(context).pop(const _GroupChoice(null)),
          child: const Text('Ungrouped'),
        ),
      ],
    ),
  );
}

/// Asks for a group name, returning the trimmed text or null when cancelled.
Future<String?> _promptGroupName(
  BuildContext context, {
  required String title,
  String initial = '',
}) {
  return showDialog<String>(
    context: context,
    builder: (context) => _GroupNameDialog(title: title, initial: initial),
  );
}

class _GroupNameDialog extends HookWidget {
  const _GroupNameDialog({required this.title, required this.initial});

  final String title;
  final String initial;

  @override
  Widget build(BuildContext context) {
    final controller = useTextEditingController(text: initial);
    final canSave = useState(initial.trim().isNotEmpty);

    void save() {
      final name = controller.text.trim();
      if (name.isEmpty) return;
      Navigator.of(context).pop(name);
    }

    return AlertDialog(
      title: Text(title),
      content: TextField(
        controller: controller,
        autofocus: true,
        decoration: const InputDecoration(labelText: 'Name'),
        onChanged: (value) => canSave.value = value.trim().isNotEmpty,
        onSubmitted: (_) => save(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: canSave.value ? save : null,
          child: const Text('Save'),
        ),
      ],
    );
  }
}

/// A yes/no confirmation in the app's dialog shape.
Future<bool?> _confirmDialog(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
}) {
  return showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
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

/// A block pasted into the composer at least this long is hard to read in the
/// message field, so it becomes a text attachment instead. Shorter pastes stay
/// inline, where they read as part of the message.
const int kPasteTextAttachmentChars = 1000;

/// The one contiguous block [after] gained over [before], with where it starts,
/// or null when the change was not a single insertion (a deletion, a typing
/// burst of separate edits, an IME composition).
({int start, String text})? _insertedBlock(String before, String after) {
  if (after.length <= before.length) return null;
  var start = 0;
  while (start < before.length && before[start] == after[start]) {
    start++;
  }
  var suffix = 0;
  while (suffix < before.length - start &&
      suffix < after.length - start &&
      before[before.length - 1 - suffix] == after[after.length - 1 - suffix]) {
    suffix++;
  }
  final text = after.substring(start, after.length - suffix);
  if (after.replaceRange(start, start + text.length, '') != before) return null;
  return (start: start, text: text);
}

/// A file's size as a tile can hold it: `812 B`, `12.3 kB`, `4.5 MB`.
String _formatBytes(int bytes) {
  if (bytes < 1000) return '$bytes B';
  if (bytes < 1000000) return _scaled(bytes / 1000, 'kB');
  return _scaled(bytes / 1000000, 'MB');
}

/// `812` stays `812`, `12,345` becomes `12.3k`. The same shape the context
/// meter uses, for the same reason: a glance, not a ledger.
String _formatCharacters(int value) {
  if (value <= 0) return 'Empty';
  if (value < 1000) return '$value characters';
  final thousands = value / 1000;
  final text = thousands.toStringAsFixed(thousands < 100 ? 1 : 0);
  final trimmed = text.endsWith('.0')
      ? text.substring(0, text.length - 2)
      : text;
  return '${trimmed}k characters';
}

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
