import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:persynth/auth/solar_auth_controller.dart';
import 'package:persynth/auth/solar_auth_service.dart';
import 'package:persynth/personality/personality_network.dart';
import 'package:persynth/plugins/plugin_registry.dart';
import 'package:persynth/plugins/social_plugin.dart';
import 'package:persynth/plugins/web_tools_plugin.dart';
import 'package:persynth/screens/settings_page.dart';
import 'package:persynth/theme/app_theme.dart';

/// A signed-in account with no launch read behind it: the card under test only
/// needs the state, not the session lookup the real notifier performs.
class _SignedInAuth extends SolarAuthNotifier {
  _SignedInAuth(this.user);

  final SolarUser user;

  @override
  SolarAuthState build() => SolarAuthState(SolarAuthStatus.signedIn, user);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('every settings tab renders without overflowing', (tester) async {
    SharedPreferences.setMockInitialValues({});
    // The console tabs read the secure session; answer with no session so the
    // request path settles into its error state instead of hanging.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async => null,
        );
    final preferences = await SharedPreferences.getInstance();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [sharedPreferencesProvider.overrideWithValue(preferences)],
        child: MaterialApp(
          theme: buildPersynthTheme(Brightness.light),
          home: const SettingsPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // General holds the account/server settings; the rest are the AI console,
    // built for a full screen and now hosted a tab bar lower.
    for (final label in ['General', 'Catalog', 'Billing', 'Usage', 'Credentials']) {
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: '$label did not fit');
    }
  });

  testWidgets('the local tool switches decide what the companion may call', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [sharedPreferencesProvider.overrideWithValue(preferences)],
        child: MaterialApp(
          theme: buildPersynthTheme(Brightness.light),
          home: const SettingsPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(SettingsPage)),
    );
    List<String> offered() =>
        container.read(pluginToolsProvider).map((tool) => tool.name).toList();

    // The web switches are on out of the box; the social set is held back.
    expect(offered(), ['web_search', 'web_fetch']);

    // Search and fetch are one row each, and both start on.
    for (final label in ['Web search', 'Web fetch']) {
      final row = find.widgetWithText(SwitchListTile, label);
      await tester.ensureVisible(row);
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(row).value, isTrue, reason: label);
    }

    final social = find.widgetWithText(SwitchListTile, 'Moments & feed');
    await tester.ensureVisible(social);
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(social).value, isFalse);

    await tester.tap(social);
    await tester.pumpAndSettle();

    expect(container.read(pluginEnablementProvider), contains('social'));
    expect(preferences.getBool(const SocialPlugin().storeKey), isTrue);
    // The social tools are on demand: switching the plugin on offers the way
    // to load them, and loading is what puts them on the run.
    expect(offered(), ['web_search', 'web_fetch', loadSkillToolName]);

    final web = find.widgetWithText(SwitchListTile, 'Web search');
    await tester.ensureVisible(web);
    await tester.pumpAndSettle();
    await tester.tap(web);
    await tester.pumpAndSettle();

    // Only what is switched on is ever offered to the model: fetch has its own
    // switch and stays on when search is withdrawn.
    expect(offered(), ['web_fetch', loadSkillToolName]);
    expect(preferences.getBool(const WebSearchPlugin().storeKey), isFalse);
    expect(preferences.getBool(const WebFetchPlugin().storeKey), isNull);
  });

  testWidgets('every Solar set has its own switch, and granting one wires it', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [sharedPreferencesProvider.overrideWithValue(preferences)],
        child: MaterialApp(
          theme: buildPersynthTheme(Brightness.light),
          home: const SettingsPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Each set the registry declares is a row the user can actually reach,
    // rather than something only the code knows about.
    for (final label in [
      'Moments & feed',
      'Messages',
      'Notifications',
      'Calendar',
      'Daily rituals',
      'Profile & standing',
      'Wallet',
    ]) {
      final row = find.widgetWithText(SwitchListTile, label);
      await tester.ensureVisible(row);
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(row).value, isFalse, reason: label);
    }

    // A set that takes over a server tool says which one, so the switch is a
    // decision about where the call comes from rather than only what it does.
    expect(
      find.textContaining(
        "Replaces the server's get_unread_notification_count, "
        'list_notifications, mark_all_notifications_read.',
      ),
      findsOneWidget,
    );

    final container = ProviderScope.containerOf(
      tester.element(find.byType(SettingsPage)),
    );
    List<String> offered() =>
        container.read(pluginToolsProvider).map((tool) => tool.name).toList();
    expect(offered(), ['web_search', 'web_fetch']);

    final notifications = find.widgetWithText(SwitchListTile, 'Notifications');
    await tester.ensureVisible(notifications);
    await tester.pumpAndSettle();
    await tester.tap(notifications);
    await tester.pumpAndSettle();

    // Granting it is the whole of the wiring: the definitions are on the next
    // run, and the choice outlives the app.
    expect(offered(), [
      'web_search',
      'web_fetch',
      'read_notifications',
      'unread_notifications',
      'mark_all_notifications_read',
    ]);
    expect(preferences.getBool('persynth_plugin_notifications'), isTrue);
  });

  testWidgets('the account picture is drawn from the drive, token and all', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(preferences),
          solarAuthStateProvider.overrideWith(
            () => _SignedInAuth(
              const SolarUser(
                name: 'Michan',
                handle: 'michan',
                pictureId: 'pic-1',
              ),
            ),
          ),
          solarAccessTokenProvider.overrideWith((ref) async => 'token-1'),
        ],
        child: MaterialApp(
          theme: buildPersynthTheme(Brightness.light),
          home: const SettingsPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(SettingsPage)),
    );
    final avatar = tester.widget<CircleAvatar>(find.byType(CircleAvatar));
    final image =
        (avatar.foregroundImage! as ResizeImage).imageProvider as NetworkImage;

    // The profile's picture is a drive file, so its URL is the drive's and the
    // request has to carry the account's token — the endpoint is behind it.
    expect(
      image.url,
      '${container.read(personalityDriveBaseUrlProvider)}/files/pic-1',
    );
    expect(image.headers, {'Authorization': 'Bearer token-1'});
  });

  testWidgets('an account with no picture falls back to the person icon', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(preferences),
          solarAuthStateProvider.overrideWith(
            () => _SignedInAuth(
              const SolarUser(name: 'Michan', handle: 'michan'),
            ),
          ),
          solarAccessTokenProvider.overrideWith((ref) async => 'token-1'),
        ],
        child: MaterialApp(
          theme: buildPersynthTheme(Brightness.light),
          home: const SettingsPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final avatar = tester.widget<CircleAvatar>(find.byType(CircleAvatar));
    expect(avatar.foregroundImage, isNull);
    expect(find.byIcon(Symbols.person_rounded), findsOneWidget);
  });
}
