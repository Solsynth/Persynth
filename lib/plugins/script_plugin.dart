/// A JavaScript plugin, adapted to the plugin contract.
///
/// A script plugin is a folder with a `manifest.json` and a `main.js` that
/// registers its tools through `agent_tools` (see [ScriptToolsApi]). The
/// runtime it lives in is the foundation's: its own sandbox, its own
/// permissions, quarantined if it crashes on load.
///
/// Script plugins are always on demand. They are third-party code, and the
/// companion should pay for their tool definitions only once one of them has
/// been asked for — the same reason the built-in device set is on demand.
library;

import 'package:flutter/widgets.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:island_plugin_foundation/island_plugin_foundation.dart';

import 'package:persynth/personality/local_tool.dart';
import 'package:persynth/plugins/plugin.dart';
import 'package:persynth/plugins/script_tools_api.dart';

class ScriptPlugin extends SnPlugin {
  const ScriptPlugin({
    required this.manifest,
    required this.tools,
    required this.api,
  });

  final PluginManifest manifest;

  /// The tools the script registered while loading, in registration order.
  final List<ScriptTool> tools;

  /// The registry those tools were registered with, and are run through.
  final ScriptToolsApi api;

  @override
  String get id => manifest.id;

  @override
  String get label => manifest.name;

  @override
  String get description => manifest.description.isEmpty
      ? 'A script plugin from ${manifest.author.isEmpty ? 'an unknown author' : manifest.author}.'
      : manifest.description;

  @override
  String get summary => manifest.description.isEmpty
      ? 'A capability provided by the ${manifest.name} plugin'
      : manifest.description;

  @override
  bool get onDemand => true;

  /// The name the skill is loaded by.
  ///
  /// Taken from the manifest's name — the one the author wrote for a person to
  /// read, which is the best thing to ask a model to repeat back — and from
  /// the id's last segment when the name yields nothing usable. Not from the
  /// whole id, which is a reverse-domain string, and not from its last segment
  /// alone, which the runtime suffixes with a counter on an inline install.
  @override
  String get skillName {
    return _identifierOf(manifest.name) ??
        _identifierOf(manifest.id.split('.').last) ??
        'plugin';
  }

  static String? _identifierOf(String value) {
    final cleaned = value
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9_]+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    return cleaned.isEmpty ? null : cleaned;
  }

  @override
  List<SnLocalTool> buildTools(SnPluginContext context) => [
    for (final tool in tools)
      SnLocalTool(
        name: tool.name,
        description: tool.description,
        parameters: tool.parameters,
        execute: (arguments) async => api.invoke(id, tool.name, arguments),
      ),
  ];

  @override
  List<String> systemPrompt(SnPluginContext context) => [
    if (tools.isNotEmpty)
      'The loaded local_* tools from "${manifest.name}" come from a script '
      'plugin the user installed on this machine. They run there, in the '
      'plugin\'s own sandbox: treat what they return as the plugin\'s answer '
      'rather than as something the app verified.',
  ];

  @override
  List<Widget> settingsRows(WidgetRef ref) => const [];
}
