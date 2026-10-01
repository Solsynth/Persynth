/// The settings section for the user's own MCP servers.
///
/// Connection is the user's to make and to see: this section lists what they
/// added, what each server last answered, and the two things they can do about
/// it — check again, or edit and remove it. The switch that decides whether the
/// companion may use a server lives with every other plugin's switch, in the
/// Plugins section above, because that is the same grant: what the model may
/// call.
///
/// A server is added by name and endpoint, with an optional token that goes to
/// the keychain rather than to the preferences the list is stored in. The row
/// reports reachability honestly — never checked, checking, connected with n
/// tools, or why the last check failed — because a server that is switched on
/// and answering nothing looks exactly like a broken app otherwise.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';

import 'package:persynth/plugins/mcp_servers.dart';

/// The MCP servers the user connected, and what each one last answered.
class McpServersSection extends ConsumerWidget {
  const McpServersSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    if (kIsWeb) {
      return const Card(
        margin: EdgeInsets.zero,
        child: ListTile(
          leading: Icon(Symbols.devices_rounded),
          title: Text('MCP servers'),
          subtitle: Text(
            'Your own MCP servers can be connected in the desktop and mobile '
            'apps. A browser cannot reach a server on your machine.',
          ),
        ),
      );
    }

    final servers = ref.watch(mcpServersProvider);
    final catalogue = ref.watch(mcpCatalogueProvider);

    return Card(
      margin: EdgeInsets.zero,
      child: Column(
        children: [
          if (servers.isEmpty)
            ListTile(
              leading: const Icon(Symbols.hub_rounded),
              title: const Text('No MCP servers connected'),
              subtitle: Text(
                'Connect a server and its tools become a plugin the companion '
                'can load.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          for (final (index, server) in servers.indexed) ...[
            if (index > 0) const Divider(height: 1),
            _ServerRow(
              server: server,
              state: catalogue[server.id],
            ),
          ],
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Symbols.add_rounded),
            title: const Text('Add server'),
            subtitle: Text(
              'An http:// or https:// MCP endpoint. A server on this machine '
              'is usually http://127.0.0.1:<port>/mcp.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            onTap: () => showMcpServerDialog(context, ref),
          ),
        ],
      ),
    );
  }
}

/// One connected server: where it is, what it answered, and what can be done
/// about it.
class _ServerRow extends ConsumerWidget {
  const _ServerRow({required this.server, required this.state});

  final SnMcpServer server;
  final McpServerState? state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final status = state;
    final reachable = status?.reachable ?? false;
    final settled = status?.checked ?? false;

    final detail = switch (status) {
      null => 'Checking the server…',
      McpServerState(checked: false) => 'Checking the server…',
      McpServerState(error: final error?) => 'Not reachable: $error',
      McpServerState(tools: final tools) =>
        '${tools.length} tool${tools.length == 1 ? '' : 's'} available',
    };

    return ListTile(
      leading: Icon(
        settled
            ? (reachable ? Symbols.dns_rounded : Symbols.link_off_rounded)
            : Symbols.sync_rounded,
        color: reachable
            ? theme.colorScheme.primary
            : theme.colorScheme.onSurfaceVariant,
      ),
      title: Text(server.name),
      subtitle: Text(
        '${server.url}\n$detail',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
      isThreeLine: true,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: 'Check again',
            icon: const Icon(Symbols.refresh),
            onPressed: () => ref
                .read(mcpCatalogueProvider.notifier)
                .refresh(server.id),
          ),
          IconButton(
            tooltip: 'Edit',
            icon: const Icon(Symbols.edit),
            onPressed: () =>
                showMcpServerDialog(context, ref, server: server),
          ),
          IconButton(
            tooltip: 'Remove',
            icon: const Icon(Symbols.delete_outline),
            onPressed: () => _confirmRemove(context, ref),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmRemove(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Remove ${server.name}?'),
        content: const Text(
          'The companion loses this server\'s tools, and the token stored for '
          'it is deleted. The server itself is not touched.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await ref.read(mcpServersProvider.notifier).remove(server.id);
  }
}

/// Adds a server, or edits the one given.
Future<void> showMcpServerDialog(
  BuildContext context,
  WidgetRef ref, {
  SnMcpServer? server,
}) {
  return showDialog<void>(
    context: context,
    builder: (context) => _McpServerDialog(server: server),
  );
}

/// The add/edit form.
///
/// Failures are shown in the form rather than in a snack bar behind it: a URL
/// the app will not use, or a token the keychain will not store, are things
/// the user can fix in the fields they typed them into.
class _McpServerDialog extends HookConsumerWidget {
  const _McpServerDialog({this.server});

  /// The server being edited, or null when one is being added.
  final SnMcpServer? server;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final editing = server != null;
    final name = useTextEditingController(text: server?.name ?? '');
    final url = useTextEditingController(text: server?.url.toString() ?? '');
    final token = useTextEditingController();
    final error = useState<String?>(null);
    final busy = useState(false);

    Future<void> submit() async {
      busy.value = true;
      error.value = null;
      try {
        final servers = ref.read(mcpServersProvider.notifier);
        final typedToken = token.text.trim();
        if (editing) {
          await servers.update(
            server!.id,
            name: name.text,
            url: url.text,
            // Blank means "keep the stored token", so an edit that does not
            // touch the token cannot wipe it.
            token: typedToken.isEmpty ? null : typedToken,
          );
        } else {
          await servers.add(name: name.text, url: url.text, token: typedToken);
        }
        if (context.mounted) Navigator.of(context).pop();
      } on FormatException catch (failure) {
        error.value = failure.message;
      } catch (failure) {
        error.value = 'Could not store the token: $failure';
      } finally {
        busy.value = false;
      }
    }

    return AlertDialog(
      title: Text(editing ? 'Edit server' : 'Connect an MCP server'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: name,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Name',
                hintText: 'Home server',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: url,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                labelText: 'Endpoint',
                hintText: 'http://127.0.0.1:4317/mcp',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: token,
              obscureText: true,
              decoration: InputDecoration(
                labelText: 'Access token',
                hintText: editing
                    ? 'Leave blank to keep the stored token'
                    : 'Optional',
              ),
            ),
            if (error.value != null) ...[
              const SizedBox(height: 12),
              Text(
                error.value!,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: busy.value ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: busy.value ? null : submit,
          child: Text(editing ? 'Save' : 'Connect'),
        ),
      ],
    );
  }
}
