/// The script-plugin runtime, wired to the plugin registry.
///
/// The runtime itself is `island_plugin_foundation`: it discovers plugins from
/// the app's plugin directory and its bundled scripts, gives each one its own
/// JavaScript sandbox, and quarantines one that crashes on load. What this file
/// adds is the bridge between it and the companion — the `agent_tools` API a
/// script registers tools through, the [SnPlugin] view of each loaded script,
/// and the two lines that start and stop a script when its switch moves.
///
/// A script plugin is discovered, not compiled in: it appears in settings (its
/// own switch, its own description) the moment its folder is in place and the
/// app restarts. Nothing here or in the registry names one.
library;

import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:island_plugin_foundation/island_plugin_foundation.dart';

import 'package:persynth/plugins/plugin.dart';
import 'package:persynth/plugins/script_plugin.dart';
import 'package:persynth/plugins/script_tools_api.dart';

/// The registry scripts register their tools with.
///
/// One instance for the app's lifetime: the foundation hands every plugin's
/// registration to whichever instance is registered on its manager, and the
/// [ScriptPlugin] view of a script runs its tools back through the same one.
final scriptToolsApiProvider = Provider<ScriptToolsApi>(
  (ref) => ScriptToolsApi(),
);

/// The loaded script plugins, as plugins.
///
/// Rebuilt whenever the runtime reports a change — a plugin loading, being
/// unloaded, failing, or installing — so a script's tools appear and disappear
/// in step with its sandbox.
class ScriptPluginsNotifier extends Notifier<List<SnPlugin>> {
  bool _disposed = false;

  @override
  List<SnPlugin> build() {
    final api = ref.watch(scriptToolsApiProvider);
    final controller = PluginController.instance;
    void onRuntimeChanged() {
      if (_disposed) return;
      state = _snapshot(api);
    }

    controller.addListener(onRuntimeChanged);
    ref.onDispose(() {
      _disposed = true;
      controller.removeListener(onRuntimeChanged);
    });
    return _snapshot(api);
  }

  static List<SnPlugin> _snapshot(ScriptToolsApi api) {
    final controller = PluginController.instance;
    return [
      for (final instance in controller.pluginList)
        if (instance.state == PluginState.active)
          ScriptPlugin(
            manifest: instance.manifest,
            tools: api.toolsFor(instance.manifest.id),
            api: api,
          ),
    ];
  }
}

final scriptPluginsProvider =
    NotifierProvider<ScriptPluginsNotifier, List<SnPlugin>>(
      ScriptPluginsNotifier.new,
    );

/// Starts the runtime and loads the script plugins whose switches are on.
///
/// Called once from `main`, before the app runs: the runtime has to be ready
/// before anything can ask what plugins exist. A failure to start is reported
/// and swallowed — a plugin runtime that cannot come up must not keep the
/// companion from running, and every script plugin is a capability the app
/// works without.
Future<void> initializePluginHost({
  required ScriptToolsApi toolsApi,
  required bool Function(String pluginId) isEnabled,
}) async {
  final controller = PluginController.instance;
  try {
    controller.registerApi(kScriptToolsApiNamespace, toolsApi);
    await controller.initialize();
    for (final instance in controller.pluginList) {
      if (instance.state != PluginState.discovered) continue;
      if (!isEnabled(instance.manifest.id)) continue;
      await controller.loadPlugin(instance.manifest.id);
    }
  } catch (error, stack) {
    debugPrint('[plugins] script plugin runtime failed to start: $error');
    debugPrintStack(stackTrace: stack);
  }
}

/// Starts or stops one script plugin, if [id] names one.
///
/// A built-in plugin is compiled in and has nothing to load, so an id the
/// runtime does not know is left alone. Stopping unloads the sandbox, which
/// drops the tools it had registered — a withdrawn grant leaves nothing
/// callable behind.
Future<void> setScriptPluginLoaded(String id, bool enabled) async {
  final controller = PluginController.instance;
  if (!controller.plugins.containsKey(id)) return;
  if (enabled) {
    await controller.loadPlugin(id);
  } else {
    controller.unloadPlugin(id);
  }
}
