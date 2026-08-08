import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:island_ui_foundation/island_ui_foundation.dart';

class DesktopWindowService {
  const DesktopWindowService._();

  static const petArgument = 'pet';

  static Future<void> openPetWindow() async {
    if (!DesktopWindowFrame.isPlatformDesktop) return;

    final windows = await WindowController.getAll();
    WindowController? petWindow;
    for (final window in windows) {
      if (window.arguments == petArgument) {
        petWindow = window;
        break;
      }
    }

    petWindow ??= await WindowController.create(
      const WindowConfiguration(arguments: petArgument, hiddenAtLaunch: true),
    );
    await petWindow.show();
  }

  static Future<void> setPetAlwaysOnTop(bool value) async {
    if (!DesktopWindowFrame.isPlatformDesktop) return;

    final windows = await WindowController.getAll();
    WindowController? petWindow;
    for (final window in windows) {
      if (window.arguments == petArgument) {
        petWindow = window;
        break;
      }
    }

    if (petWindow == null) {
      if (value) await openPetWindow();
      return;
    }

    await petWindow.invokeMethod<void>('set_always_on_top', value);
  }
}
