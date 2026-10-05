import 'package:auto_route/auto_route.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:gap/gap.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:persynth/auth/solar_auth_controller.dart';
import 'package:persynth/auth/solar_sign_in_panel.dart';
import 'package:persynth/router.dart';

/// The app's front door: nothing of the app's own is drawn until an account is
/// signed in, and the conversation is only reachable from here.
///
/// A cold start with no session therefore never lands on a chat surface that
/// could not send anything, and the sign-in is the first thing the user sees
/// rather than a banner over a dead composer. A session that ends while the app
/// is in use is a different case, handled where it happens: that surface shows
/// its own unauthorized status with the sign-in in place, keeping whatever the
/// user was looking at on screen.
@RoutePage()
class GatePage extends ConsumerStatefulWidget {
  const GatePage({super.key});

  @override
  ConsumerState<GatePage> createState() => _GatePageState();
}

class _GatePageState extends ConsumerState<GatePage> {
  /// Latched while the hand-over is in flight: the auth state passes through
  /// several values while a sign-in runs, and one replacement is enough for
  /// all of them.
  var _entering = false;

  void _enter() {
    if (!mounted || _entering) return;
    _entering = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      context.router.replaceAll([const ConversationRoute()]);
    });
  }

  @override
  Widget build(BuildContext context) {
    final status = ref.watch(
      solarAuthStateProvider.select((state) => state.status),
    );

    ref.listen(solarAuthStateProvider, (previous, next) {
      if (next.status == SolarAuthStatus.signedIn) _enter();
    });

    return switch (status) {
      // The launch's session read: neither the app nor a sign-in is offered
      // until it answers, so a returning user never sees a sign-in flash past.
      SolarAuthStatus.checking => const _GateFrame(
        child: Center(child: CircularProgressIndicator()),
      ),
      // A sign-in already under way keeps this panel: it is the only thing
      // holding the device code, and the failure of the attempt.
      SolarAuthStatus.signingIn ||
      SolarAuthStatus.signedOut => const _GateFrame(child: _SignInPanel()),
      SolarAuthStatus.signedIn => _ready(),
    };
  }

  Widget _ready() {
    _enter();
    return const _GateFrame(
      child: Center(child: CircularProgressIndicator()),
    );
  }
}

/// The gate's card: who the app is, what the account is for, and the one thing
/// the user can do about it.
class _SignInPanel extends StatelessWidget {
  const _SignInPanel();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // The app icon's own artwork, so the front door wears the same mark
        // the user sees in the Dock or on their home screen. The source art is
        // a full-bleed square (unlike SolWatt's pre-masked icon), so it takes
        // the same squircle the platforms do — 22.37% of the 96px tile.
        Align(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(22),
            child: Image.asset(
              'assets/icons/icon.png',
              width: 96,
              height: 96,
              fit: BoxFit.cover,
            ),
          ),
        ),
        const Gap(20),
        Text(
          'appNamePersynth'.tr(),
          textAlign: TextAlign.center,
          style: theme.textTheme.headlineMedium?.copyWith(letterSpacing: -0.5),
        ),
        const Gap(8),
        Text(
          'gateDescription'.tr(),
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyLarge?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        const Gap(28),
        const SolarSignInPanel(),
      ],
    );
  }
}

/// The gate's surface: one centered card on the app's background, sized for a
/// desktop window as much as a phone.
class _GateFrame extends StatelessWidget {
  const _GateFrame({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: scheme.surface,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 24,
                ),
                child: Material(
                  color: scheme.surfaceContainer,
                  borderRadius: BorderRadius.circular(24),
                  clipBehavior: Clip.antiAlias,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 28,
                      vertical: 32,
                    ),
                    child: child,
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
