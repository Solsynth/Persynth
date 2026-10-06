import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:solsynth_express/solsynth_express.dart';

import 'package:persynth/personality/personality_network.dart';
import 'package:persynth/screens/settings_page.dart';
import 'package:persynth/shared/app_update.dart';
import 'package:persynth/theme/app_theme.dart';

import 'localization_harness.dart';

/// Counts the checks the launch hook asks for, so the switch can be shown to
/// decide whether the request happens at all. The real service is replaced
/// wholesale: what it answers is the package's business.
class _RecordingUpdateService extends UpdateService {
  _RecordingUpdateService()
    : super(apiBaseUrl: 'https://updates.invalid', productId: 'test-product');

  int checks = 0;

  @override
  Future<void> checkForUpdates(BuildContext context) async {
    checks++;
  }
}

/// Scrolls the settings list down until [target] has been built.
///
/// The card under test sits below the fold of the test window, and a `ListView`
/// only builds what it is showing, so the rows have to be dragged into being
/// rather than looked up.
Future<void> _scrollTo(WidgetTester tester, Finder target) async {
  for (var attempt = 0; attempt < 40 && target.evaluate().isEmpty; attempt++) {
    final list = find.byType(ListView);
    if (list.evaluate().isEmpty) return;
    await tester.drag(list.first, const Offset(0, -300));
    await tester.pumpAndSettle();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(initializeLocalization);

  // One mount for the file: a second `localizedApp` in the same process comes
  // up empty, so the launch check and the switch are exercised together — the
  // switch is what the hook reads, and turning it off is the relaunch.
  testWidgets('the launch check follows the switch, and the section shows it', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    // The console behind the other tabs reads the secure session; answer with
    // no session so the request path settles into its error state.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async => null,
        );
    final preferences = await SharedPreferences.getInstance();
    final service = _RecordingUpdateService();

    // A fresh container per launch, the way a relaunch reads the store again.
    Widget app() => ProviderScope(
      key: UniqueKey(),
      overrides: [
        sharedPreferencesProvider.overrideWithValue(preferences),
        updateServiceProvider.overrideWithValue(service),
        packageInfoProvider.overrideWith(
          (ref) async => PackageInfo(
            appName: 'Persynth',
            packageName: 'dev.solsynth.pet',
            version: '1.0.0',
            buildNumber: '4',
          ),
        ),
      ],
      child: localizedApp(
        (context) => MaterialApp(
          theme: buildPersynthTheme(Brightness.light),
          locale: context.locale,
          supportedLocales: context.supportedLocales,
          localizationsDelegates: context.localizationDelegates,
          home: const UpdateCheckOnLaunch(child: SettingsPage()),
        ),
      ),
    );

    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    // The launch asked, and the app behind it is really there — an empty tree
    // would otherwise read as "asked nothing".
    expect(find.byType(SettingsPage), findsOneWidget);
    expect(service.checks, 1);

    // The row names the build the check compares against, so a user can tell
    // what the sheet's version is newer than.
    final row = find.widgetWithText(ListTile, 'Check for updates');
    await _scrollTo(tester, row);
    expect(row, findsOneWidget);
    expect(find.text('Installed version 1.0.0+4'), findsOneWidget);

    final toggle = find.widgetWithText(
      SwitchListTile,
      'Check for updates on launch',
    );
    await _scrollTo(tester, toggle);
    expect(tester.widget<SwitchListTile>(toggle).value, isTrue);

    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(preferences.getBool(kUpdateChecksStoreKey), isFalse);

    // The next launch reads that switch: asking on its own is a request the
    // user did not make, and one flip is their whole say over it.
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    expect(find.byType(SettingsPage), findsOneWidget);
    expect(service.checks, 1, reason: 'the check is switched off');
  });
}
