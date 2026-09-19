import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
        overrides: [sharedPreferencesProvider.overrideWithValue(preferences)],
        child: MaterialApp(
          theme: buildSynthPetTheme(Brightness.light),
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
}
