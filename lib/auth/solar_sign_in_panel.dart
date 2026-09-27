import 'package:flutter/material.dart';
import 'package:gap/gap.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';

import 'package:persynth/auth/solar_auth_controller.dart';
import 'package:persynth/personality/personality_session.dart';
import 'package:persynth/widgets/solar_device_code_card.dart';

/// The app's one way in: the button that starts the Solar Network sign-in, the
/// code a waiting device-flow sign-in needs approved, and the failure of either.
///
/// Two surfaces need it — the gate, which has no session to begin with, and a
/// page that lost its session mid-use — so it lives here rather than in either
/// of them. It reports success only through the auth state it watches; the
/// surrounding surface decides what to draw next.
class SolarSignInPanel extends ConsumerStatefulWidget {
  const SolarSignInPanel({super.key});

  @override
  ConsumerState<SolarSignInPanel> createState() => _SolarSignInPanelState();
}

class _SolarSignInPanelState extends ConsumerState<SolarSignInPanel> {
  var _signingIn = false;
  String? _error;

  Future<void> _signIn() async {
    if (_signingIn) return;
    setState(() {
      _signingIn = true;
      _error = null;
    });
    try {
      await ref.read(solarAuthStateProvider.notifier).signIn();
      // The next account may not be the last one: nothing cached for the
      // previous session survives the replacement.
      invalidatePersonalitySession(ref);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _signingIn = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    // A waiting device-flow sign-in replaces the button with its code: there is
    // nothing to press until the account approves it in a browser.
    final deviceCode = ref.watch(
      solarAuthStateProvider.select((state) => state.deviceCode),
    );
    if (deviceCode != null) {
      return SolarDeviceCodeCard(authorization: deviceCode);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_error case final message?) ...[
          Material(
            color: scheme.errorContainer,
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Icon(
                    Symbols.error_rounded,
                    size: 20,
                    color: scheme.onErrorContainer,
                  ),
                  const Gap(10),
                  Expanded(
                    child: Text(
                      message,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onErrorContainer,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const Gap(16),
        ],
        FilledButton.icon(
          onPressed: _signingIn ? null : _signIn,
          icon: _signingIn
              ? SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: scheme.onPrimary,
                  ),
                )
              : const Icon(Symbols.login_rounded),
          label: Text(
            _signingIn ? 'Signing in…' : 'Continue with Solar Network',
          ),
        ),
      ],
    );
  }
}
