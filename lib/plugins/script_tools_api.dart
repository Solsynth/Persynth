/// The bridge that lets a JavaScript plugin contribute tools to the companion.
///
/// A script plugin registers a tool by name and points it at one of its own
/// functions:
///
/// ```javascript
/// function on_load() {
///   agent_tools.register_tool(
///     "discount",
///     "Look up the discount on an order.",
///     '{"type":"object","properties":{"order":{"type":"string"}},"required":["order"]}',
///     "lookup_discount"
///   );
/// }
///
/// function lookup_discount(args) {
///   return { order: args.order, percent: 10 };
/// }
/// ```
///
/// The handler runs in the plugin's own sandbox and returns a value the host
/// turns into the tool's answer: an object or array is sent to the model as
/// JSON, a string as written. A handler that returns nothing is reported to
/// the model as a failure, so a tool with nothing to say returns `""`.
///
/// Handlers run synchronously, the same way the foundation's own commands and
/// hooks do: the runtime exposes no way to await a promise from a call. A tool
/// that needs to reach the network should call a host API the app provides
/// rather than fetching on its own.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:island_plugin_foundation/island_plugin_foundation.dart';

/// A tool a script plugin registered, before it is bound to a runtime.
class ScriptTool {
  const ScriptTool({
    required this.pluginId,
    required this.name,
    required this.description,
    required this.parameters,
    required this.handlerName,
  });

  /// The plugin that registered it, as the manifest names it.
  final String pluginId;

  /// The wire name the model calls, already namespaced.
  final String name;

  final String description;

  /// JSON Schema of the arguments object.
  final Map<String, dynamic> parameters;

  /// The plugin's own function to call, e.g. `lookup_discount`.
  final String handlerName;
}

/// The namespace the API is registered under, i.e. the JS global a plugin
/// calls: `agent_tools.register_tool(...)`.
const String kScriptToolsApiNamespace = 'agent_tools';

/// A JS identifier, which is all a handler name may be — it is interpolated
/// into an `eval` by the runtime's `callFunction`.
final RegExp _jsIdentifier = RegExp(r'^[A-Za-z_$][A-Za-z0-9_$]*$');

/// The shape a tool name must have: the model's providers accept only
/// `[a-zA-Z0-9_-]` once the server has namespaced it, and a name that fails
/// that fails the whole run.
final RegExp _toolName = RegExp(r'^[a-z][a-z0-9_]{0,47}$');

/// Reports a plugin that contributed something unusable. A script is the
/// user's own and may be wrong; the app carries on without the tool.
void _warn(String message) => debugPrint('[plugins] $message');

/// Collects the tools script plugins register, and runs them.
///
/// One instance is registered on the plugin manager, so every plugin's
/// registration lands here; [toolsFor] hands them back per plugin.
class ScriptToolsApi extends PluginApi {
  final Map<String, ScriptTool> _tools = {};

  /// The tools a plugin registered, in registration order.
  ///
  /// Registration order is the script's `on_load` order, which is what the
  /// author sees — so it is what the model is offered.
  List<ScriptTool> toolsFor(String pluginId) => [
    for (final tool in _tools.values)
      if (tool.pluginId == pluginId) tool,
  ];

  /// Runs one tool inside its plugin's sandbox and returns the model's answer.
  ///
  /// Every failure — a plugin that is no longer loaded, a handler that threw,
  /// a handler that returned nothing — comes back as text, because a broken
  /// plugin is an answer about the tool rather than a defect of the run.
  String invoke(String pluginId, String toolName, Map<String, dynamic> arguments) {
    final tool = _tools[toolName];
    if (tool == null || tool.pluginId != pluginId) {
      return 'Error: no such tool: $toolName';
    }
    final runtime = PluginController.instance.manager.plugins[pluginId]?.runtime;
    if (runtime == null) {
      return 'Error: plugin ${tool.pluginId} is not loaded.';
    }
    // The runtime reports a call's result in its JavaScript string form, which
    // flattens an object to "[object Object]" and loses the arguments the
    // script is meant to have. The call is therefore wrapped to hand the
    // arguments over as JSON and answer with JSON: the value, and whether the
    // handler produced one at all.
    final argumentsLiteral = jsonEncode(jsonEncode(arguments));
    final envelope = runtime.eval(
      '(function(){'
      'var r=${tool.handlerName}(JSON.parse($argumentsLiteral));'
      'return JSON.stringify({'
      'ok:r!==undefined&&r!==null,'
      'value:r===undefined||r===null?null:r});'
      '})()',
    );
    if (envelope is! Map || envelope['ok'] != true) {
      return 'Error: ${tool.name} returned nothing '
          '(its handler ${tool.handlerName} threw or returned null).';
    }
    final value = envelope['value'];
    if (value is String) return value;
    if (value is Map || value is List) return jsonEncode(value);
    return '$value';
  }

  @override
  Set<PluginPermission> get requiredPermissions => const {};

  @override
  void register(PluginContext context, JsRuntime runtime) {
    runtime.exec('''
var agent_tools = {};
agent_tools.register_tool = function(name, description, parameters, handler) {
  sendMessage("api:agent_tools:register", JSON.stringify({
    name: name,
    description: description,
    parameters: parameters === undefined || parameters === null ? null : parameters,
    handler: handler
  }));
};
''');
    runtime.onMessage('api:agent_tools:register', (raw) {
      final data = context.decode(raw);
      final name = (data['name'] ?? '').toString().trim();
      final description = (data['description'] ?? '').toString().trim();
      final handler = (data['handler'] ?? '').toString().trim();
      if (name.isEmpty || description.isEmpty) {
        _warn(
          'Plugin ${context.pluginId} registered a tool without a name or '
          'description; ignored.',
        );
        return;
      }
      if (!_jsIdentifier.hasMatch(handler)) {
        _warn(
          'Plugin ${context.pluginId} tool "$name" names a handler that is not '
          'a function name ("$handler"); ignored.',
        );
        return;
      }
      final parameters = _parameters(data['parameters']);
      if (parameters == null) {
        _warn(
          'Plugin ${context.pluginId} tool "$name" has parameters that are not '
          'a JSON object; ignored.',
        );
        return;
      }
      if (!_toolName.hasMatch(name)) {
        _warn(
          'Plugin ${context.pluginId} tool name "$name" is not a lower-case '
          'identifier; ignored.',
        );
        return;
      }
      if (_tools.containsKey(name)) {
        _warn(
          'Tool "$name" is already registered by ${_tools[name]!.pluginId}; '
          'the one from ${context.pluginId} is ignored.',
        );
        return;
      }
      _tools[name] = ScriptTool(
        pluginId: context.pluginId,
        name: name,
        description: description,
        parameters: parameters,
        handlerName: handler,
      );
    });
  }

  @override
  void onPluginUnload(String pluginId) {
    _tools.removeWhere((_, tool) => tool.pluginId == pluginId);
  }

  @override
  void reset() => _tools.clear();

  /// The tool's JSON Schema, or null when the plugin gave something that is
  /// not an object — a tool whose arguments the model cannot see is worse than
  /// an absent one.
  static Map<String, dynamic>? _parameters(Object? raw) {
    if (raw == null) {
      return const {'type': 'object', 'properties': <String, dynamic>{}};
    }
    if (raw is Map) return Map<String, dynamic>.from(raw);
    if (raw is String) {
      final trimmed = raw.trim();
      if (trimmed.isEmpty) {
        return const {'type': 'object', 'properties': <String, dynamic>{}};
      }
      try {
        final decoded = jsonDecode(trimmed);
        if (decoded is Map) return Map<String, dynamic>.from(decoded);
      } catch (_) {
        return null;
      }
    }
    return null;
  }
}
