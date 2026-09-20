import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:synth_pet/personality/local_tool.dart';
import 'package:synth_pet/personality/mcp_client.dart';
import 'package:synth_pet/personality/mcp_device_tools.dart';

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

List<SnLocalTool> _tools(ProviderContainer container) =>
    container.read(mcpDeviceToolsProvider);

void main() {
  test('offers the three device tools, mcp_-prefixed, in order', () {
    final container = ProviderContainer(
      overrides: [mcpGatewayProvider.overrideWithValue(_FakeGateway())],
    );
    addTearDown(container.dispose);

    expect(
      _tools(container).map((tool) => tool.name).toList(),
      ['mcp_read_file', 'mcp_list_dir', 'mcp_run_command'],
    );
  });

  test('forwards each call to the daemon with the prefix stripped', () async {
    final gateway = _FakeGateway();
    final container = ProviderContainer(
      overrides: [mcpGatewayProvider.overrideWithValue(gateway)],
    );
    addTearDown(container.dispose);

    final tools = {for (final tool in _tools(container)) tool.name: tool};

    expect(
      await tools['mcp_read_file']!.execute({'path': 'x', 'max_chars': 500}),
      'result of read_file',
    );
    expect(
      await tools['mcp_list_dir']!.execute({'path': 'y'}),
      'result of list_dir',
    );
    expect(
      await tools['mcp_run_command']!.execute({'command': 'ls'}),
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
      startsWith('Error: the SynthPet MCP daemon is not running'),
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
