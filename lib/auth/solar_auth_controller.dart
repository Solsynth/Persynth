import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:persynth/auth/solar_auth_service.dart';

/// One shared auth service instance. The secure-storage session is the single
/// source of truth; this avoids constructing per-call instances and lets the
/// API client and the UI agree on the same session.
final solarAuthProvider = Provider<SolarAuthService>(
  (ref) => SolarAuthService(),
);

enum SolarAuthStatus { checking, signedIn, signedOut }

@immutable
class SolarAuthState {
  const SolarAuthState(this.status, this.user);

  final SolarAuthStatus status;
  final SolarUser? user;

  bool get signedIn => status == SolarAuthStatus.signedIn;
}

/// App-wide sign-in state. The conversation page and settings page watch this;
/// the Personality API client calls [markSignedOut] when a 401 could not be
/// refreshed, which turns the banner into a sign-in prompt.
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
    state = const SolarAuthState(SolarAuthStatus.checking, null);
    try {
      final user = await ref.read(solarAuthProvider).signIn();
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
  void markSignedOut() {
    state = const SolarAuthState(SolarAuthStatus.signedOut, null);
  }
}

final solarAuthStateProvider = NotifierProvider<SolarAuthNotifier, SolarAuthState>(
  SolarAuthNotifier.new,
);
