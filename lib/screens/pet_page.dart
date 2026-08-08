import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:synth_pet/auth/solar_auth_service.dart';
import 'package:synth_pet/personality/personality_service.dart';
import 'package:synth_pet/pet/pet_appearance_settings.dart';
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
  String _face = PetAppearance.defaultValue.face;
  String _status = 'Mochi is here';
  bool _isThinking = false;

  @override
  void initState() {
    super.initState();
    _loadAppearance();
  }

  Future<void> _loadAppearance() async {
    try {
      final appearance = await const PetAppearanceSettings().load();
      if (mounted) setState(() => _face = appearance.face);
    } catch (_) {
      // The default face remains available when local storage is unavailable.
    }
  }

  void _setMood(String face, String status) {
    setState(() {
      _face = face;
      _status = status;
    });
  }

  Future<void> _talkToMochi() async {
    if (_isThinking) return;

    String? accessToken;
    try {
      accessToken = await _auth.accessToken();
    } on SolarAuthException {
      _setMood('o.o', 'Sign in to talk to Mochi.');
      return;
    }
    if (accessToken == null) {
      _setMood('o.o', 'Sign in to talk to Mochi.');
      return;
    }

    setState(() {
      _face = 'o.o';
      _status = 'Thinking...';
      _isThinking = true;
    });
    try {
      final reply = await _personality.chat(
        accessToken: accessToken,
        agentId: _personalityConfig.agentId,
        prompt: 'Say one short, warm sentence to your desktop companion user.',
      );
      if (mounted) _setMood('^.^', reply);
    } on PersonalityCoreException {
      if (mounted) _setMood('>.<', 'Personality Core is unavailable.');
    } finally {
      if (mounted) setState(() => _isThinking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: colors.surface,
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              PetAvatar(size: 190, face: _face),
              const SizedBox(height: 16),
              Text(
                'Mochi',
                style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 6),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 180),
                child: Text(_status, key: ValueKey(_status)),
              ),
              const SizedBox(height: 24),
              Wrap(
                spacing: 8,
                alignment: WrapAlignment.center,
                children: [
                  IconButton.filledTonal(
                    tooltip: 'Feed Mochi',
                    onPressed: () => _setMood('0.0', 'A tiny snack helps.'),
                    icon: const Icon(Icons.restaurant_rounded),
                  ),
                  IconButton.filledTonal(
                    tooltip: 'Play with Mochi',
                    onPressed: () => _setMood('^.^', 'That was fun.'),
                    icon: const Icon(Icons.sports_esports_rounded),
                  ),
                  IconButton.filledTonal(
                    tooltip: 'Rest with Mochi',
                    onPressed: () => _setMood('-.-', 'A quiet moment.'),
                    icon: const Icon(Icons.nightlight_rounded),
                  ),
                  IconButton.filledTonal(
                    tooltip: 'Talk to Mochi',
                    onPressed: _talkToMochi,
                    icon: const Icon(Icons.chat_bubble_outline_rounded),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              TextButton.icon(
                onPressed: () => _setMood('-.-', 'See you soon.'),
                icon: const Icon(Icons.visibility_off_outlined),
                label: const Text('Hide for now'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
