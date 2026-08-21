import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';

import 'package:synth_pet/auth/solar_auth_service.dart';
import 'package:synth_pet/conversation/conversation_controller.dart';
import 'package:synth_pet/conversation/conversation_event.dart';
import 'package:synth_pet/conversation/personality_backend.dart';
import 'package:synth_pet/personality/personality_service.dart';
import 'package:synth_pet/theme/app_theme.dart';

// ---------------------------------------------------------------------------
// Bubble types
// ---------------------------------------------------------------------------
enum _BubbleKind { user, assistant, systemNote }

class _Bubble {
  _Bubble(this.kind, this.text, {this.streaming = false});
  final _BubbleKind kind;
  String text;
  bool streaming;
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
  const ConversationPage({super.key});

  @override
  State<ConversationPage> createState() => _ConversationPageState();
}

class _ConversationPageState extends State<ConversationPage> {
  final _controller = ConversationController(
    backend: PersonalityCoreBackend(const PersonalityCoreService()),
    getAccessToken: () => SolarAuthService().accessToken(),
    defaultAgentId: PersonalityCoreConfig.fromEnvironment().agentId,
  );

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
        case ChunkReceived(:final delta):
          final last = _bubbles.isNotEmpty ? _bubbles.last : null;
          if (last == null || last.kind != _BubbleKind.assistant) {
            _bubbles.add(
              _Bubble(_BubbleKind.assistant, delta, streaming: true),
            );
          } else {
            last.text += delta;
          }
          _scrollToEnd();
        case MessageCompleted(:final text):
          if (_bubbles.isNotEmpty &&
              _bubbles.last.kind == _BubbleKind.assistant) {
            _bubbles.last.text = text;
            _bubbles.last.streaming = false;
          } else {
            _bubbles.add(_Bubble(_BubbleKind.assistant, text));
          }
          _scrollToEnd();
        case ToolInvoked(:final name, :final result):
          if (result == 'running') break;
          _bubbles.add(_Bubble(_BubbleKind.systemNote, '$name · $result'));
          _scrollToEnd();
        case StatusChanged(:final busy):
          _busy = busy;
        case ErrorOccurred(:final message):
          _error = message;
      }
    });
  }

  // ---- actions -------------------------------------------------------------

  void _send() {
    final text = _inputController.text.trim();
    if (text.isEmpty || _busy || _authError) return;
    setState(() {
      _bubbles.add(_Bubble(_BubbleKind.user, text));
      _error = null;
    });
    _inputController.clear();
    _scrollToEnd();
    _controller.send(text);
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
          if (_busy)
            IconButton(
              icon: Icon(Icons.stop_circle_outlined, color: cs.error),
              tooltip: 'Stop',
              onPressed: _controller.abort,
            ),
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
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
      color: cs.surfaceContainer,
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _inputController,
              onSubmitted: (_) => _send(),
              enabled: !_busy && !_authError,
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
            onPressed: (_busy || _authError) ? null : _send,
            style: FilledButton.styleFrom(
              shape: const CircleBorder(),
              padding: const EdgeInsets.all(10),
            ),
            child: const Icon(Icons.arrow_upward_rounded, size: 20),
          ),
        ],
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
                    color: SynthPetColors.ink,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Text(
                    bubble.text,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      height: 1.35,
                    ),
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
                  child: Text(
                    bubble.streaming ? '${bubble.text}▍' : bubble.text,
                    style: const TextStyle(fontSize: 14, height: 1.35),
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
}
