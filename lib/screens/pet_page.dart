import 'package:easy_localization/easy_localization.dart';
import 'package:auto_route/auto_route.dart';
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:island_ui_foundation/island_ui_foundation.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:persynth/auth/solar_auth_service.dart';
import 'package:persynth/personality/personality_service.dart';
import 'package:persynth/pet/pet_appearance_settings.dart';
import 'package:persynth/pet/pet_behavior.dart';
import 'package:persynth/theme/app_theme.dart';
import 'package:persynth/widgets/pet_avatar.dart';
import 'package:window_manager/window_manager.dart';

// ---------------------------------------------------------------------------
// Breathing aura — the ember glow behind the face. Slow when idle, faster
// while thinking. The one accent color in the whole app: it marks "alive".
// ---------------------------------------------------------------------------
class _BreathingAura extends StatefulWidget {
  const _BreathingAura({required this.active, required this.diameter});

  final bool active;
  final double diameter;

  @override
  State<_BreathingAura> createState() => _BreathingAuraState();
}

class _BreathingAuraState extends State<_BreathingAura>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: widget.active
        ? const Duration(milliseconds: 1200)
        : const Duration(milliseconds: 2600),
  )..repeat(reverse: true);

  late final Animation<double> _breath = CurvedAnimation(
    parent: _c,
    curve: Curves.easeInOutSine,
  );

  @override
  void didUpdateWidget(covariant _BreathingAura old) {
    super.didUpdateWidget(old);
    if (old.active != widget.active) {
      _c.duration = widget.active
          ? const Duration(milliseconds: 1200)
          : const Duration(milliseconds: 2600);
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  Widget _disc(BuildContext context, double alpha) {
    final ember = Theme.of(context).colorScheme.primary;
    return Container(
      width: widget.diameter,
      height: widget.diameter,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(
          colors: [
            ember.withValues(alpha: alpha),
            ember.withValues(alpha: 0),
          ],
          stops: const [0.0, 1.0],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.of(context).disableAnimations) {
      return _disc(context, 0.18);
    }
    return AnimatedBuilder(
      animation: _breath,
      builder: (context, _) => _disc(context, 0.14 + 0.12 * _breath.value),
    );
  }
}

// ---------------------------------------------------------------------------
// The island — the floating window as a soft rounded card.
// ---------------------------------------------------------------------------
@RoutePage()
class PetPage extends StatefulWidget {
  const PetPage({super.key});

  @override
  State<PetPage> createState() => _PetPageState();
}

class _PetPageState extends State<PetPage> {
  final _auth = SolarAuthService();
  final _personality = const PersonalityCoreService();
  final _personalityConfig = PersonalityCoreConfig.fromEnvironment();
  final _behavior = PetBehaviorController();
  final _messageController = TextEditingController();
  final _speech = SpeechToText();

  Timer? _behaviorTimer;
  bool _speechAvailable = false;
  bool _isListening = false;
  final _chatHistory = <String>[];

  @override
  void initState() {
    super.initState();
    _loadAppearance();
    _initializeSpeech();
    _behaviorTimer = Timer.periodic(const Duration(seconds: 20), (_) {
      if (mounted) setState(_behavior.tick);
    });
  }

  @override
  void dispose() {
    _behaviorTimer?.cancel();
    _speech.cancel();
    _messageController.dispose();
    super.dispose();
  }

  Future<void> _loadAppearance() async {
    try {
      final appearance = await const PetAppearanceSettings().load();
      if (mounted) {
        setState(() => _behavior.setAppearance(appearance.face));
      }
    } catch (_) {
      // The default face remains available when local storage is unavailable.
    }
  }

  Future<void> _initializeSpeech() async {
    final supported =
        kIsWeb ||
        defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS;
    if (!supported) return;

    try {
      final available = await _speech.initialize(
        onStatus: (status) {
          if (!mounted) return;
          if (status == 'done' || status == 'notListening') {
            setState(() => _isListening = false);
          }
        },
        onError: (error) {
          if (mounted) {
            setState(() {
              _isListening = false;
              _behavior.setStatus('voiceInputFailed'.tr());
            });
          }
        },
      );
      if (mounted) setState(() => _speechAvailable = available);
    } catch (_) {
      // Text chat remains available when speech recognition is unavailable.
    }
  }

  void _interact(PetInteraction interaction) {
    setState(() => _behavior.applyInteraction(interaction));
  }

  Future<void> _toggleListening() async {
    if (!_speechAvailable) {
      setState(() => _behavior.setStatus('voiceUnavailable'.tr()));
      return;
    }
    if (_isListening) {
      await _speech.stop();
      if (mounted) setState(() => _isListening = false);
      return;
    }

    setState(() {
      _isListening = true;
      _behavior.setStatus('listening'.tr(), face: 'o.o');
    });
    await _speech.listen(
      onResult: (result) {
        if (!mounted) return;
        setState(() {
          _messageController.value = TextEditingValue(
            text: result.recognizedWords,
            selection: TextSelection.collapsed(
              offset: result.recognizedWords.length,
            ),
          );
        });
        if (result.finalResult) {
          _speech.stop();
          if (mounted) {
            setState(() => _isListening = false);
            _sendMessage();
          }
        }
      },
    );
  }

  Future<void> _sendMessage() async {
    final message = _messageController.text.trim();
    if (message.isEmpty || _behavior.state.isThinking) return;
    _messageController.clear();

    String? accessToken;
    try {
      accessToken = await _auth.accessToken();
    } on SolarAuthException {
      if (mounted) {
        setState(
          () => _behavior.setStatus('signInToTalk'.tr(), face: 'o.o'),
        );
      }
      return;
    }
    if (accessToken == null) {
      if (mounted) {
        setState(
          () => _behavior.setStatus('signInToTalk'.tr(), face: 'o.o'),
        );
      }
      return;
    }

    final prompt = _promptFor(message);
    setState(() {
      _chatHistory.add('User: $message');
      _behavior.setThinking(true);
    });
    try {
      final rawReply = await _personality.chat(
        agentId: _personalityConfig.agentId,
        prompt: prompt,
      );
      final response = PetBehaviorResponse.fromAssistantText(rawReply);
      if (mounted) {
        setState(() {
          if (response.directive != null) {
            _behavior.applyAiDirective(response.directive!);
          }
          _behavior.setThinking(false);
          _behavior.setStatus(
            response.reply,
            source: response.directive == null ? 'programmatic' : 'ai',
          );
        });
        _chatHistory.add('Mochi: ${response.reply}');
        if (_chatHistory.length > 12) {
          _chatHistory.removeRange(0, _chatHistory.length - 12);
        }
      }
    } on PersonalityCoreException catch (error) {
      if (mounted) {
        setState(() {
          _behavior.setThinking(false);
          _behavior.setStatus(error.message, face: '>.<');
        });
      }
    } finally {
      if (mounted && _behavior.state.isThinking) {
        setState(() => _behavior.setThinking(false));
      }
    }
  }

  String _promptFor(String message) {
    final state = _behavior.state;
    final transcript = [..._chatHistory, 'User: $message'].join('\n');
    return '''You are Mochi, a warm desktop companion. Reply to the user message below.

Return JSON only with this shape:
{"reply":"one or two short conversational sentences","behavior":{"mood":"neutral|happy|sad|sleepy|curious|excited|lonely|focused","face":"0.0","status":"short status","animation":"none|pulse|bounce|blink"}}

The behavior object may be empty when no change is needed. You may control only mood, face, status, and animation. Do not invent energy, affection, settings, commands, or tool calls. Keep the reply natural and concise.

Current pet state: mood=${state.mood.name}, energy=${state.energy.toStringAsFixed(2)}, affection=${state.affection.toStringAsFixed(2)}.
Recent conversation:
$transcript''';
  }

  Widget _wrapIsland(BuildContext context, Widget child) {
    final cs = Theme.of(context).colorScheme;
    final island = Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(26),
        boxShadow: const [
          BoxShadow(
            color: Color(0x2E20252C),
            blurRadius: 26,
            offset: Offset(0, 12),
          ),
        ],
      ),
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 26, 20, 18),
          child: child,
        ),
      ),
    );
    if (!DesktopWindowFrame.isPlatformDesktop) return island;
    // The island itself is the drag handle; controls inside still receive taps.
    return DragToMoveArea(child: island);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final state = _behavior.state;
    final avatarScale =
        state.animation == 'pulse' || state.animation == 'bounce' ? 1.04 : 1.0;
    final awake =
        state.isThinking ||
        state.animation == 'pulse' ||
        state.animation == 'bounce';

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: Center(
          child: _wrapIsland(
            context,
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Stack(
                  alignment: Alignment.center,
                  children: [
                    _BreathingAura(active: awake, diameter: 196),
                    AnimatedScale(
                      scale: avatarScale,
                      duration: const Duration(milliseconds: 220),
                      child: PetAvatar(size: 170, face: state.face),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  'Mochi',
                  style: TextStyle(
                    fontFamily: PersynthFonts.sans,
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 1.2,
                    color: cs.onSurface,
                  ),
                ),
                const SizedBox(height: 4),
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 180),
                  child: Text(
                    state.status,
                    key: ValueKey(state.status),
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.35,
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '${state.mood.name} · ${state.source}',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.labelSmall,
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 10,
                  alignment: WrapAlignment.center,
                  children: [
                    IconButton(
                      tooltip: 'feedMochi'.tr(),
                      onPressed: () => _interact(PetInteraction.feed),
                      icon: const Icon(Icons.restaurant_rounded, size: 19),
                      style: IconButton.styleFrom(
                        backgroundColor: cs.surfaceContainerLowest,
                        foregroundColor: cs.onSurfaceVariant,
                        shape: const CircleBorder(),
                        padding: const EdgeInsets.all(10),
                      ),
                    ),
                    IconButton(
                      tooltip: 'playWithMochi'.tr(),
                      onPressed: () => _interact(PetInteraction.play),
                      icon: const Icon(Icons.sports_esports_rounded, size: 19),
                      style: IconButton.styleFrom(
                        backgroundColor: cs.surfaceContainerLowest,
                        foregroundColor: cs.onSurfaceVariant,
                        shape: const CircleBorder(),
                        padding: const EdgeInsets.all(10),
                      ),
                    ),
                    IconButton(
                      tooltip: 'restWithMochi'.tr(),
                      onPressed: () => _interact(PetInteraction.rest),
                      icon: const Icon(Icons.nightlight_rounded, size: 19),
                      style: IconButton.styleFrom(
                        backgroundColor: cs.surfaceContainerLowest,
                        foregroundColor: cs.onSurfaceVariant,
                        shape: const CircleBorder(),
                        padding: const EdgeInsets.all(10),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Container(
                  decoration: BoxDecoration(
                    color: cs.surfaceContainerLowest,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  padding: const EdgeInsets.only(left: 14, right: 6),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _messageController,
                          minLines: 1,
                          maxLines: 3,
                          textInputAction: TextInputAction.send,
                          onSubmitted: (_) => _sendMessage(),
                          decoration: InputDecoration(
                            hintText: 'talkToMochi'.tr(),
                            border: InputBorder.none,
                            focusedBorder: InputBorder.none,
                            filled: false,
                            contentPadding: EdgeInsets.symmetric(vertical: 12),
                          ),
                        ),
                      ),
                      if (_speechAvailable)
                        IconButton(
                          tooltip: _isListening
                              ? 'stopListening'.tr()
                              : 'useVoice'.tr(),
                          onPressed: _toggleListening,
                          color: _isListening
                              ? cs.primary
                              : cs.onSurfaceVariant,
                          icon: Icon(
                            _isListening ? Icons.stop_circle : Icons.mic_none,
                            size: 20,
                          ),
                        ),
                      IconButton(
                        tooltip: 'sendMessage'.tr(),
                        onPressed: _sendMessage,
                        style: IconButton.styleFrom(
                          backgroundColor: cs.primary,
                          foregroundColor: cs.onPrimary,
                          disabledBackgroundColor: cs.outline,
                          disabledForegroundColor: cs.onSurfaceVariant,
                          shape: const CircleBorder(),
                          padding: const EdgeInsets.all(9),
                        ),
                        icon: const Icon(Icons.arrow_upward_rounded, size: 19),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 6),
                TextButton.icon(
                  onPressed: () => setState(
                    () => _behavior.setStatus('seeYouSoon'.tr(), face: '-.-'),
                  ),
                  style: TextButton.styleFrom(
                    foregroundColor: cs.onSurfaceVariant,
                    textStyle: const TextStyle(
                      fontFamily: PersynthFonts.sans,
                      fontSize: 11,
                      letterSpacing: 0.4,
                    ),
                  ),
                  icon: const Icon(Icons.visibility_off_outlined, size: 15),
                  label: Text('hideForNow'.tr()),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
