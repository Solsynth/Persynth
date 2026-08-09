import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synth_pet/main.dart';

void main() {
  testWidgets('renders the configuration window', (tester) async {
    await tester.pumpWidget(MyApp(useDesktopFrame: false));
    await tester.pumpAndSettle();

    expect(find.text('Configuration'), findsWidgets);
    expect(find.text('Mochi'), findsNothing);
    expect(find.text('Appearance'), findsNothing);
    expect(find.text('Show pet'), findsOneWidget);
    expect(find.text('synth.pet'), findsNothing);
    expect(find.text('Sign in'), findsOneWidget);
  });

  testWidgets('renders the pet window route', (tester) async {
    await tester.pumpWidget(MyApp(isPetWindow: true, useDesktopFrame: false));
    await tester.pumpAndSettle();
    expect(find.text('Mochi'), findsOneWidget);
    expect(find.text('Mochi is here'), findsOneWidget);
  });

  testWidgets('uses the simplified mobile configuration layout', (
    tester,
  ) async {
    await tester.pumpWidget(
      MyApp(
        useDesktopFrame: false,
        mediaQueryData: const MediaQueryData(size: Size(390, 844)),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(NavigationBar), findsNothing);
    expect(find.text('Configuration'), findsOneWidget);
  });
}
