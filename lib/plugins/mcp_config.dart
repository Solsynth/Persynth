/// What an MCP server's configuration is, in this app and in the clients the
/// user already configures.
///
/// Every MCP client describes a server the same way and writes it down in its
/// own file. The format has settled around one shape — an object of server
/// name → definition, under `mcpServers` (Claude Desktop, Cursor, Windsurf,
/// `.mcp.json`), `servers` (VS Code, and the editors that follow it) or
/// `context_servers` (Zed) — so a configuration the user already has is
/// something this app can read rather than something they retype, token
/// included.
///
/// What is read is only what this app can act on. A definition with a `url` is
/// an endpoint it connects to; a definition with a `command` is a stdio
/// server, which this app does not launch (see `mcp_client.dart` for why), and
/// is reported instead of being added as a row that could never answer. Keys
/// this file does not know are ignored, which is what keeps a config written
/// for a newer client readable here.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';

/// The keys an MCP client puts its server list under, in the order they are
/// looked for. A root holding none of them is read as the list itself, so a
/// user who pasted only the inner object still gets their servers.
const List<String> _kServerListKeys = [
  'mcpServers',
  'servers',
  'context_servers',
];

/// The http:// or https:// endpoint [url] names, or null for anything this app
/// cannot connect to.
///
/// One rule, in one place: a server is reached over Streamable HTTP, so a
/// scheme that is not http(s), a URL without a host and a string that is not a
/// URL at all are the same answer.
Uri? mcpEndpoint(String url) {
  final uri = Uri.tryParse(url.trim());
  if (uri == null ||
      !uri.hasScheme ||
      (uri.scheme != 'http' && uri.scheme != 'https') ||
      uri.host.isEmpty) {
    return null;
  }
  return uri;
}

/// One server read out of a pasted configuration file.
@immutable
class McpConfigServer {
  const McpConfigServer({
    required this.name,
    required this.url,
    this.token,
    this.note,
  });

  /// What the file calls the server.
  final String name;

  /// The endpoint it points at.
  final Uri url;

  /// The bearer token the file carries for this server, or null when it
  /// carries none.
  final String? token;

  /// What the file said that this app does not carry over, or null when
  /// everything it said was read: headers other than the authorization one,
  /// and a transport this app does not speak.
  final String? note;
}

/// What one pasted configuration file adds up to.
@immutable
class McpConfigImport {
  const McpConfigImport({this.servers = const [], this.skipped = const []});

  /// The servers the file names that this app can connect to, in file order.
  final List<McpConfigServer> servers;

  /// One line per server the file names that this app is not importing, saying
  /// which one and why — the user is told what was left behind rather than
  /// finding it missing later.
  final List<String> skipped;
}

/// Reads MCP configuration JSON into the servers this app connects to.
///
/// Throws a [FormatException] whose message is what the user needs to read —
/// it is shown in the paste form — when the text is not a JSON object, or is
/// one that names no servers at all. Anything past that is per-entry: one
/// server this app cannot use does not stop the others from being read.
McpConfigImport readMcpConfig(String text) {
  Object? decoded;
  try {
    decoded = jsonDecode(text);
  } catch (_) {
    throw const FormatException(
      'That is not JSON. Paste what the other app\'s configuration file holds.',
    );
  }
  if (decoded is! Map) {
    throw const FormatException(
      'That JSON is not an object of servers. Paste the configuration file, '
      'or its `mcpServers` object.',
    );
  }

  var list = decoded;
  for (final key in _kServerListKeys) {
    if (!decoded.containsKey(key)) continue;
    final value = decoded[key];
    if (value is! Map) {
      throw FormatException(
        'The `$key` value in that JSON is not an object of servers.',
      );
    }
    list = value;
    break;
  }
  if (list.isEmpty) {
    throw const FormatException('That JSON names no MCP servers.');
  }

  final servers = <McpConfigServer>[];
  final skipped = <String>[];
  for (final entry in list.entries) {
    final name = entry.key.toString().trim();
    final label = name.isEmpty ? 'An unnamed entry' : name;
    final definition = entry.value;
    if (definition is! Map) {
      skipped.add('$label is not a server definition.');
      continue;
    }

    final url = definition['url']?.toString().trim() ?? '';
    if (url.isEmpty) {
      final command = definition['command']?.toString().trim() ?? '';
      skipped.add(
        command.isEmpty
            ? '$label names no url.'
            : '$label runs the local command `$command`, and this app reaches '
                  'servers over HTTP only. Start it with an HTTP endpoint and '
                  'add that.',
      );
      continue;
    }
    final endpoint = mcpEndpoint(url);
    if (endpoint == null) {
      skipped.add(
        '$label points at $url, which is not an http:// or https:// endpoint.',
      );
      continue;
    }

    final headers = definition['headers'];
    String? token;
    final dropped = <String>[];
    if (headers is Map) {
      for (final header in headers.entries) {
        final key = header.key.toString().trim();
        final value = header.value?.toString().trim() ?? '';
        if (value.isEmpty) continue;
        if (key.toLowerCase() == 'authorization') {
          token = _bearerToken(value);
        } else {
          dropped.add(key);
        }
      }
    }

    final transport = (definition['type'] ?? definition['transport'])
        ?.toString()
        .trim()
        .toLowerCase();
    final notes = [
      if (dropped.isNotEmpty)
        'Headers ${dropped.join(', ')} are not carried over; only the bearer '
            'token is.',
      if (transport == 'sse')
        'It is declared as an SSE server, and this app speaks Streamable HTTP.',
    ];

    servers.add(
      McpConfigServer(
        name: name.isEmpty ? endpoint.host : name,
        url: endpoint,
        token: token,
        note: notes.isEmpty ? null : notes.join(' '),
      ),
    );
  }
  return McpConfigImport(servers: servers, skipped: skipped);
}

/// The credential in an `Authorization` header, without its scheme.
String _bearerToken(String value) {
  final lowercase = value.toLowerCase();
  return lowercase.startsWith('bearer ') ? value.substring(7).trim() : value;
}
