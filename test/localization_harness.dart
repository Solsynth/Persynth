/// The localization mount the widget tests need.
///
/// Every user-facing string in the app goes through `.tr()`, which resolves
/// against the `Localization` that `EasyLocalization` publishes. A test that
/// pumps its own `MaterialApp` therefore has to mount that wrapper too, or the
/// copy comes back as the bare key. The English catalogue reproduces the app's
/// original wording, so a test can keep naming what a user actually reads.
library;

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The locale the tests assert on.
const testLocale = Locale('en', 'US');

/// Prepares what `main()` prepares before it builds the wrapper. Call it once
/// from `setUpAll`.
///
/// The plugin reads the saved locale through `SharedPreferences`, so the store
/// has to be answering before it can pick a locale at all; in a test nothing
/// else does that.
Future<void> initializeLocalization() async {
  SharedPreferences.setMockInitialValues({});
  await EasyLocalization.ensureInitialized();
}

/// The wrapper `main()` puts around the app, handing [build] the context that
/// `EasyLocalization` publishes — the source of `context.locale` and of the
/// delegates the inner app has to adopt to read its copy at all.
Widget localizedApp(Widget Function(BuildContext context) build) =>
    EasyLocalization(
      supportedLocales: const [Locale('en', 'US'), Locale('zh', 'CN')],
      path: 'assets/i18n',
      fallbackLocale: testLocale,
      useFallbackTranslations: true,
      child: Builder(builder: build),
    );

/// Loads the catalogue without mounting an app.
///
/// A few builders hand their copy to something the framework renders natively
/// rather than to a widget — a context menu item's title is the case this repo
/// has — so there is no `MaterialApp` down there to give them delegates. Pumping
/// a bare `Localizations` leaves the singleton the top-level `tr()` reads filled
/// in, which is all those builders ever ask for.
Future<void> loadLocalizedCopy(WidgetTester tester) async {
  await tester.pumpWidget(
    localizedApp(
      (context) => Localizations(
        locale: context.locale,
        delegates: context.localizationDelegates,
        child: const SizedBox.shrink(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}