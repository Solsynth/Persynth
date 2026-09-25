import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:island_plugin_foundation/island_plugin_foundation.dart';

import 'package:persynth/personality/mcp_client.dart';
import 'package:persynth/plugins/plugin.dart';
import 'package:persynth/plugins/script_plugin.dart';
import 'package:persynth/plugins/script_tools_api.dart';

/// A script that registers one tool and answers it, in the same shape a plugin
/// author writes.
const _source = '''
function on_load() {
  agent_tools.register_tool(
    "discount",
    "Look up the discount on an order.",
    '{"type":"object","properties":{"order":{"type":"string"}},"required":["order"]}',
    "lookup_discount"
  );
}

function lookup_discount(args) {
  return { order: args.order, percent: 10 };
}
''';

/// The host API plus the plugin it loaded, wired the way `main` wires them.
(String, ScriptToolsApi) _install(String source) {
  final api = ScriptToolsApi();
  final controller = PluginController.instance;
  controller.registerApi(kScriptToolsApiNamespace, api);
  final instance = controller.installInlinePlugin(
    id: 'com.example.discount',
    name: 'Discount',
    source: source,
  );
  expect(
    instance.state,
    PluginState.active,
    reason: 'the script failed to load: ${instance.lastError}',
  );
  return (instance.manifest.id, api);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDownAll(() {
    for (final plugin in PluginController.instance.pluginList) {
      PluginController.instance.unloadPlugin(plugin.manifest.id);
    }
  });

  test('a script tool reaches the registry and runs in its sandbox', () async {
    final (pluginId, api) = _install(_source);

    final tools = api.toolsFor(pluginId);
    expect(tools.map((tool) => tool.name), ['discount']);
    expect(tools.single.description, 'Look up the discount on an order.');
    expect(tools.single.parameters['required'], ['order']);
    expect(tools.single.handlerName, 'lookup_discount');

    // The plugin view is what the registry offers; its body is a JS call.
    final plugin = ScriptPlugin(
      manifest: PluginController.instance.plugins[pluginId]!.manifest,
      tools: tools,
      api: api,
    );
    final built = plugin.buildTools(_context());
    expect(built.map((tool) => tool.name), ['discount']);
    expect(
      await built.single.execute({'order': 'A-1'}),
      '{"order":"A-1","percent":10}',
    );
  });

  test('a script plugin is on demand and named after its manifest', () {
    final (pluginId, api) = _install(_source);
    final plugin = ScriptPlugin(
      manifest: PluginController.instance.plugins[pluginId]!.manifest,
      tools: api.toolsFor(pluginId),
      api: api,
    );

    expect(plugin.onDemand, isTrue);
    expect(plugin.enabledByDefault, isFalse);
    expect(plugin.skillName, 'discount');
    expect(plugin.label, 'Discount');
    expect(plugin.systemPrompt(_context()).single, contains('Discount'));
  });

  test('a handler that returns nothing is an answer, not a crash', () async {
    final (pluginId, api) = _install('''
function on_load() {
  agent_tools.register_tool("broken", "Does nothing.", "{}", "no_such_function");
}
''');

    final plugin = ScriptPlugin(
      manifest: PluginController.instance.plugins[pluginId]!.manifest,
      tools: api.toolsFor(pluginId),
      api: api,
    );

    expect(
      await plugin.buildTools(_context()).single.execute({}),
      startsWith('Error: broken returned nothing'),
    );
  });

  test('an unusable registration is refused, and the rest survive', () {
    final (pluginId, api) = _install('''
function on_load() {
  agent_tools.register_tool("Good", "Uppercase is not a tool name.", "{}", "h");
  agent_tools.register_tool("ok", "Fine.", "{}", "not a function name");
  agent_tools.register_tool("good", "Fine.", "not json", "h");
  agent_tools.register_tool("kept", "Fine.", "{}", "h");
}
''');

    // A script is the user's own and may be wrong; what it got wrong is
    // dropped rather than left to fail a run.
    expect(api.toolsFor(pluginId).map((tool) => tool.name), ['kept']);
  });

  test('a script that cannot be evaluated contributes nothing', () {
    final api = ScriptToolsApi();
    PluginController.instance.registerApi(kScriptToolsApiNamespace, api);
    final instance = PluginController.instance.installInlinePlugin(
      id: 'com.example.broken',
      name: 'Broken',
      source: 'function on_load( { this is not javascript }',
    );

    expect(instance.state, PluginState.error);
    expect(api.toolsFor(instance.manifest.id), isEmpty);
  });
}

/// A context with no app behind it: nothing these tools reach for is used.
SnPluginContext _context() => SnPluginContext(
  api: Dio(),
  http: Dio(),
  mcp: _NoGateway(),
);

class _NoGateway implements McpGateway {
  @override
  Future<List<McpDaemonTool>> listTools() async => const [];

  @override
  Future<String> callTool(String name, Map<String, dynamic> arguments) async =>
      throw StateError('no daemon in this test');

  @override
  void dispose() {}
}
