import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:synth_pet/auth/solar_auth_service.dart';
import 'package:synth_pet/personality/personality_service.dart';
import 'package:synth_pet/pet/pet_appearance_settings.dart';
import 'package:synth_pet/pet/pet_behavior.dart';
import 'package:synth_pet/widgets/pet_avatar.dart';

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
              _behavior.setStatus('Voice input failed: ${error.errorMsg}');
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
      setState(() => _behavior.setStatus('Voice input is unavailable here.'));
      return;
    }
    if (_isListening) {
      await _speech.stop();
      if (mounted) setState(() => _isListening = false);
      return;
    }

    setState(() {
      _isListening = true;
      _behavior.setStatus('Listening... ', face: 'o.o');
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
          () => _behavior.setStatus('Sign in to talk to Mochi.', face: 'o.o'),
        );
      }
      return;
    }
    if (accessToken == null) {
      if (mounted) {
        setState(
          () => _behavior.setStatus('Sign in to talk to Mochi.', face: 'o.o'),
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
        accessToken: accessToken,
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

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final state = _behavior.state;
    final avatarScale =
        state.animation == 'pulse' || state.animation == 'bounce' ? 1.04 : 1.0;
    return Scaffold(
      backgroundColor: colors.surface,
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            AnimatedScale(
              scale: avatarScale,
              duration: const Duration(milliseconds: 220),
              child: PetAvatar(size: 170, face: state.face),
            ),
            const SizedBox(height: 12),
            Text(
              'Mochi',
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 180),
              child: Text(
                state.status,
                key: ValueKey(state.status),
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '${state.mood.name} · ${state.source}',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.labelSmall,
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              alignment: WrapAlignment.center,
              children: [
                IconButton.filledTonal(
                  tooltip: 'Feed Mochi',
                  onPressed: () => _interact(PetInteraction.feed),
                  icon: const Icon(Icons.restaurant_rounded),
                ),
                IconButton.filledTonal(
                  tooltip: 'Play with Mochi',
                  onPressed: () => _interact(PetInteraction.play),
                  icon: const Icon(Icons.sports_esports_rounded),
                ),
                IconButton.filledTonal(
                  tooltip: 'Rest with Mochi',
                  onPressed: () => _interact(PetInteraction.rest),
                  icon: const Icon(Icons.nightlight_rounded),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Card(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 6, 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _messageController,
                        minLines: 1,
                        maxLines: 3,
                        textInputAction: TextInputAction.send,
                        onSubmitted: (_) => _sendMessage(),
                        decoration: const InputDecoration(
                          hintText: 'Talk to Mochi...',
                          border: InputBorder.none,
                        ),
                      ),
                    ),
                    if (_speechAvailable)
                      IconButton(
                        tooltip: _isListening ? 'Stop listening' : 'Use voice',
                        onPressed: _toggleListening,
                        icon: Icon(
                          _isListening ? Icons.stop_circle : Icons.mic_none,
                        ),
                      ),
                    IconButton.filledTonal(
                      tooltip: 'Send message',
                      onPressed: _sendMessage,
                      icon: const Icon(Icons.arrow_upward_rounded),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: () => setState(
                () => _behavior.setStatus('See you soon.', face: '-.-'),
              ),
              icon: const Icon(Icons.visibility_off_outlined),
              label: const Text('Hide for now'),
            ),
          ],
        ),
      ),
    );
  }
}
