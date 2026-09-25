import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:island_ui_foundation/island_ui_foundation.dart';
import 'package:material_ui/material_ui.dart' as mui;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

import 'package:persynth/personality/personality_network.dart';
import 'package:persynth/router.dart';
import 'package:persynth/shared/desktop_window_service.dart';
import 'package:persynth/theme/app_theme.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  final preferences = await SharedPreferences.getInstance();

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
      title: isPetWindow ? 'Mochi' : 'Persynth',
      titleBarStyle: TitleBarStyle.hidden,
      windowButtonVisibility: true,
    );
    await windowManager.waitUntilReadyToShow(windowOptions, () async {
      await windowManager.show();
      await windowManager.focus();
    });
  }

  runApp(
    ProviderScope(
      overrides: [sharedPreferencesProvider.overrideWithValue(preferences)],
      child: MyApp(isPetWindow: isPetWindow),
    ),
  );
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
    return MaterialApp.router(
      title: isPetWindow ? 'Mochi' : 'Persynth',
      theme: buildPersynthTheme(Brightness.light),
      darkTheme: buildPersynthTheme(Brightness.dark),
      themeMode: ThemeMode.system,
      routerConfig: _router.config(),
      builder: (context, child) {
        Widget content = child ?? const SizedBox.shrink();
        final overrideMediaQuery = mediaQueryData;
        if (overrideMediaQuery != null) {
          content = MediaQuery(data: overrideMediaQuery, child: content);
        }
        if (!useDesktopFrame) return content;

        // The pet window draws itself as a floating island, so it needs no
        // chrome. Everything else gets the quiet desktop frame.
        if (isPetWindow && DesktopWindowFrame.isPlatformDesktop) return content;

        // DesktopWindowFrame (island_ui_foundation) paints with the
        // `material_ui` fork's Material, which reads a separate theme system
        // from Flutter's. Without a material_ui Theme in scope it falls back
        // to the fork's default (always-light) scheme. Mirror the app scheme
        // so the chrome (the shell step, by design) follows light/dark mode.
        final scheme = Theme.of(context).colorScheme;
        final brightness = Theme.of(context).brightness;
        final chromeScheme = mui.ColorScheme.fromSeed(
          seedColor: scheme.primary,
          brightness: brightness,
        ).copyWith(surfaceContainer: scheme.surfaceContainer);
        final chromeTheme = (brightness == Brightness.dark
                ? mui.ThemeData.dark()
                : mui.ThemeData.light())
            .copyWith(colorScheme: chromeScheme);

        return mui.Theme(
          data: chromeTheme,
          child: DesktopWindowFrame(
            isDesktopPlatform: DesktopWindowFrame.isPlatformDesktop,
            title: Text(
              isPetWindow ? 'Mochi' : 'Persynth',
              style: TextStyle(
                fontFamily: PersynthFonts.display,
                fontSize: 11,
                letterSpacing: 1.1,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            child: content,
          ),
        );
      },
    );
  }
}
