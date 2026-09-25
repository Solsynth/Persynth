/// The device tool set — files and shell, through the MCP daemon — as a
/// plugin.
///
/// On demand rather than eager: three tool definitions with long descriptions,
/// for calls the companion makes occasionally. Offering them on every request
/// would spend context on tools most turns never touch, so the model loads
/// them by name when a question actually calls for the user's machine.
///
/// Off by default and honest about it: these read the user's files and run
/// shell commands as the user, so the switch is a real grant and the model is
/// told the outputs are the user's own machine rather than a server sandbox.
library;

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';

import 'package:persynth/personality/local_tool.dart';
import 'package:persynth/personality/mcp_client.dart';
import 'package:persynth/plugins/plugin.dart';

/// The key this switch is persisted under. It predates the plugin registry;
/// keeping the name keeps the choice of every user who already made it.
const String kLocalDeviceToolsStoreKey = 'persynth_local_tools_device';

class DeviceToolsPlugin extends SnPlugin {
  const DeviceToolsPlugin();

  @override
  String get id => 'device';

  @override
  String get storeKey => kLocalDeviceToolsStoreKey;

  @override
  String get label => 'Files & commands';

  @override
  String get description =>
      'Lets the companion read this machine\'s files and run shell commands '
      'through the Persynth MCP daemon. Relative paths resolve against your '
      'home directory. Anything your account can do, it can do too.';

  @override
  String get summary =>
      'Read the user\'s files and run shell commands on their own machine';

  @override
  bool get onDemand => true;

  @override
  List<SnLocalTool> buildTools(SnPluginContext context) {
    final gateway = context.mcp;
    return [
      SnLocalTool(
        name: 'read_file',
        description:
            "Read a text file from the user's machine. Relative paths resolve "
            'against their home directory. Returns the content, optionally '
            'from an offset and capped at `max_chars`.',
        parameters: const <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{
            'path': <String, dynamic>{
              'type': 'string',
              'description': 'File path to read.',
            },
            'offset': <String, dynamic>{
              'type': 'integer',
              'minimum': 0,
              'description': 'Line number to start reading from (0-based).',
            },
            'max_chars': <String, dynamic>{
              'type': 'integer',
              'minimum': 1,
              'description': 'Maximum number of characters to return.',
            },
          },
          'required': <String>['path'],
        },
        execute: (arguments) => _forward(gateway, 'read_file', arguments),
      ),
      SnLocalTool(
        name: 'list_dir',
        description:
            "List a directory on the user's machine: one entry per line, "
            'directories marked with a trailing slash, with size and last '
            'modified time. Relative paths resolve against their home '
            'directory.',
        parameters: const <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{
            'path': <String, dynamic>{
              'type': 'string',
              'description': 'Directory path to list.',
            },
          },
          'required': <String>['path'],
        },
        execute: (arguments) => _forward(gateway, 'list_dir', arguments),
      ),
      SnLocalTool(
        name: 'run_command',
        description:
            "Run a shell command on the user's machine and return its output. "
            'The command runs as the user, with their environment and their '
            'working directory. Say what it will do before running anything '
            'that deletes, overwrites, or installs.',
        parameters: const <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{
            'command': <String, dynamic>{
              'type': 'string',
              'description': 'Shell command to run.',
            },
            'cwd': <String, dynamic>{
              'type': 'string',
              'description':
                  'Working directory. Defaults to the home directory.',
            },
            'timeout_ms': <String, dynamic>{
              'type': 'integer',
              'minimum': 1,
              'description': 'How long to let the command run, in ms.',
            },
          },
          'required': <String>['command'],
        },
        execute: (arguments) => _forward(gateway, 'run_command', arguments),
      ),
    ];
  }

  @override
  List<String> systemPrompt(SnPluginContext context) => const [
    'Device tools that run on the user\'s own machine are loaded: '
    'local_read_file, local_list_dir and local_run_command go through the Persynth '
    'MCP daemon, not a server sandbox. What they return is the user\'s real '
    'machine, and paths are theirs, not the server\'s. Describe a command '
    'before running anything that deletes, overwrites, or installs.',
  ];

  @override
  List<Widget> settingsRows(WidgetRef ref) => const [McpDaemonRow()];
}

/// Runs [tool] on the daemon, turning an unreachable daemon into the same kind
/// of text answer the tools themselves produce — a missing process is an
/// answer about the machine, not a defect of the run.
Future<String> _forward(
  McpGateway gateway,
  String tool,
  Map<String, dynamic> arguments,
) async {
  try {
    return await gateway.callTool(tool, arguments);
  } catch (error) {
    return 'Error: the Persynth MCP daemon is not running ($error). '
        'Start it (tool/synthpet_mcp: `dart run synthpet_mcp`) and try again.';
  }
}

/// Where the device tools actually run: the MCP daemon is a separate process
/// because the app is sandboxed, so its reachability is the device set's
/// lifeline. The row reports it and says how to start it; re-checking
/// re-probes.
class McpDaemonRow extends ConsumerWidget {
  const McpDaemonRow({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final status = ref.watch(mcpDaemonStatusProvider);
    final url = ref.watch(mcpDaemonUrlProvider);

    final running = status.value?.reachable == true;
    return ListTile(
      leading: Icon(
        running ? Symbols.dns_rounded : Symbols.link_off_rounded,
        color: running
            ? theme.colorScheme.primary
            : theme.colorScheme.onSurfaceVariant,
      ),
      title: const Text('MCP daemon'),
      subtitle: Text(
        switch (status.value) {
          McpDaemonStatus(reachable: true, toolCount: final count) =>
            'Running on $url with $count tool${count == 1 ? '' : 's'} '
                'available.',
          McpDaemonStatus(reachable: false) =>
            'Not running. Start it from tool/synthpet_mcp '
                '(`dart run synthpet_mcp`) for Files & commands to work.',
          null => 'Checking whether the daemon is running…',
        },
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
      trailing: TextButton(
        onPressed: () => ref.invalidate(mcpDaemonStatusProvider),
        child: const Text('Check again'),
      ),
    );
  }
}
