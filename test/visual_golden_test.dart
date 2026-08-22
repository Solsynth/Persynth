import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synth_pet/main.dart';

/// Registers a mock for the flutter_secure_storage platform channel so that
/// the secure-storage reads in SolarAuthService return null instead of throwing.
void _mockSecureStorage() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
        const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
        (call) async => null,
      );
}

/// Generates goldens for all three app windows. Run once with
/// `flutter test --update-goldens`.
void main() {
  setUpAll(_mockSecureStorage);

  testWidgets('config window', (tester) async {
    tester.view.physicalSize = const Size(960, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(MyApp(useDesktopFrame: false));
    await tester.pumpAndSettle();

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/config_window.png'),
    );
  });

  testWidgets('conversation tab', (tester) async {
    tester.view.physicalSize = const Size(960, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(MyApp(useDesktopFrame: false));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.chat_bubble_outline), findsOneWidget);
    await tester.tap(find.byIcon(Icons.chat_bubble_outline));
    await tester.pump();
    expect(find.byKey(const ValueKey('conversation')), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 400));

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/conversation_tab.png'),
    );
  });

  testWidgets('pet island', (tester) async {
    tester.view.physicalSize = const Size(340, 420);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(MyApp(isPetWindow: true, useDesktopFrame: false));
    await tester.pump(const Duration(milliseconds: 300));

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/pet_island.png'),
    );
  });
}
