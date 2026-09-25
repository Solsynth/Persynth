import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:synth_pet/personality/local_tools.dart';
import 'package:synth_pet/personality/mcp_client.dart';
import 'package:synth_pet/personality/personality_network.dart';
import 'package:synth_pet/screens/settings_page.dart';
import 'package:synth_pet/theme/app_theme.dart';

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
          // The row probes the daemon over the network; tests answer for it
          // instead of going near the loopback.
          mcpDaemonStatusProvider.overrideWith(
            (ref) async => const McpDaemonStatus(reachable: false),
          ),
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

  testWidgets('the MCP daemon the device tools lean on is reported', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(preferences),
          mcpDaemonStatusProvider.overrideWith(
            (ref) async => const McpDaemonStatus(
              reachable: true,
              toolCount: 3,
            ),
          ),
        ],
        child: MaterialApp(
          theme: buildPersynthTheme(Brightness.light),
          home: const SettingsPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('MCP daemon'), findsOneWidget);
    expect(find.textContaining('Running on'), findsOneWidget);
    expect(find.textContaining('3 tools'), findsOneWidget);
    expect(find.text('Check again'), findsOneWidget);
  });

  testWidgets('an unreachable daemon is reported with how to start it', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(preferences),
          mcpDaemonStatusProvider.overrideWith(
            (ref) async => const McpDaemonStatus(reachable: false),
          ),
        ],
        child: MaterialApp(
          theme: buildPersynthTheme(Brightness.light),
          home: const SettingsPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('MCP daemon'), findsOneWidget);
    expect(find.textContaining('Not running'), findsOneWidget);
    expect(find.textContaining('dart run synthpet_mcp'), findsOneWidget);
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
          mcpDaemonStatusProvider.overrideWith(
            (ref) async => const McpDaemonStatus(reachable: false),
          ),
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
        container.read(localToolsProvider).map((tool) => tool.name).toList();

    // The web set is on out of the box; the device set is held back.
    expect(offered(), ['web_search_local', 'web_fetch_local']);

    final device = find.widgetWithText(SwitchListTile, 'Files & commands');
    await tester.ensureVisible(device);
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(device).value, isFalse);

    await tester.tap(device);
    await tester.pumpAndSettle();

    expect(container.read(localToolSettingsProvider).device, isTrue);
    expect(preferences.getBool(kLocalDeviceToolsStoreKey), isTrue);
    expect(offered(), contains('mcp_run_command'));

    final web = find.widgetWithText(SwitchListTile, 'Web search & fetch');
    await tester.ensureVisible(web);
    await tester.pumpAndSettle();
    await tester.tap(web);
    await tester.pumpAndSettle();

    // Only what is switched on is ever offered to the model.
    expect(offered(), ['mcp_read_file', 'mcp_list_dir', 'mcp_run_command']);
    expect(preferences.getBool(kLocalWebToolsStoreKey), isFalse);
  });
}
