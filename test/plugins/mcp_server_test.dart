import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:persynth/personality/local_tool.dart';
import 'package:persynth/personality/personality_network.dart';
import 'package:persynth/plugins/mcp_client.dart';
import 'package:persynth/plugins/mcp_server_plugin.dart';
import 'package:persynth/plugins/mcp_servers.dart';
import 'package:persynth/plugins/mcp_servers_section.dart';
import 'package:persynth/plugins/plugin.dart';
import 'package:persynth/plugins/plugin_registry.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The shape the model's providers accept once the server has namespaced a
/// name. A name outside it fails the whole run, so it is what the tests hold
/// the app's own naming to.
final _wireName = RegExp(r'^[a-z][a-z0-9_]{0,47}$');

McpServerTool _tool(String name, {String description = ''}) => McpServerTool(
  name: name,
  description: description.isEmpty ? 'The $name tool.' : description,
  inputSchema: const {
    'type': 'object',
    'properties': {
      'query': {'type': 'string'},
    },
    'required': ['query'],
  },
);

/// An MCP server that answers without a socket.
class _FakeGateway implements McpGateway {
  _FakeGateway({List<McpServerTool> tools = const []}) : tools = List.of(tools);

  List<McpServerTool> tools;

  /// Whether the next listing fails the way an unreachable server does.
  bool failListing = false;

  /// Whether a call answers as a tool-level error.
  bool failCall = false;

  /// The calls the app made, as the server saw them.
  final List<(String, Map<String, dynamic>)> calls = [];

  int disposals = 0;

  @override
  Future<List<McpServerTool>> listTools() async {
    if (failListing) throw Exception('connection refused');
    return tools;
  }

  @override
  Future<McpToolAnswer> callTool(
    String name,
    Map<String, dynamic> arguments,
  ) async {
    calls.add((name, arguments));
    // A server that cannot answer a listing cannot answer a call either: the
    // real gateway drops the connection and the next call has to reconnect.
    if (failListing) throw Exception('connection refused');
    if (failCall) return const McpToolAnswer(text: 'no such file', isError: true);
    return McpToolAnswer(text: 'answer from $name');
  }

  @override
  void dispose() => disposals++;
}

/// Tokens in memory: the keychain is a platform channel, and nothing here is
/// about the keychain itself.
class _MemoryTokens implements McpTokenStore {
  final Map<String, String> values = {};

  @override
  Future<String?> read(String serverId) async => values[serverId];

  @override
  Future<void> write(String serverId, String token) async {
    values[serverId] = token.trim();
  }

  @override
  Future<void> clear(String serverId) async => values.remove(serverId);
}

Future<ProviderContainer> _launch({
  required _FakeGateway gateway,
  _MemoryTokens? tokens,
  List<(Uri, String?)>? built,
}) async {
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  final container = ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(preferences),
      mcpTokenStoreProvider.overrideWithValue(tokens ?? _MemoryTokens()),
      mcpGatewayFactoryProvider.overrideWithValue((baseUrl, token) {
        built?.add((baseUrl, token));
        return gateway;
      }),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

/// Adds a server and waits for its listing, as the settings row does.
Future<SnMcpServer> _connect(
  ProviderContainer container, {
  String name = 'Home',
  String url = 'http://127.0.0.1:4317/mcp',
  String? token,
}) async {
  final server = await container
      .read(mcpServersProvider.notifier)
      .add(name: name, url: url, token: token);
  await pumpEventQueue();
  await container.read(mcpCatalogueProvider.notifier).refreshAll();
  return server;
}

/// The plugin one server contributes, as the registry has it.
SnPlugin _plugin(ProviderContainer container, String pluginId) =>
    container.read(pluginRegistryProvider).firstWhere(
      (plugin) => plugin.id == pluginId,
    );

/// The tool the model calls, as the registry currently offers it. Read per
/// call: a catalogue change rebuilds the plugin it came from.
SnLocalTool _toolNamed(ProviderContainer container, String name) => container
    .read(pluginToolsProvider)
    .firstWhere((tool) => tool.name == name);

Future<void> _load(ProviderContainer container, String skillName) async {
  final tool = container
      .read(pluginToolsProvider)
      .firstWhere((tool) => tool.name == loadSkillToolName);
  await tool.execute({'skill': namespacedToolName(skillName)});
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a connected server becomes a plugin whose tools load by name', () async {
    final gateway = _FakeGateway(
      tools: [_tool('read_file'), _tool('list_dir')],
    );
    final container = await _launch(gateway: gateway);
    final server = await _connect(container, name: 'Home');

    final plugin = _plugin(container, 'mcp_home');
    expect(plugin.label, 'Home');
    expect(plugin.skillName, server.id);
    // On demand: a server's tool set is the server's to decide, so its
    // definitions are paid for only once the conversation asks for them.
    expect(plugin.onDemand, isTrue);

    // Nothing is offered, and nothing is advertised, until the user grants it.
    expect(container.read(pluginSkillsProvider), isEmpty);
    await container.read(pluginEnablementProvider.notifier).setEnabled(
      'mcp_home',
      true,
    );
    await pumpEventQueue();

    expect(
      [for (final skill in container.read(pluginSkillsProvider)) skill.name],
      ['home'],
    );
    await _load(container, 'home');
    expect(
      [
        for (final tool in container.read(pluginToolsProvider))
          if (tool.name.startsWith('mcp_home_')) tool.name,
      ],
      ['mcp_home_read_file', 'mcp_home_list_dir'],
    );
  });

  test('two servers keep their own tools apart, in the wire format', () async {
    final gateway = _FakeGateway(
      tools: [
        _tool('search'),
        // A name the server is free to choose and the provider is not.
        _tool('Search:Web!'),
        // The same sanitized name as the one above: the second is dropped
        // rather than made up, so a call is never sent under a name its
        // server never used.
        _tool('search/web'),
        _tool('a' * 80),
      ],
    );
    final container = await _launch(gateway: gateway);
    await _connect(container, name: 'Home');
    final other = _FakeGateway(tools: [_tool('search')]);
    await _connect(container, name: 'Work', url: 'https://mcp.example.com/mcp');

    for (final id in ['mcp_home', 'mcp_work']) {
      final names = [
        for (final (name, _) in (_plugin(container, id) as McpServerPlugin).tools)
          name,
      ];
      expect(names, everyElement(matches(_wireName)), reason: id);
      expect(names.toSet().length, names.length, reason: id);
      expect(names.first, id == 'mcp_home' ? 'mcp_home_search' : 'mcp_work_search');
    }

    final home = _plugin(container, 'mcp_home') as McpServerPlugin;
    expect(
      [for (final (name, _) in home.tools) name],
      ['mcp_home_search', 'mcp_home_search_web', startsWith('mcp_home_aaaa')],
      reason: 'the duplicate and the over-long name are the only casualties',
    );
    expect(other.tools.first.name, 'search');
  });

  test('a call reaches the server under the name the server knows', () async {
    final gateway = _FakeGateway(tools: [_tool('read_file')]);
    final container = await _launch(gateway: gateway);
    await _connect(container);
    await container.read(pluginEnablementProvider.notifier).setEnabled(
      'mcp_home',
      true,
    );
    await _load(container, 'home');

    expect(
      await _toolNamed(container, 'mcp_home_read_file').execute({
        'query': 'notes.md',
      }),
      'answer from read_file',
    );
    // The server's own name and the model's arguments, untouched: namespacing
    // is the app's, dispatching is the server's.
    expect(gateway.calls.single.$1, 'read_file');
    expect(gateway.calls.single.$2, <String, dynamic>{'query': 'notes.md'});
  });

  test('a server that fails answers with text rather than breaking the run', () async {
    final gateway = _FakeGateway(tools: [_tool('read_file')]);
    final container = await _launch(gateway: gateway);
    await _connect(container);
    await container.read(pluginEnablementProvider.notifier).setEnabled(
      'mcp_home',
      true,
    );
    await _load(container, 'home');

    gateway.failCall = true;
    expect(
      await _toolNamed(container, 'mcp_home_read_file').execute({}),
      'Error from "Home": no such file',
    );

    gateway.failCall = false;
    gateway.failListing = true;
    await container.read(mcpCatalogueProvider.notifier).refreshAll();
    final status = container.read(mcpCatalogueProvider)['home']!;
    expect(status.reachable, isFalse);
    expect(status.error, contains('connection refused'));
    // The tools the user granted survive a server that is briefly down: the
    // call is what reports the failure.
    expect(status.tools, hasLength(1));
    expect(
      await _toolNamed(container, 'mcp_home_read_file').execute({}),
      startsWith('Error: the MCP server "Home" did not answer'),
    );
  });

  test('editing a server keeps its switch and re-points its connection', () async {
    final gateway = _FakeGateway(tools: [_tool('read_file')]);
    final tokens = _MemoryTokens();
    final built = <(Uri, String?)>[];
    final container = await _launch(
      gateway: gateway,
      tokens: tokens,
      built: built,
    );
    final server = await _connect(container, token: 'secret');
    expect(built.last, (server.url, 'secret'));
    await container.read(pluginEnablementProvider.notifier).setEnabled(
      'mcp_home',
      true,
    );

    await container
        .read(mcpServersProvider.notifier)
        .update(
          server.id,
          name: 'Home',
          url: 'http://127.0.0.1:5000/mcp',
          // Blank means "keep the stored token".
          token: null,
        );
    await pumpEventQueue();
    await container.read(mcpCatalogueProvider.notifier).refreshAll();

    expect(container.read(mcpServersProvider).single.id, server.id);
    expect(
      container.read(pluginEnablementProvider),
      contains('mcp_home'),
      reason: 'the switch the user flipped outlives the edit',
    );
    expect(built.last, (Uri.parse('http://127.0.0.1:5000/mcp'), 'secret'));
    expect(gateway.disposals, 1, reason: 'the old connection is dropped');
  });

  test('removing a server takes its switch and its token with it', () async {
    final gateway = _FakeGateway(tools: [_tool('read_file')]);
    final tokens = _MemoryTokens();
    final container = await _launch(gateway: gateway, tokens: tokens);
    final server = await _connect(container, token: 'secret');
    await container.read(pluginEnablementProvider.notifier).setEnabled(
      'mcp_home',
      true,
    );
    final preferences = container.read(sharedPreferencesProvider);
    expect(preferences.getBool('persynth_plugin_mcp_home'), isTrue);

    await container.read(mcpServersProvider.notifier).remove(server.id);
    await pumpEventQueue();

    expect(container.read(mcpServersProvider), isEmpty);
    expect(
      container.read(pluginRegistryProvider).map((plugin) => plugin.id),
      isNot(contains('mcp_home')),
    );
    expect(tokens.values, isEmpty);
    expect(preferences.getBool('persynth_plugin_mcp_home'), isNull);
  });

  testWidgets('a server is connected from the Connections section', (
    tester,
  ) async {
    final gateway = _FakeGateway(tools: [_tool('read_file')]);
    final container = await _launch(gateway: gateway);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(body: McpServersSection()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('No MCP servers connected'), findsOneWidget);

    await tester.tap(find.text('Add server'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).at(0), 'Home');
    await tester.enterText(
      find.byType(TextField).at(1),
      'http://127.0.0.1:4317/mcp',
    );
    await tester.tap(find.text('Connect'));
    await tester.pumpAndSettle();

    // The row the user gets back says what the server answered, not just that
    // something was saved.
    expect(container.read(mcpServersProvider).single.name, 'Home');
    expect(find.textContaining('1 tool available'), findsOneWidget);

    await tester.tap(find.byTooltip('Remove'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove').last);
    await tester.pumpAndSettle();
    expect(container.read(mcpServersProvider), isEmpty);
    expect(find.text('No MCP servers connected'), findsOneWidget);
  });

  test('a pasted config becomes servers the companion can call', () async {
    final gateway = _FakeGateway(tools: [_tool('read_file')]);
    final tokens = _MemoryTokens();
    final container = await _launch(gateway: gateway, tokens: tokens);

    final imported = await container
        .read(mcpServersProvider.notifier)
        .importConfig('''
{
  "mcpServers": {
    "home": {
      "url": "http://127.0.0.1:4317/mcp",
      "headers": {"Authorization": "Bearer secret"}
    },
    "filesystem": {"command": "npx", "args": ["-y", "server-filesystem"]}
  }
}
''');
    await pumpEventQueue();
    await container.read(mcpCatalogueProvider.notifier).refreshAll();

    // A pasted server is a configured server: same id, same keychain, and the
    // row behind it reports what the server answered.
    final server = container.read(mcpServersProvider).single;
    expect(server.name, 'home');
    expect(server.url, Uri.parse('http://127.0.0.1:4317/mcp'));
    expect(tokens.values[server.id], 'secret');
    expect(
      container.read(mcpCatalogueProvider)[server.id]!.tools.single.name,
      'read_file',
    );
    expect(imported.skipped.single, contains('filesystem'));

    // The paste is also what the user is left holding: nothing was written for
    // a config the app cannot read at all.
    await expectLater(
      container
          .read(mcpServersProvider.notifier)
          .importConfig('{"mcpServers": {'),
      throwsFormatException,
    );
    expect(container.read(mcpServersProvider), hasLength(1));
  });

  testWidgets('a config is pasted into the Connections section', (
    tester,
  ) async {
    final gateway = _FakeGateway(tools: [_tool('read_file')]);
    final container = await _launch(gateway: gateway);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: McpServersSection())),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Paste JSON config'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(TextField),
      '{"mcpServers": {"home": {"url": "http://127.0.0.1:4317/mcp"}}}',
    );
    await tester.tap(find.text('Import'));
    await tester.pumpAndSettle();

    expect(container.read(mcpServersProvider).single.name, 'home');
    expect(find.text('1 server added.'), findsOneWidget);

    // Importing again cannot add the same servers twice: the field the paste
    // came from is the one the import empties.
    await tester.tap(find.text('Import'));
    await tester.pumpAndSettle();
    expect(container.read(mcpServersProvider), hasLength(1));
  });

  testWidgets('a config the app cannot read is refused in the form', (
    tester,
  ) async {
    final container = await _launch(gateway: _FakeGateway());
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: McpServersSection())),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Paste JSON config'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '{"mcpServers": {"home": {');
    await tester.tap(find.text('Import'));
    await tester.pumpAndSettle();

    expect(container.read(mcpServersProvider), isEmpty);
    expect(find.textContaining('not JSON'), findsOneWidget);
  });

  testWidgets('an endpoint the app cannot use is refused in the form', (
    tester,
  ) async {
    final container = await _launch(gateway: _FakeGateway());
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(body: McpServersSection()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Add server'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).at(0), 'Home');
    await tester.enterText(find.byType(TextField).at(1), '127.0.0.1:4317');
    await tester.tap(find.text('Connect'));
    await tester.pumpAndSettle();

    expect(container.read(mcpServersProvider), isEmpty);
    expect(
      find.textContaining('http:// or https:// endpoint'),
      findsOneWidget,
    );
  });

  test('a server that was never reached is refused in words, not by throwing', () async {
    final server = SnMcpServer(
      id: 'home',
      name: 'Home',
      url: Uri.parse('http://127.0.0.1:4317/mcp'),
    );
    // The state a plugin is built from before its listing answers — the tools
    // of the last list, no connection yet.
    final plugin = McpServerPlugin(
      server: server,
      state: const McpServerState(
        tools: [McpServerTool(name: 'x', description: 'x', inputSchema: {})],
      ),
    );
    final tools = plugin.buildTools(SnPluginContext(api: Dio(), http: Dio()));
    expect([for (final tool in tools) tool.name], ['mcp_home_x']);
    expect(
      await tools.single.execute({}),
      startsWith('Error: the MCP server "Home" has not been reached'),
    );
  });
}
