/// The device tool set, MCP-backed.
///
/// These used to run in-process (`read_file_local`, `list_dir_local`,
/// `run_command_local`), which is why the app could not be sandboxed: they
/// read the user's files and run shell commands inside the app. They now run
/// in the Persynth MCP daemon, a separate process, and each call here is a
/// `tools/call` over the wire. The `mcp_` prefix tells the model a call is
/// leaving the machine through the daemon, and keeps the names clear of the
/// server-owned tools.
///
/// The descriptors are static, mirroring the daemon's `tools/list`, because
/// the app owns the daemon: the model sees the tools the moment the switch
/// flips, before (or without) a round trip, and a call that finds the daemon
/// down answers with a plain error instead of failing the run.
library;

import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:synth_pet/personality/local_tool.dart';
import 'package:synth_pet/personality/mcp_client.dart';

/// The prefix on every tool name that forwards to the daemon. The daemon's
/// wire name is the prefix stripped.
const kMcpToolPrefix = 'mcp_';

/// The device tools, in the order the model sees them, all forwarding to the
/// daemon through [McpGateway].
final mcpDeviceToolsProvider = Provider<List<SnLocalTool>>((ref) {
  final gateway = ref.watch(mcpGatewayProvider);
  return [
    SnLocalTool(
      name: '${kMcpToolPrefix}read_file',
      description:
          "Read a text file from the user's machine. Relative paths resolve "
          'against their home directory; absolute paths are used as given.\n\n'
          'Returns the file size and line count, then its text. Binary files '
          'are reported rather than dumped. Large files are truncated to '
          '`max_chars`.',
      parameters: const <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'path': <String, dynamic>{
            'type': 'string',
            'description':
                'File to read: absolute, or relative to the home directory.',
          },
          'max_chars': <String, dynamic>{
            'type': 'integer',
            'minimum': 500,
            'maximum': 200000,
            'description': 'Output character cap (500-200000, default 20000).',
          },
        },
        'required': <String>['path'],
      },
      execute: (arguments) => _forward(gateway, 'read_file', arguments),
    ),
    SnLocalTool(
      name: '${kMcpToolPrefix}list_dir',
      description:
          "List a directory on the user's machine: one entry per line, "
          'directories marked with a trailing slash, with size and last '
          'modified time. Relative paths resolve against their home directory.',
      parameters: const <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'path': <String, dynamic>{
            'type': 'string',
            'description':
                'Directory to list; defaults to the home directory. Absolute, '
                'or relative to the home directory.',
          },
        },
      },
      execute: (arguments) => _forward(gateway, 'list_dir', arguments),
    ),
    SnLocalTool(
      name: '${kMcpToolPrefix}run_command',
      description:
          "Run a shell command on the user's machine and return its output.\n\n"
          'The command runs through the platform shell ("/bin/sh -c", '
          '"cmd /c" on Windows) with the home directory as its working '
          'directory unless `cwd` says otherwise. stdout and stderr are both '
          'captured, along with the exit code; a command that outruns '
          '`timeout_seconds` is killed. Destructive commands run with all the '
          "user's own authority — check with them before anything that "
          'deletes, overwrites, or installs.',
      parameters: const <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'command': <String, dynamic>{
            'type': 'string',
            'description': 'Command line to run, exactly as a shell would see it.',
          },
          'cwd': <String, dynamic>{
            'type': 'string',
            'description':
                'Working directory; defaults to the home directory. Absolute, '
                'or relative to the home directory.',
          },
          'timeout_seconds': <String, dynamic>{
            'type': 'integer',
            'minimum': 1,
            'maximum': 120,
            'description': 'Kill the command after this long (1-120, default 30).',
          },
          'max_chars': <String, dynamic>{
            'type': 'integer',
            'minimum': 500,
            'maximum': 200000,
            'description': 'Output character cap (500-200000, default 20000).',
          },
        },
        'required': <String>['command'],
      },
      execute: (arguments) => _forward(gateway, 'run_command', arguments),
    ),
  ];
});

/// Runs [tool] on the daemon, turning an unreachable daemon into the same
/// kind of text answer the tools themselves produce — a missing process is an
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
