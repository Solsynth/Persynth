/// The app's MCP client: it talks to the Persynth MCP daemon, a separate
/// process that holds the filesystem and shell tools the companion may call.
///
/// The daemon exists because the app is sandboxed again: a child process of a
/// sandboxed app inherits the sandbox, so the file access had to move out of
/// the app entirely. The app is now a plain MCP client over Streamable HTTP
/// to a loopback-only daemon the user runs (`tool/synthpet_mcp`).
library;

import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:mcp_client/mcp_client.dart';

/// The daemon's default URL; override with
/// `--dart-define=SYNTHPET_MCP_URL=http://127.0.0.1:PORT/mcp`.
const kMcpDaemonDefaultUrl = 'http://127.0.0.1:4317/mcp';

/// The daemon URL the app connects to.
final mcpDaemonUrlProvider = Provider<Uri>(
  (ref) => Uri.parse(
    const String.fromEnvironment(
      'SYNTHPET_MCP_URL',
      defaultValue: kMcpDaemonDefaultUrl,
    ),
  ),
);

/// One tool the daemon advertises (`tools/list`).
@immutable
class McpDaemonTool {
  const McpDaemonTool({
    required this.name,
    required this.description,
    required this.inputSchema,
  });

  /// The wire name the daemon dispatches on, e.g. `read_file`.
  final String name;

  /// Prose the model reads when deciding whether to call this tool.
  final String description;

  /// JSON Schema of the arguments object.
  final Map<String, dynamic> inputSchema;
}

/// What the app's MCP client needs from the daemon, abstract so tests can
/// fake it without a server running.
abstract class McpGateway {
  /// The tools the daemon exposes, or throws when it is unreachable.
  Future<List<McpDaemonTool>> listTools();

  /// Runs one tool on the daemon and returns its text, or throws when the
  /// daemon is unreachable or the call fails at the transport level.
  Future<String> callTool(String name, Map<String, dynamic> arguments);

  /// Releases the connection, if any.
  void dispose();
}

/// Whether the daemon answered, and with how many tools, for the settings row.
@immutable
class McpDaemonStatus {
  const McpDaemonStatus({required this.reachable, this.toolCount = 0});

  final bool reachable;
  final int toolCount;
}

/// The real gateway: an MCP client over Streamable HTTP to [baseUrl].
class HttpMcpGateway implements McpGateway {
  HttpMcpGateway({
    required this.baseUrl,
    this.connectTimeout = const Duration(seconds: 5),
  });

  final Uri baseUrl;

  /// How long connecting may take before the daemon counts as unreachable.
  /// A dead daemon must not hang a tool call for the client's full
  /// request-timeout, which would stall the conversation.
  final Duration connectTimeout;

  Client? _client;
  Future<Client>? _connecting;

  Future<Client> _ensureClient() {
    final existing = _client;
    if (existing != null && existing.isConnected) {
      return Future.value(existing);
    }
    return _connecting ??= _connect().then((client) {
      _client = client;
      _connecting = null;
      return client;
    }).catchError((Object error, StackTrace stack) {
      _connecting = null;
      throw error;
    });
  }

  Future<Client> _connect() async {
    final result = await McpClient.createAndConnect(
      // One attempt, no retry storm: the daemon is a local process that is
      // either up or not, and a dead one must fail a call in connectTimeout,
      // not hang it behind five back-off retries. The next call reconnects.
      config: McpClientConfig(
        name: 'persynth',
        version: '1.0.0',
        maxRetries: 1,
        requestTimeout: connectTimeout,
      ),
      transportConfig: TransportConfig.streamableHttp(
        baseUrl: baseUrl.toString(),
        timeout: connectTimeout,
      ),
    );
    return result.fold(
      (client) => client,
      (error) => throw error,
    );
  }

  /// Drops a connection that outlived its daemon, so the next call reconnects.
  void _drop() {
    _client?.disconnect();
    _client = null;
  }

  @override
  Future<List<McpDaemonTool>> listTools() async {
    final client = await _ensureClient();
    final tools = await client.listTools();
    return [
      for (final tool in tools)
        McpDaemonTool(
          name: tool.name,
          description: tool.description,
          inputSchema: tool.inputSchema,
        ),
    ];
  }

  @override
  Future<String> callTool(
    String name,
    Map<String, dynamic> arguments,
  ) async {
    final client = await _ensureClient();
    try {
      final result = await client.callTool(name, arguments);
      return result.content
          .whereType<TextContent>()
          .map((content) => content.text)
          .join('\n');
    } on Exception {
      // The daemon may have restarted mid-conversation; a stale connection
      // would fail every call after it. Drop it and let the next call
      // reconnect. The call itself is NOT retried: a command tool must not
      // run twice because the socket hiccuped.
      _drop();
      rethrow;
    }
  }

  @override
  void dispose() => _drop();
}

/// The gateway the app talks through; override in tests with a fake.
final mcpGatewayProvider = Provider<McpGateway>((ref) {
  final gateway = HttpMcpGateway(baseUrl: ref.watch(mcpDaemonUrlProvider));
  ref.onDispose(gateway.dispose);
  return gateway;
});

/// Whether the daemon answers, for the settings row. Invalidate to re-probe
/// after the user has started the daemon.
final mcpDaemonStatusProvider = FutureProvider<McpDaemonStatus>((ref) async {
  final gateway = ref.watch(mcpGatewayProvider);
  try {
    final tools = await gateway.listTools();
    return McpDaemonStatus(reachable: true, toolCount: tools.length);
  } catch (_) {
    // Unreachable is a status, not an error: the row says so and tells the
    // user how to start the daemon.
    return const McpDaemonStatus(reachable: false);
  }
});
