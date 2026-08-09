import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:island_ui_foundation/island_ui_foundation.dart';
import 'package:window_manager/window_manager.dart';

import 'package:synth_pet/router.dart';
import 'package:synth_pet/shared/desktop_window_service.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();

  var isPetWindow = false;
  if (DesktopWindowFrame.isPlatformDesktop) {
    await windowManager.ensureInitialized();
    final currentWindow = await WindowController.fromCurrentEngine();
    isPetWindow = currentWindow.arguments == DesktopWindowService.petArgument;
    if (isPetWindow) {
      await currentWindow.setWindowMethodHandler((call) async {
        if (call.method != 'set_always_on_top') {
          throw MissingPluginException();
        }
        await windowManager.setAlwaysOnTop(call.arguments as bool? ?? true);
      });
    }

    final windowOptions = WindowOptions(
      size: isPetWindow ? const Size(340, 420) : const Size(960, 640),
      minimumSize: isPetWindow ? const Size(280, 340) : const Size(720, 500),
      center: true,
      backgroundColor: Colors.transparent,
      skipTaskbar: isPetWindow,
      alwaysOnTop: isPetWindow,
      title: isPetWindow ? 'Mochi' : 'synth.pet',
      titleBarStyle: TitleBarStyle.hidden,
      windowButtonVisibility: true,
    );
    await windowManager.waitUntilReadyToShow(windowOptions, () async {
      await windowManager.show();
      await windowManager.focus();
    });
  }

  runApp(ProviderScope(child: MyApp(isPetWindow: isPetWindow)));
}

class MyApp extends StatelessWidget {
  MyApp({
    super.key,
    this.isPetWindow = false,
    this.useDesktopFrame = true,
    this.mediaQueryData,
    AppRouter? router,
  }) : _router = router ?? AppRouter(isPet: isPetWindow);

  final bool isPetWindow;
  final bool useDesktopFrame;
  final MediaQueryData? mediaQueryData;
  final AppRouter _router;

  @override
  Widget build(BuildContext context) {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF667A5A),
      brightness: Brightness.light,
    );

    return MaterialApp.router(
      title: isPetWindow ? 'Mochi' : 'synth.pet',
      theme: ThemeData(
        colorScheme: colorScheme,
        useMaterial3: true,
        fontFamily: 'Avenir Next',
      ),
      routerConfig: _router.config(),
      builder: (context, child) {
        Widget content = child ?? const SizedBox.shrink();
        final overrideMediaQuery = mediaQueryData;
        if (overrideMediaQuery != null) {
          content = MediaQuery(data: overrideMediaQuery, child: content);
        }
        if (!useDesktopFrame) return content;

        return DesktopWindowFrame(
          isDesktopPlatform: DesktopWindowFrame.isPlatformDesktop,
          title: Text(
            isPetWindow ? 'Mochi' : 'synth.pet',
            style: Theme.of(context).textTheme.labelLarge,
          ),
          child: content,
        );
      },
    );
  }
}
