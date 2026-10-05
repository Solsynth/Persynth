import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:persynth/main.dart';

import 'localization_harness.dart';

/// Registers a mock for the flutter_secure_storage platform channel so that
/// the secure-storage reads in SolarAuthService return null instead of throwing.
void _mockSecureStorage() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
        const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
        (call) async => null,
      );
}

/// Generates the pet island golden. Run once with
/// `flutter test --update-goldens`.
void main() {
  setUpAll(() async {
    await initializeLocalization();
    _mockSecureStorage();
  });

  testWidgets('pet island', (tester) async {
    tester.view.physicalSize = const Size(340, 420);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(
      localizedApp((_) => MyApp(isPetWindow: true, useDesktopFrame: false)),
    );
    await tester.pump(const Duration(milliseconds: 300));

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/pet_island.png'),
    );
  });
}
