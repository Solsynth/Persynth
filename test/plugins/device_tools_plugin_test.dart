import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:persynth/personality/local_tool.dart';
import 'package:persynth/personality/mcp_client.dart';
import 'package:persynth/plugins/device_tools_plugin.dart';
import 'package:persynth/plugins/plugin.dart';

/// A gateway that answers without a server, recording the calls it forwards.
class _FakeGateway implements McpGateway {
  _FakeGateway({this.failCalls = false, this.failList = false});

  /// Calls in wire order: tool name → arguments as received.
  final calls = <(String, Map<String, dynamic>)>[];

  /// When set, `callTool` throws (the daemon is unreachable).
  final bool failCalls;

  /// When set, `listTools` throws.
  final bool failList;

  @override
  Future<List<McpDaemonTool>> listTools() async {
    if (failList) throw Exception('connection refused');
    return const [
      McpDaemonTool(
        name: 'read_file',
        description: 'd',
        inputSchema: {'type': 'object'},
      ),
    ];
  }

  @override
  Future<String> callTool(String name, Map<String, dynamic> arguments) async {
    if (failCalls) throw Exception('connection refused');
    calls.add((name, Map<String, dynamic>.from(arguments)));
    return 'result of $name';
  }

  @override
  void dispose() {}
}

/// The tools the device plugin offers when it is loaded, built through the
/// context a plugin is handed.
List<SnLocalTool> _tools(ProviderContainer container) => const DeviceToolsPlugin()
    .buildTools(
      SnPluginContext(
        api: Dio(),
        http: Dio(),
        mcp: container.read(mcpGatewayProvider),
      ),
    );

void main() {
  test('offers the three device tools, in order, under plain names', () {
    final container = ProviderContainer(
      overrides: [mcpGatewayProvider.overrideWithValue(_FakeGateway())],
    );
    addTearDown(container.dispose);

    expect(
      _tools(container).map((tool) => tool.name).toList(),
      ['read_file', 'list_dir', 'run_command'],
    );
  });

  test('forwards each call to the daemon under the daemon\'s own name', () async {
    final gateway = _FakeGateway();
    final container = ProviderContainer(
      overrides: [mcpGatewayProvider.overrideWithValue(gateway)],
    );
    addTearDown(container.dispose);

    final tools = {for (final tool in _tools(container)) tool.name: tool};

    expect(
      await tools['read_file']!.execute({'path': 'x', 'max_chars': 500}),
      'result of read_file',
    );
    expect(
      await tools['list_dir']!.execute({'path': 'y'}),
      'result of list_dir',
    );
    expect(
      await tools['run_command']!.execute({'command': 'ls'}),
      'result of run_command',
    );

    expect(gateway.calls.map((call) => call.$1).toList(), [
      'read_file',
      'list_dir',
      'run_command',
    ]);
    expect(gateway.calls[0].$2, {'path': 'x', 'max_chars': 500});
    expect(gateway.calls[1].$2, {'path': 'y'});
    expect(gateway.calls[2].$2, {'command': 'ls'});
  });

  test('an unreachable daemon answers with an error text, not a throw', () async {
    final container = ProviderContainer(
      overrides: [
        mcpGatewayProvider.overrideWithValue(_FakeGateway(failCalls: true)),
      ],
    );
    addTearDown(container.dispose);

    final tool = _tools(container).first;

    expect(
      await tool.execute({'path': 'x'}),
      startsWith('Error: the Persynth MCP daemon is not running'),
    );
  });

  test('the status reports reachability and the daemon\'s tool count', () async {
    final container = ProviderContainer(
      overrides: [mcpGatewayProvider.overrideWithValue(_FakeGateway())],
    );
    addTearDown(container.dispose);

    final status = await container.read(mcpDaemonStatusProvider.future);
    expect(status.reachable, isTrue);
    expect(status.toolCount, 1);
  });

  test('the status reports unreachable when listing fails', () async {
    final container = ProviderContainer(
      overrides: [mcpGatewayProvider.overrideWithValue(_FakeGateway(failList: true))],
    );
    addTearDown(container.dispose);

    final status = await container.read(mcpDaemonStatusProvider.future);
    expect(status.reachable, isFalse);
    expect(status.toolCount, 0);
  });
}
