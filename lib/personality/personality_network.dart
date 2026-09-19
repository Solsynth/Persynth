import 'package:dio/dio.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:synth_pet/auth/solar_auth_controller.dart';
import 'package:synth_pet/auth/solar_auth_service.dart';
import 'package:synth_pet/personality/personality_api.dart';

/// The default Personality Core server, matching the app's own API base.
const kPersonalityServerDefault = 'https://api.solian.app';

/// SharedPreferences key holding an overridden Personality server base URL.
const kPersonalityServerStoreKey = 'synth_pet_personality_server_url';

/// Overridden by the app (main.dart) and by tests with the mocked instance.
final sharedPreferencesProvider = Provider<SharedPreferences>((ref) {
  throw UnimplementedError();
});

/// The Personality server base URL, persisted across launches.
class PersonalityServerUrlNotifier extends Notifier<String> {
  @override
  String build() {
    final stored = ref.watch(
      sharedPreferencesProvider.select((prefs) => prefs.getString(
        kPersonalityServerStoreKey,
      )),
    );
    return stored == null || stored.trim().isEmpty
        ? kPersonalityServerDefault
        : stored.trim();
  }

  Future<void> set(String url) async {
    final value = url.trim().isEmpty
        ? kPersonalityServerDefault
        : url.trim().replaceFirst(RegExp(r'/+$'), '');
    state = value;
    await ref
        .read(sharedPreferencesProvider)
        .setString(kPersonalityServerStoreKey, value);
  }
}

final personalityServerUrlProvider =
    NotifierProvider<PersonalityServerUrlNotifier, String>(
      PersonalityServerUrlNotifier.new,
    );

/// Builds the authenticated Personality client. The account token is attached
/// per-request when a session exists; storage failures fall back to an
/// unauthenticated request rather than failing the call.
///
/// On a 401 the stored session is force-refreshed once and the request retried
/// with the new token (concurrent 401s share one refresh). When the refresh
/// fails — no session, no refresh token, or an expired refresh token — the
/// request fails and [onAuthExpired] is called so the UI can invite the user
/// to sign in again.
Dio buildPersonalityApiDio({
  required String serverUrl,
  required SolarAuthService auth,
  required void Function() onAuthExpired,
}) {
  final dio = Dio(
    BaseOptions(
      baseUrl: serverUrl,
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 10),
      headers: {
        'Accept': 'application/json',
        'Content-Type': 'application/json',
      },
    ),
  );

  // One refresh in flight at a time; a burst of 401s waits on the same one.
  Future<String?>? pendingRefresh;

  Future<String?> refreshAccessToken() {
    final pending = pendingRefresh;
    if (pending != null) return pending;
    final future = auth.forceRefresh();
    pendingRefresh = future;
    future.whenComplete(() => pendingRefresh = null);
    return future;
  }

  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) async {
        try {
          final token = await auth.accessToken();
          if (token != null && token.trim().isNotEmpty) {
            options.headers['Authorization'] = 'Bearer ${token.trim()}';
          }
        } catch (_) {
          // No session or storage unavailable: proceed unauthenticated.
        }
        handler.next(options);
      },
      onError: (error, handler) async {
        final status = error.response?.statusCode;
        final retried = error.requestOptions.extra['authRetried'] == true;
        if (status != 401 || retried) {
          handler.next(error);
          return;
        }
        String? newToken;
        try {
          newToken = await refreshAccessToken();
        } catch (_) {
          newToken = null;
        }
        if (newToken == null || newToken.trim().isEmpty) {
          onAuthExpired();
          handler.next(error);
          return;
        }
        final options = error.requestOptions;
        options.extra['authRetried'] = true;
        try {
          final retriedResponse = await dio.fetch(options);
          handler.resolve(retriedResponse);
        } catch (retryError) {
          handler.next(retryError is DioException ? retryError : error);
        }
      },
    ),
  );
  return dio;
}

/// The authenticated Dio the Personality API talks to.
final personalityApiClientProvider = Provider<Dio>((ref) {
  final serverUrl = ref.watch(personalityServerUrlProvider);
  return buildPersonalityApiDio(
    serverUrl: serverUrl,
    auth: ref.watch(solarAuthProvider),
    onAuthExpired: () {
      ref.read(solarAuthStateProvider.notifier).markSignedOut();
    },
  );
});

/// The conversation/run client used by the chat controller and screens.
final personalityApiProvider = Provider<PersonalityApi>(
  (ref) => PersonalityApi(ref.watch(personalityApiClientProvider)),
);
