import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:persynth/auth/solar_auth_service.dart';

/// One shared auth service instance. The secure-storage session is the single
/// source of truth; this avoids constructing per-call instances and lets the
/// API client and the UI agree on the same session.
final solarAuthProvider = Provider<SolarAuthService>(
  (ref) => SolarAuthService(),
);

/// What the stored session says right now.
///
/// [checking] and [signingIn] are both "no answer yet", but they are not the
/// same screen: a launch reads the session before anything may be drawn, while
/// a sign-in is already under way and owns what is on screen — the gate keeps
/// the sign-in panel up through it, code and failure included, instead of
/// swapping it for a spinner that would take the code away.
enum SolarAuthStatus { checking, signingIn, signedIn, signedOut }

@immutable
class SolarAuthState {
  const SolarAuthState(this.status, this.user, {this.deviceCode});

  final SolarAuthStatus status;
  final SolarUser? user;

  /// The code a device-flow sign-in is waiting on, or null when no sign-in is
  /// waiting for one. Only the web build produces it.
  final SolarDeviceAuthorization? deviceCode;

  bool get signedIn => status == SolarAuthStatus.signedIn;
}

/// App-wide sign-in state. The gate, the conversation page and the settings
/// page watch this; the Personality API client calls [markSignedOut] when a 401
/// could not be refreshed, which turns the surface in front of the user into
/// the sign-in that fixes it.
class SolarAuthNotifier extends Notifier<SolarAuthState> {
  @override
  SolarAuthState build() {
    Future.microtask(refresh);
    return const SolarAuthState(SolarAuthStatus.checking, null);
  }

  /// Re-reads the signed-in account from the session.
  Future<void> refresh() async {
    final auth = ref.read(solarAuthProvider);
    try {
      final user = await auth.currentUser();
      state = SolarAuthState(
        user == null ? SolarAuthStatus.signedOut : SolarAuthStatus.signedIn,
        user,
      );
    } on SolarAuthException {
      state = const SolarAuthState(SolarAuthStatus.signedOut, null);
    }
  }

  /// Runs the Solar OAuth flow; throws [SolarAuthException] on failure so the
  /// caller can surface the reason.
  Future<SolarUser> signIn() async {
    state = const SolarAuthState(SolarAuthStatus.signingIn, null);
    try {
      final user = await ref.read(solarAuthProvider).signIn(
        // The web needs a code approved while this waits; publishing it is what
        // puts it on screen. The other platforms never call this.
        onDeviceCode: (authorization) {
          state = SolarAuthState(
            SolarAuthStatus.signingIn,
            null,
            deviceCode: authorization,
          );
        },
      );
      state = SolarAuthState(SolarAuthStatus.signedIn, user);
      return user;
    } on SolarAuthException {
      state = const SolarAuthState(SolarAuthStatus.signedOut, null);
      rethrow;
    }
  }

  Future<void> signOut() async {
    await ref.read(solarAuthProvider).signOut();
    state = const SolarAuthState(SolarAuthStatus.signedOut, null);
  }

  /// Called by the API client when a 401 could not be refreshed: the session
  /// is gone, so the UI should invite the user to sign in again.
  ///
  /// A wait already under way — the launch's session read, or a sign-in — owns
  /// the state and is left alone: every call the app makes while it waits is
  /// unauthenticated, so the 401s that arrive are about the session being
  /// replaced, not about the attempt replacing it. Overwriting the state here
  /// would take the device code off the screen mid-flow.
  void markSignedOut() {
    if (state.status == SolarAuthStatus.checking ||
        state.status == SolarAuthStatus.signingIn) {
      return;
    }
    state = const SolarAuthState(SolarAuthStatus.signedOut, null);
  }
}

final solarAuthStateProvider = NotifierProvider<SolarAuthNotifier, SolarAuthState>(
  SolarAuthNotifier.new,
);
