/// The SynthPet MCP daemon.
///
/// A standalone Model Context Protocol server that exposes the filesystem and
/// shell tools the companion's agent may call on this machine. It runs as its
/// own process, outside the app's sandbox, and listens on loopback only; the
/// app (sandboxed) is an MCP client to it.
///
/// Relative paths resolve against the directory the daemon was started with —
/// the user's home by default — because a daemon launched from Finder or a
/// terminal has no meaningful working directory, and a model asking for
/// `notes.txt` must land somewhere it can reason about.
library;

import 'dart:io';

import 'package:mcp_server/mcp_server.dart';

import 'src/tools.dart';

export 'src/tools.dart';

/// The port the daemon listens on by default. The app's default MCP URL
/// (`http://127.0.0.1:4317/mcp`) must agree.
const int defaultMcpPort = 4317;

/// The tool set, in the order the model sees them, wired to this daemon's
/// [base] directory.
///
/// Each handler returns the tool's text exactly as the in-process tools used
/// to: `Error: ...` lines included. They are answers for the model to read —
/// a missing file is information, not a tool failure — so results are never
/// flagged `isError`.
void registerTools(Server server, Directory base) {
  server.addTool(
    name: 'read_file',
    description:
        "Read a text file from the user's machine. Relative paths resolve "
        'against their home directory; absolute paths are used as given.\n\n'
        'Returns the file size and line count, then its text. Binary files '
        'are reported rather than dumped. Large files are truncated to '
        '`max_chars`.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'path': {
          'type': 'string',
          'description':
              'File to read: absolute, or relative to the home directory.',
        },
        'max_chars': {
          'type': 'integer',
          'minimum': 500,
          'maximum': 200000,
          'description': 'Output character cap (500-200000, default 20000).',
        },
      },
      'required': ['path'],
    },
    handler: (arguments) async =>
        CallToolResult(content: [TextContent(text: await readFile(base, arguments))]),
  );

  server.addTool(
    name: 'list_dir',
    description:
        "List a directory on the user's machine: one entry per line, "
        'directories marked with a trailing slash, with size and last '
        'modified time. Relative paths resolve against their home directory.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'path': {
          'type': 'string',
          'description':
              'Directory to list; defaults to the home directory. Absolute, '
              'or relative to the home directory.',
        },
      },
    },
    handler: (arguments) async =>
        CallToolResult(content: [TextContent(text: await listDir(base, arguments))]),
  );

  server.addTool(
    name: 'run_command',
    description:
        "Run a shell command on the user's machine and return its output.\n\n"
        'The command runs through the platform shell ("/bin/sh -c", '
        '"cmd /c" on Windows) with the home directory as its working '
        'directory unless `cwd` says otherwise. stdout and stderr are both '
        'captured, along with the exit code; a command that outruns '
        '`timeout_seconds` is killed. Destructive commands run with all the '
        "user's own authority — check with them before anything that "
        'deletes, overwrites, or installs.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'command': {
          'type': 'string',
          'description': 'Command line to run, exactly as a shell would see it.',
        },
        'cwd': {
          'type': 'string',
          'description':
              'Working directory; defaults to the home directory. Absolute, '
              'or relative to the home directory.',
        },
        'timeout_seconds': {
          'type': 'integer',
          'minimum': 1,
          'maximum': 120,
          'description': 'Kill the command after this long (1-120, default 30).',
        },
        'max_chars': {
          'type': 'integer',
          'minimum': 500,
          'maximum': 200000,
          'description': 'Output character cap (500-200000, default 20000).',
        },
      },
      'required': ['command'],
    },
    handler: (arguments) async =>
        CallToolResult(content: [TextContent(text: await runCommand(base, arguments))]),
  );
}

/// Starts the daemon: an MCP server over Streamable HTTP on loopback.
///
/// The HTTP transport answers each request with a single JSON document
/// (JSON response mode) — this daemon's calls are request/response, so the
/// SSE streaming mode buys nothing and costs a connection to keep open.
Future<Server> startDaemon({required int port, String? root}) async {
  final result = await McpServer.createAndStart(
    config: McpServerConfig(
      name: 'synthpet_mcp',
      version: '1.0.0',
      capabilities: ServerCapabilities.simple(tools: true),
    ),
    transportConfig: TransportConfig.streamableHttp(
      host: '127.0.0.1',
      port: port,
      endpoint: '/mcp',
      isJsonResponseEnabled: true,
    ),
  );

  final server = result.fold(
    (server) => server,
    (error) => throw error,
  );
  registerTools(server, directoryOf(root ?? homeDirectory()));
  return server;
}
