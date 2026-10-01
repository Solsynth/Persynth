/// The MCP servers the user connected, and what each one last answered.
///
/// A server here is configuration, not capability: the user points the app at
/// a Model Context Protocol server (their own, on this machine or anywhere the
/// network reaches), names it, and optionally gives it an access token. The
/// registry then offers that server as a plugin — one switch in settings, its
/// tools loadable by name — and this file owns the things the plugin reads:
/// which servers exist, what each one's `tools/list` last returned, and the
/// live connection a call goes through.
///
/// ## Why the catalogue is a cache
///
/// `buildTools` is synchronous while `tools/list` is a request. The tools the
/// model is offered therefore come from the last successful listing held here,
/// refreshed when the app starts, when the list of servers changes and when
/// the user asks. A refresh that fails keeps the last good listing and records
/// the error: a server that is briefly down loses its reachability, not the
/// capability the user granted, and the call itself is what reports the
/// failure.
///
/// ## Which servers are probed
///
/// Every configured server, switched on or not: the settings row reports each
/// one's state, and a server whose switch is off would otherwise never be
/// checked. Nothing is sent to a server — the listing is read-only — and the
/// user's own token is what rides on it, if the server needs one.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:persynth/personality/personality_network.dart';
import 'package:persynth/plugins/mcp_client.dart';

/// The `SharedPreferences` key the configured servers are stored under.
const String kMcpServersStoreKey = 'persynth_mcp_servers';

/// The secure-storage key one server's access token is stored under.
///
/// A token is a credential, so it goes to the keychain rather than to the
/// preferences the server list itself lives in.
String mcpTokenStoreKey(String serverId) => 'persynth_mcp_token_$serverId';

/// One MCP server the user connected.
@immutable
class SnMcpServer {
  const SnMcpServer({required this.id, required this.name, required this.url});

  /// Stable identifier, unique across the servers: the slug the user's name
  /// yields, and the name the server is stored, switched and namespaced under.
  final String id;

  /// What the user calls this server. Free text, shown in settings.
  final String name;

  /// The Streamable HTTP endpoint, e.g. `http://127.0.0.1:4317/mcp`.
  final Uri url;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'url': url.toString(),
  };

  /// Reads one stored server, or null when the entry is not a server.
  ///
  /// A malformed entry is dropped rather than repaired: a server the app
  /// cannot point at is not one it may guess at, and the rest of the list must
  /// still load.
  static SnMcpServer? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id']?.toString();
    final url = Uri.tryParse(json['url']?.toString() ?? '');
    if (id == null || id.isEmpty || url == null || !url.hasScheme) return null;
    final name = json['name']?.toString();
    return SnMcpServer(
      id: id,
      name: name == null || name.trim().isEmpty ? id : name.trim(),
      url: url,
    );
  }
}

/// The plugin id one configured server contributes to the registry.
///
/// Prefixed so a server's plugin can never collide with a built-in or script
/// plugin, and reversible — the server an id names can be read back from it.
String mcpServerPluginId(String serverId) => 'mcp_$serverId';

/// The server a plugin id names, or null when the id is not one of ours.
String? mcpServerIdOfPlugin(String pluginId) => pluginId.startsWith('mcp_')
    ? pluginId.substring('mcp_'.length)
    : null;

/// The longest tool name the model's providers accept, once the server has put
/// its own namespace in front of it.
const int kMaxLocalToolNameLength = 48;

/// What the model calls one tool of [serverId], from the name [tool] has on its
/// server.
///
/// The prefix is what keeps two servers' `search` apart, and what keeps a
/// server's tool from colliding with a built-in plugin's: the model sees one
/// flat list of caller-owned names. The result is lower-cased, stripped of
/// everything the wire format does not allow and capped at
/// [kMaxLocalToolNameLength] — a name the provider rejects fails the whole
/// run, not just that tool.
String mcpToolName(String serverId, String toolName) {
  final prefix = 'mcp_${_identifier(serverId, fallback: 'server')}_';
  final room = kMaxLocalToolNameLength - prefix.length;
  if (room <= 0) return prefix.substring(0, kMaxLocalToolNameLength);
  final identifier = _identifier(toolName, fallback: 'tool');
  return '$prefix${identifier.length > room ? identifier.substring(0, room) : identifier}';
}

/// A lower-case `[a-z0-9_]` identifier, as long as it is not empty.
String _identifier(String value, {required String fallback}) {
  final cleaned = value
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9_]+'), '_')
      .replaceAll(RegExp(r'_+'), '_')
      .replaceAll(RegExp(r'^_+|_+$'), '');
  return cleaned.isEmpty ? fallback : cleaned;
}

/// The slug one server's id may take, so nothing has to sanitize it twice.
String mcpServerSlug(String name, {required Set<String> taken}) {
  final base = _identifier(name, fallback: 'server');
  var candidate = base.length > 16 ? base.substring(0, 16) : base;
  var counter = 2;
  while (taken.contains(candidate)) {
    final suffix = '_$counter';
    final trimmed = base.length + suffix.length > 16
        ? base.substring(0, 16 - suffix.length)
        : base;
    candidate = '$trimmed$suffix';
    counter++;
  }
  return candidate;
}

/// The servers the user has connected, persisted across launches.
class McpServersNotifier extends Notifier<List<SnMcpServer>> {
  @override
  List<SnMcpServer> build() {
    final stored = ref.watch(
      sharedPreferencesProvider.select(
        (prefs) => prefs.getString(kMcpServersStoreKey),
      ),
    );
    if (stored == null || stored.trim().isEmpty) return const [];
    late final Object? decoded;
    try {
      decoded = jsonDecode(stored);
    } catch (_) {
      return const [];
    }
    if (decoded is! List) return const [];
    return [for (final entry in decoded) ?SnMcpServer.fromJson(entry)];
  }

  Future<void> _persist(List<SnMcpServer> servers) async {
    await ref
        .read(sharedPreferencesProvider)
        .setString(
          kMcpServersStoreKey,
          jsonEncode([for (final server in servers) server.toJson()]),
        );
  }

  /// Adds a server and returns it, with the id it will be known by.
  ///
  /// The token is written first: a credential that cannot be stored fails the
  /// add rather than leaving a server the user believes is authenticated. A
  /// blank url is refused — a server without an endpoint is not a server.
  Future<SnMcpServer> add({
    required String name,
    required String url,
    String? token,
  }) async {
    final uri = _checked(url);
    final server = SnMcpServer(
      id: mcpServerSlug(name, taken: {for (final s in state) s.id}),
      name: name.trim().isEmpty ? uri.host : name.trim(),
      url: uri,
    );
    final trimmedToken = token?.trim();
    if (trimmedToken != null && trimmedToken.isNotEmpty) {
      await ref
          .read(mcpTokenStoreProvider)
          .write(server.id, trimmedToken);
    }
    state = [...state, server];
    await _persist(state);
    return server;
  }

  /// Replaces what one server points at, keeping its id — and with it the
  /// switch the user already flipped and any conversation that loaded it.
  ///
  /// A null [token] leaves the stored one alone; an empty one clears it.
  Future<void> update(
    String id, {
    required String name,
    required String url,
    String? token,
  }) async {
    final uri = _checked(url);
    final index = state.indexWhere((server) => server.id == id);
    if (index < 0) return;
    if (token != null) {
      await ref.read(mcpTokenStoreProvider).write(id, token.trim());
    }
    final next = List.of(state);
    next[index] = SnMcpServer(
      id: id,
      name: name.trim().isEmpty ? uri.host : name.trim(),
      url: uri,
    );
    state = next;
    await _persist(next);
  }

  /// Removes a server: its configuration, its token, and the switch that
  /// granted it.
  Future<void> remove(String id) async {
    if (!state.any((server) => server.id == id)) return;
    state = [for (final server in state) if (server.id != id) server];
    await _persist(state);
    await ref.read(mcpTokenStoreProvider).clear(id);
    // The switch is the registry's, and the plugin it belongs to has just
    // disappeared — but the remembered value would outlive it and be waiting
    // if a server were added under the same name again.
    await ref
        .read(sharedPreferencesProvider)
        .remove('persynth_plugin_${mcpServerPluginId(id)}');
  }

  /// The endpoint the user typed, or a throw the settings row reports.
  Uri _checked(String url) {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || !uri.hasScheme || (uri.scheme != 'http' && uri.scheme != 'https') || uri.host.isEmpty) {
      throw const FormatException(
        'Enter the server\'s http:// or https:// endpoint.',
      );
    }
    return uri;
  }
}

final mcpServersProvider =
    NotifierProvider<McpServersNotifier, List<SnMcpServer>>(
      McpServersNotifier.new,
    );

/// What one configured server last answered.
@immutable
class McpServerState {
  const McpServerState({
    this.tools = const [],
    this.gateway,
    this.error,
    this.checked = false,
  });

  /// The tools the server last advertised. Kept across a failed refresh: a
  /// server that is briefly down has not withdrawn the tools the user
  /// granted.
  final List<McpServerTool> tools;

  /// The connection calls go through, once one has been made.
  final McpGateway? gateway;

  /// Why the last listing failed, or null when it succeeded.
  final String? error;

  /// Whether a listing has finished since the server list last changed.
  final bool checked;

  /// Whether the server answered its last listing.
  bool get reachable => checked && error == null;
}

/// The last listing of every configured server, keyed by server id.
///
/// Rebuilt when the list of servers changes, and updated in place as listings
/// answer. The plugin the registry builds for a server reads its own entry,
/// which is how a synchronous `buildTools` offers tools that arrive from a
/// request.
class McpCatalogueNotifier extends Notifier<Map<String, McpServerState>> {
  /// The last successful listing per server, which outlives a rebuild of this
  /// notifier's state — the notifier instance does.
  final Map<String, List<McpServerTool>> _lastGood = {};

  /// The live connection per server. Disposed when the server list changes,
  /// so a re-pointed server never keeps the old endpoint's session.
  final Map<String, McpGateway> _gateways = {};

  /// Which server list the in-flight listings belong to. A listing that
  /// answers after the list changed is dropped rather than written over the
  /// new one.
  int _generation = 0;

  @override
  Map<String, McpServerState> build() {
    if (kIsWeb) return const {};
    final servers = ref.watch(mcpServersProvider);
    final generation = ++_generation;

    // Every connection of the previous list is dropped, not just the ones for
    // servers that are gone: the list changing is what an edit looks like, and
    // both the endpoint and the token a connection was built from may have
    // moved under it.
    final ids = {for (final server in servers) server.id};
    for (final entry in _gateways.entries.toList()) {
      entry.value.dispose();
      _gateways.remove(entry.key);
    }
    _lastGood.removeWhere((serverId, _) => !ids.contains(serverId));

    // Nothing is checked yet for a server just added: the rows say so rather
    // than claiming a state they have not established.
    final state = {
      for (final server in servers)
        server.id: McpServerState(tools: _lastGood[server.id] ?? const []),
    };
    unawaited(_probeAll(servers, generation));
    return state;
  }

  /// Re-reads one server's tool list, for the settings row and for a switch
  /// that has just been flipped on.
  Future<void> refresh(String serverId) async {
    final server = ref
        .read(mcpServersProvider)
        .where((server) => server.id == serverId)
        .firstOrNull;
    if (server == null) return;
    await _probe(server, _generation);
  }

  /// Re-reads every configured server.
  Future<void> refreshAll() async {
    final generation = _generation;
    await _probeAll(ref.read(mcpServersProvider), generation);
  }

  Future<void> _probeAll(List<SnMcpServer> servers, int generation) async {
    await Future.wait([
      for (final server in servers) _probe(server, generation),
    ]);
  }

  Future<void> _probe(SnMcpServer server, int generation) async {
    final token = await ref.read(mcpTokenStoreProvider).read(server.id);
    if (_isStale(generation)) return;

    final gateway = _gateways.putIfAbsent(
      server.id,
      () => ref.read(mcpGatewayFactoryProvider)(server.url, token),
    );
    try {
      final tools = await gateway.listTools();
      if (_isStale(generation)) return;
      _lastGood[server.id] = tools;
      _write(server.id, McpServerState(
        tools: tools,
        gateway: gateway,
        checked: true,
      ));
    } catch (error) {
      if (_isStale(generation)) return;
      _write(server.id, McpServerState(
        tools: _lastGood[server.id] ?? const [],
        gateway: gateway,
        error: _describe(error),
        checked: true,
      ));
    }
  }

  /// Whether a listing that started before the current server list is no
  /// longer the one that matters.
  bool _isStale(int generation) => !ref.mounted || generation != _generation;

  void _write(String serverId, McpServerState status) {
    state = {...state, serverId: status};
  }

  /// A listing failure as the settings row says it. The transport's own
  /// message is kept — it is what says *why* (refused, 401, no such host) —
  /// but trimmed to one line, because the row shows one.
  static String _describe(Object error) {
    final text = error.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
    return text.length > 200 ? '${text.substring(0, 200)}…' : text;
  }
}

final mcpCatalogueProvider =
    NotifierProvider<McpCatalogueNotifier, Map<String, McpServerState>>(
      McpCatalogueNotifier.new,
    );

/// Reads and writes the per-server access tokens.
///
/// Abstract so tests can hand a server a token without a platform keychain —
/// and so nothing in the registry can reach one directly.
abstract class McpTokenStore {
  Future<String?> read(String serverId);

  /// Stores [token] for [serverId]. A blank token clears it.
  Future<void> write(String serverId, String token);

  Future<void> clear(String serverId);
}

/// The keychain the real app keeps server tokens in.
class SecureMcpTokenStore implements McpTokenStore {
  const SecureMcpTokenStore();

  static const FlutterSecureStorage _storage = FlutterSecureStorage();

  @override
  Future<String?> read(String serverId) =>
      _storage.read(key: mcpTokenStoreKey(serverId));

  @override
  Future<void> write(String serverId, String token) {
    final trimmed = token.trim();
    if (trimmed.isEmpty) return clear(serverId);
    return _storage.write(key: mcpTokenStoreKey(serverId), value: trimmed);
  }

  @override
  Future<void> clear(String serverId) =>
      _storage.delete(key: mcpTokenStoreKey(serverId));
}

final mcpTokenStoreProvider = Provider<McpTokenStore>(
  (ref) => const SecureMcpTokenStore(),
);

/// How the app builds a connection to a server. Overridden in tests with a
/// gateway that answers without a server running.
final mcpGatewayFactoryProvider = Provider<McpGatewayFactory>(
  (ref) => (baseUrl, token) => HttpMcpGateway(baseUrl: baseUrl, token: token),
);

/// Re-reads the server a plugin belongs to, if [pluginId] names one.
///
/// Called when a switch moves: the tools a server-backed plugin offers are the
/// catalogue's, so switching it on is what asks the server again — the model
/// should not have to wait for a relaunch to reach a server that came back.
Future<void> refreshMcpServerForPlugin(Ref ref, String pluginId) async {
  final serverId = mcpServerIdOfPlugin(pluginId);
  if (serverId == null) return;
  await ref.read(mcpCatalogueProvider.notifier).refresh(serverId);
}
