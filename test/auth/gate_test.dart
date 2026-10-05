import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:persynth/auth/solar_auth_controller.dart';
import 'package:persynth/auth/solar_auth_service.dart';
import 'package:persynth/gate/gate_page.dart';
import 'package:persynth/main.dart';
import 'package:persynth/personality/personality_api.dart';
import 'package:persynth/personality/personality_network.dart';
import 'package:persynth/router.dart';
import 'package:persynth/screens/conversation_page.dart';
import 'package:persynth/theme/app_theme.dart';

const _agent = SnPersonalityAgent(id: 'a1', name: 'Michan', enabled: true);
const _user = SolarUser(name: 'Test', handle: 'tester');

/// The app's own routes: the gate is the front door and the conversation sits
/// behind it, which is the behaviour under test.
class _GateTestRouter extends RootStackRouter {
  @override
  List<AutoRoute> get routes => [
    AutoRoute(page: GateRoute.page, path: '/', initial: true),
    AutoRoute(page: ConversationRoute.page, path: '/conversation'),
    AutoRoute(page: SettingsRoute.page, path: '/settings'),
  ];
}

/// Deterministic auth: [initial] is the session the app starts with, and a
/// sign-in moves it to signed in — publishing [deviceCode] first and waiting on
/// [approved] when there is one, exactly as the web build's flow does.
class _StubSolarAuthNotifier extends SolarAuthNotifier {
  _StubSolarAuthNotifier(this.initial, {this.deviceCode});

  final SolarAuthState initial;
  final SolarDeviceAuthorization? deviceCode;

  /// Completed by the test to approve a device-flow sign-in.
  final Completer<void> approved = Completer<void>();

  @override
  SolarAuthState build() => initial;

  @override
  Future<SolarUser> signIn() async {
    final code = deviceCode;
    if (code != null) {
      state = SolarAuthState(SolarAuthStatus.signingIn, null, deviceCode: code);
      await approved.future;
    }
    state = const SolarAuthState(SolarAuthStatus.signedIn, _user);
    return _user;
  }

  @override
  Future<void> signOut() async {
    state = const SolarAuthState(SolarAuthStatus.signedOut, null);
  }
}

Future<void> _pumpApp(
  WidgetTester tester,
  _StubSolarAuthNotifier auth,
) async {
  final preferences = await SharedPreferences.getInstance();
  await tester.runAsync(() async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(preferences),
          personalityAgentsProvider.overrideWith((ref) async => [_agent]),
          personalityConversationsProvider.overrideWith(
            (ref) async => const <SnPersonalityConversation>[],
          ),
          solarAuthStateProvider.overrideWith(() => auth),
        ],
        child: EasyLocalization(
          supportedLocales: const [Locale('en', 'US'), Locale('zh', 'CN')],
          path: 'assets/i18n',
          fallbackLocale: const Locale('en', 'US'),
          useFallbackTranslations: true,
          child: Builder(
            builder: (context) => MaterialApp.router(
              routerConfig: _GateTestRouter().config(),
              theme: buildPersynthTheme(Brightness.light),
              locale: context.locale,
              supportedLocales: context.supportedLocales,
              localizationsDelegates: context.localizationDelegates,
            ),
          ),
        ),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));
  });
}

/// Pumps frames rather than settling: a sign-in passes through a spinner, which
/// never settles while it is on screen.
Future<void> _pumpFrames(WidgetTester tester, [int frames = 10]) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// Pumps the app as it ships: [MyApp] with the real router, so the initial
/// route and the hand-over off it are the ones under test. [storedAuth] is the
/// session the launch finds; the test router cases below replace it instead.
Future<void> _pumpRealApp(
  WidgetTester tester, {
  SolarAuthService? storedAuth,
}) async {
  final preferences = await SharedPreferences.getInstance();
  await tester.runAsync(() async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(preferences),
          if (storedAuth != null)
            solarAuthProvider.overrideWithValue(storedAuth),
          personalityAgentsProvider.overrideWith((ref) async => [_agent]),
          personalityConversationsProvider.overrideWith(
            (ref) async => const <SnPersonalityConversation>[],
          ),
        ],
        child: EasyLocalization(
          supportedLocales: const [Locale('en', 'US'), Locale('zh', 'CN')],
          path: 'assets/i18n',
          fallbackLocale: const Locale('en', 'US'),
          useFallbackTranslations: true,
          child: MyApp(useDesktopFrame: false),
        ),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
  });

  testWidgets('holds the app at the sign-in until there is a session', (
    tester,
  ) async {
    await _pumpApp(
      tester,
      _StubSolarAuthNotifier(
        const SolarAuthState(SolarAuthStatus.signedOut, null),
      ),
    );
    await _pumpFrames(tester, 3);

    expect(find.byType(GatePage), findsOneWidget);
    expect(find.text('Persynth'), findsOneWidget);
    expect(find.text('Continue with Solar Network'), findsOneWidget);
    // Nothing of the app is drawn behind the gate.
    expect(find.byType(ConversationPage), findsNothing);

    await tester.tap(find.text('Continue with Solar Network'));
    await _pumpFrames(tester);

    expect(find.byType(GatePage), findsNothing);
    expect(find.byType(ConversationPage), findsOneWidget);
  });

  testWidgets('waits on the code a web sign-in needs approved', (tester) async {
    final auth = _StubSolarAuthNotifier(
      const SolarAuthState(SolarAuthStatus.signedOut, null),
      deviceCode: SolarDeviceAuthorization(
        userCode: 'WDJB-MJHT',
        verificationUri: Uri.parse('https://id.solian.app/auth/device'),
        verificationUriComplete: Uri.parse(
          'https://id.solian.app/auth/device?code=WDJB-MJHT',
        ),
        expiresAt: DateTime(2026, 1, 1),
      ),
    );
    await _pumpApp(tester, auth);
    await _pumpFrames(tester, 3);

    await tester.tap(find.text('Continue with Solar Network'));
    await _pumpFrames(tester, 3);

    // Nothing to press until the browser approves the code, and the code the
    // user has to type is on screen rather than in a banner over the chat.
    expect(find.text('WDJB-MJHT'), findsOneWidget);
    expect(find.text('Continue with Solar Network'), findsNothing);
    expect(find.byType(GatePage), findsOneWidget);

    auth.approved.complete();
    await _pumpFrames(tester);

    expect(find.byType(ConversationPage), findsOneWidget);
  });

  testWidgets('shows the gate, not a sign-in, while the session is read', (
    tester,
  ) async {
    await _pumpApp(
      tester,
      _StubSolarAuthNotifier(
        const SolarAuthState(SolarAuthStatus.checking, null),
      ),
    );
    await _pumpFrames(tester, 3);

    expect(find.byType(GatePage), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('Continue with Solar Network'), findsNothing);
  });

  testWidgets('signing out hands the settings account card back to the gate', (
    tester,
  ) async {
    await _pumpApp(
      tester,
      _StubSolarAuthNotifier(
        const SolarAuthState(SolarAuthStatus.signedIn, _user),
      ),
    );
    // The gate's hand-over is a route replacement: let its transition finish
    // before touching the app bar it moved on screen.
    await _pumpFrames(tester);

    await tester.tap(find.byIcon(Symbols.tune_rounded));
    await _pumpFrames(tester);
    expect(find.text('Sign out'), findsOneWidget);

    await tester.tap(find.text('Sign out'));
    await _pumpFrames(tester, 5);

    expect(find.text('Sign out'), findsNothing);
    expect(find.text('Continue with Solar Network'), findsOneWidget);
  });

  /// The app's own wiring, which the cases above swap a router for: the gate is
  /// the initial route, and a stored session is what leaves it.
  testWidgets('the real app opens on the gate without a session', (
    tester,
  ) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async => null,
        );

    await _pumpRealApp(tester);
    await _pumpFrames(tester, 5);

    expect(find.byType(GatePage), findsOneWidget);
    expect(find.text('Continue with Solar Network'), findsOneWidget);
  });

  testWidgets('the real app hands a stored session to the conversation', (
    tester,
  ) async {
    await _pumpRealApp(tester, storedAuth: _StoredSessionAuthService());
    await _pumpFrames(tester, 10);

    expect(find.byType(GatePage), findsNothing);
    expect(find.byType(ConversationPage), findsOneWidget);
  });
}

/// The real app's auth service with a session already stored: what a returning
/// launch has before anything has been drawn.
class _StoredSessionAuthService extends SolarAuthService {
  @override
  Future<SolarUser?> currentUser() async => _user;
}
