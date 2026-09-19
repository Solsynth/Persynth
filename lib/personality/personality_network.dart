import 'package:dio/dio.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

/// The authenticated Dio the Personality API talks to. The account token is
/// attached per-request when a session exists; storage failures fall back to
/// an unauthenticated request rather than failing the call.
final personalityApiClientProvider = Provider<Dio>((ref) {
  final serverUrl = ref.watch(personalityServerUrlProvider);
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
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) async {
        try {
          final token = await SolarAuthService().accessToken();
          if (token != null && token.trim().isNotEmpty) {
            options.headers['Authorization'] = 'Bearer ${token.trim()}';
          }
        } catch (_) {
          // No session or storage unavailable: proceed unauthenticated.
        }
        handler.next(options);
      },
    ),
  );
  return dio;
});

/// The conversation/run client used by the chat controller and screens.
final personalityApiProvider = Provider<PersonalityApi>(
  (ref) => PersonalityApi(ref.watch(personalityApiClientProvider)),
);
