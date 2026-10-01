import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:persynth/personality/personality_network.dart';
import 'package:persynth/personality/reasoning_settings.dart';
import 'package:persynth/plugins/plugin_registry.dart';
import 'package:persynth/plugins/social_plugin.dart';
import 'package:persynth/plugins/web_tools_plugin.dart';
import 'package:persynth/screens/settings_page.dart';
import 'package:persynth/theme/app_theme.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('every settings tab renders without overflowing', (
    tester,
  ) async {
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
        overrides: [
          sharedPreferencesProvider.overrideWithValue(preferences),
        ],
        child: MaterialApp(
          theme: buildPersynthTheme(Brightness.light),
          home: const SettingsPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // General holds the account/server settings; the rest are the AI console,
    // built for a full screen and now hosted a tab bar lower.
    for (final label in ['General', 'Catalog', 'Billing', 'Credentials']) {
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
        overrides: [
          sharedPreferencesProvider.overrideWithValue(preferences),
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
    List<String> offered() =>
        container.read(pluginToolsProvider).map((tool) => tool.name).toList();

    // The web plugin is on out of the box; the social set is held back.
    expect(offered(), ['web_search', 'web_fetch']);

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

    final web = find.widgetWithText(SwitchListTile, 'Web search & fetch');
    await tester.ensureVisible(web);
    await tester.pumpAndSettle();
    await tester.tap(web);
    await tester.pumpAndSettle();

    // Only what is switched on is ever offered to the model.
    expect(offered(), [loadSkillToolName]);
    expect(preferences.getBool(const WebToolsPlugin().storeKey), isFalse);
  });

  testWidgets('every Solar set has its own switch, and granting one wires it', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(preferences),
        ],
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

    final notifications = find.widgetWithText(
      SwitchListTile,
      'Notifications',
    );
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

  testWidgets('the reasoning picker reaches storage and outlives a restart', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(preferences),
        ],
        child: MaterialApp(
          theme: buildPersynthTheme(Brightness.light),
          home: const SettingsPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final picker = find.byType(DropdownButtonFormField<ReasoningSetting>);
    // The picker sits below the plugin switches, past what a lazily built
    // settings list has on screen, so the test scrolls to it as a reader would.
    await tester.dragUntilVisible(
      picker,
      find.byType(ListView),
      const Offset(0, -200),
    );
    await tester.pumpAndSettle();
    // Untouched, the run carries no reasoning controls at all and the model's
    // own default stands.
    expect(
      tester
          .widget<DropdownButtonFormField<ReasoningSetting>>(picker)
          .initialValue,
      ReasoningSetting.modelDefault,
    );

    await tester.tap(picker);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Off (no thinking)').last);
    await tester.pumpAndSettle();

    expect(preferences.getString(kReasoningSettingStoreKey), 'off');
    final container = ProviderScope.containerOf(
      tester.element(find.byType(SettingsPage)),
    );
    expect(container.read(reasoningSettingProvider), ReasoningSetting.off);

    // What is on disk is what the next launch starts from; a stored level this
    // build no longer knows falls back rather than leaving the run unstated.
    expect(ReasoningSetting.fromToken('ultra'), ReasoningSetting.ultra);
    expect(ReasoningSetting.fromToken('flux'), ReasoningSetting.modelDefault);
    expect(ReasoningSetting.fromToken(null), ReasoningSetting.modelDefault);
  });
}
