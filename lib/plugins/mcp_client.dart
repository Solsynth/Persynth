/// The MCP client: how the app reaches a Model Context Protocol server the
/// user connected.
///
/// The companion's own capabilities are compiled in, but a user's MCP servers
/// are theirs: the app lists what a server advertises (`tools/list`), offers
/// the answers as client tools on the run, and forwards the model's calls back
/// to the server they came from (`tools/call`). This file is that wire and
/// nothing else — which servers exist, whether their tools are offered and
/// what the model is told about them belong to the registry, not here.
///
/// Streamable HTTP only. The spec's other transport, stdio, spawns a child
/// process, and a child of a sandboxed app inherits the sandbox: that is
/// exactly why the app's file tools live in a separate daemon rather than in
/// here. A stdio-only server can be run by the user and reached over HTTP
/// (its own process, outside this app's sandbox).
///
/// Nothing here throws at a plugin: an unreachable server, a refused call and
/// a server that answers with an error are all answers about the user's own
/// machine, not defects of the run. [McpGateway] still throws at the transport
/// level — the caller decides what text the model reads.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:mcp_client/mcp_client.dart' as mcp;

/// How long one request to a server may take before the server counts as
/// unresponsive.
///
/// One ceiling for connecting and for calling: a socket-level failure (refused
/// connection, no such host) fails immediately regardless, while a real tool —
/// a query, a scan — may legitimately take seconds, so a short cap here would
/// break calls that were working. A server that accepts the connection and
/// never answers costs the run this long at most.
const Duration kMcpRequestTimeout = Duration(seconds: 30);

/// One tool an MCP server advertises (`tools/list`).
@immutable
class McpServerTool {
  const McpServerTool({
    required this.name,
    required this.description,
    required this.inputSchema,
  });

  /// The wire name the server dispatches on, e.g. `read_file`.
  final String name;

  /// Prose the model reads when deciding whether to call this tool.
  final String description;

  /// JSON Schema of the arguments object.
  final Map<String, dynamic> inputSchema;
}

/// What one `tools/call` answered.
///
/// [isError] is the server's own report that the tool failed — a value the
/// model should see as a failed call, not as a result. It is not a transport
/// failure: that throws.
@immutable
class McpToolAnswer {
  const McpToolAnswer({required this.text, this.isError = false});

  /// The answer text, content parts flattened.
  final String text;

  /// Whether the server marked the result as an error.
  final bool isError;
}

/// What the app needs from one MCP server, abstract so tests can fake it
/// without a server running.
abstract class McpGateway {
  /// The tools the server advertises, or throws when it is unreachable or
  /// does not support tools.
  Future<List<McpServerTool>> listTools();

  /// Runs one tool on the server, or throws when the call fails at the
  /// transport level.
  Future<McpToolAnswer> callTool(
    String name,
    Map<String, dynamic> arguments,
  );

  /// Releases the connection, if any.
  void dispose();
}

/// Builds the gateway for one configured server.
///
/// A function rather than a class so the transport can be replaced wholesale
/// in a test, and so nothing above this file holds a concrete client.
typedef McpGatewayFactory = McpGateway Function(Uri baseUrl, String? token);

/// The real gateway: an MCP client over Streamable HTTP to [baseUrl].
class HttpMcpGateway implements McpGateway {
  HttpMcpGateway({
    required this.baseUrl,
    String? token,
    this.requestTimeout = kMcpRequestTimeout,
  }) : _headers = {
         if (token != null && token.trim().isNotEmpty)
           'Authorization': 'Bearer ${token.trim()}',
       };

  final Uri baseUrl;

  /// How long one request to this server may take.
  final Duration requestTimeout;

  /// Headers every request to this server carries. The token, when there is
  /// one, never leaves this map: it is not logged and not sent anywhere else.
  final Map<String, String> _headers;

  mcp.Client? _client;
  Future<mcp.Client>? _connecting;

  Future<mcp.Client> _ensureClient() {
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

  Future<mcp.Client> _connect() async {
    final result = await mcp.McpClient.createAndConnect(
      // One attempt, no retry storm: a server the user connected is either
      // answering or not, and a dead one must fail a probe or a call in
      // [requestTimeout], not hang it behind five back-off retries. The next
      // call reconnects.
      config: mcp.McpClientConfig(
        name: 'persynth',
        version: '1.0.0',
        maxRetries: 1,
        requestTimeout: requestTimeout,
      ),
      transportConfig: mcp.TransportConfig.streamableHttp(
        baseUrl: baseUrl.toString(),
        headers: _headers,
        timeout: requestTimeout,
      ),
    );
    return result.fold((client) => client, (error) => throw error);
  }

  /// Drops a connection that outlived its server, so the next call
  /// reconnects.
  void _drop() {
    _client?.disconnect();
    _client = null;
  }

  @override
  Future<List<McpServerTool>> listTools() async {
    final client = await _ensureClient();
    try {
      final tools = await client.listTools();
      return [
        for (final tool in tools)
          McpServerTool(
            name: tool.name,
            description: tool.description,
            inputSchema: tool.inputSchema,
          ),
      ];
    } on Exception {
      // A server that fails the listing may still be reachable for calls
      // (a listing timeout, a restart mid-request); drop the connection so
      // the next attempt starts clean rather than reusing a half-dead one.
      _drop();
      rethrow;
    }
  }

  @override
  Future<McpToolAnswer> callTool(
    String name,
    Map<String, dynamic> arguments,
  ) async {
    final client = await _ensureClient();
    try {
      final result = await client.callTool(name, arguments);
      return McpToolAnswer(
        text: _textOf(result),
        isError: result.isError == true,
      );
    } on Exception {
      // The server may have restarted mid-conversation; a stale connection
      // would fail every call after it. Drop it and let the next call
      // reconnect. The call itself is NOT retried: a tool that writes must
      // not run twice because the socket hiccuped.
      _drop();
      rethrow;
    }
  }

  @override
  void dispose() => _drop();
}

/// The answer text handed to the model: the server's text parts, with a
/// one-line marker standing in for any part that is not text — an image, a
/// resource link, a binary blob — so a result that is mostly not text still
/// says what it was instead of arriving empty.
String _textOf(mcp.CallToolResult result) {
  final parts = <String>[];
  for (final content in result.content) {
    if (content is mcp.TextContent) {
      parts.add(content.text);
    } else {
      parts.add('[${content.toJson()['type'] ?? 'content'}]');
    }
  }
  if (parts.isEmpty) {
    final structured = result.structuredContent;
    if (structured != null) return jsonEncode(structured);
  }
  return parts.join('\n');
}
