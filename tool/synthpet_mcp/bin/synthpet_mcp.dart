/// The SynthPet MCP daemon entrypoint.
///
/// Usage: `dart run synthpet_mcp [--port 4317] [--root <directory>]`
///
/// Listens on `127.0.0.1:<port>/mcp` only — never on a routable interface, so
/// the filesystem and shell tools it exposes stay reachable from this machine
/// alone. Relative paths resolve against `--root` (default: the user's home).
library;

import 'dart:async';
import 'dart:io';

import 'package:synthpet_mcp/synthpet_mcp.dart';

/// The value following `--name` in [arguments], or null.
String? _option(List<String> arguments, String name) {
  final index = arguments.indexOf(name);
  if (index < 0 || index + 1 >= arguments.length) return null;
  return arguments[index + 1];
}

Future<void> main(List<String> arguments) async {
  final port = int.tryParse(_option(arguments, '--port') ?? '') ??
      defaultMcpPort;
  final root = _option(arguments, '--root');

  if (port < 1 || port > 65535) {
    stderr.writeln('synthpet_mcp: invalid port $port');
    exitCode = 64; // EX_USAGE
    return;
  }

  try {
    await startDaemon(port: port, root: root);
  } catch (error) {
    stderr.writeln('synthpet_mcp: could not start on 127.0.0.1:$port — $error');
    exitCode = 69; // EX_UNAVAILABLE
    return;
  }

  stdout.writeln(
    'synthpet_mcp listening on http://127.0.0.1:$port/mcp '
    '(relative paths resolve against ${root ?? homeDirectory()})',
  );
  stdout.writeln('Grant this binary Full Disk Access for protected folders.');

  // Run until asked to stop; the HTTP transport keeps serving in the
  // meantime. There is nothing to tear down on exit — the process is the
  // server, and the kernel closes the socket.
  final stopped = Completer<void>();
  ProcessSignal.sigint.watch().listen((_) => stopped.complete());
  ProcessSignal.sigterm.watch().listen((_) => stopped.complete());
  await stopped.future;
}
