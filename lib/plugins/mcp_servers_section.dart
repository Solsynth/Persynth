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
/// the keychain rather than to the preferences the list is stored in — or by
/// pasting the configuration file another client already wrote, which is the
/// same thing with the token the user does not have to find again. The row
/// reports reachability honestly — never checked, checking, connected with n
/// tools, or why the last check failed — because a server that is switched on
/// and answering nothing looks exactly like a broken app otherwise.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';

import 'package:easy_localization/easy_localization.dart';
import 'package:persynth/plugins/mcp_config.dart';
import 'package:persynth/plugins/mcp_servers.dart';
import 'package:persynth/theme/app_theme.dart';

/// The MCP servers the user connected, and what each one last answered.
class McpServersSection extends ConsumerWidget {
  const McpServersSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    if (kIsWeb) {
      return Card(
        margin: EdgeInsets.zero,
        child: ListTile(
          leading: const Icon(Symbols.devices_rounded),
          title: Text('mcpServers'.tr()),
          subtitle: Text('mcpServersWebNote'.tr()),
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
              title: Text('noMcpServers'.tr()),
              subtitle: Text(
                'connectMcpServerHint'.tr(),
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
            title: Text('addServer'.tr()),
            subtitle: Text(
              'addServerHint'.tr(),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            onTap: () => showMcpServerDialog(context, ref),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Symbols.content_paste_rounded),
            title: Text('pasteJsonConfig'.tr()),
            subtitle: Text(
              'pasteJsonConfigHint'.tr(),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            onTap: () => showMcpConfigDialog(context),
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
      null => 'checkingServer'.tr(),
      McpServerState(checked: false) => 'checkingServer'.tr(),
      McpServerState(error: final error?) =>
        'notReachable'.tr(namedArgs: {'error': error}),
      McpServerState(tools: final tools) => tools.length == 1
          ? 'toolAvailable'.tr(namedArgs: {'count': '${tools.length}'})
          : 'toolsAvailable'.tr(namedArgs: {'count': '${tools.length}'}),
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
            tooltip: 'checkAgain'.tr(),
            icon: const Icon(Symbols.refresh),
            onPressed: () => ref
                .read(mcpCatalogueProvider.notifier)
                .refresh(server.id),
          ),
          IconButton(
            tooltip: 'edit'.tr(),
            icon: const Icon(Symbols.edit),
            onPressed: () =>
                showMcpServerDialog(context, ref, server: server),
          ),
          IconButton(
            tooltip: 'remove'.tr(),
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
        title: Text('removeServerConfirmation'.tr(namedArgs: {'name': server.name})),
        content: Text('removeServerDescription'.tr()),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text('cancel'.tr()),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text('remove'.tr()),
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

/// Opens the paste form: a whole MCP configuration file, read into servers.
Future<void> showMcpConfigDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (context) => const _McpConfigDialog(),
  );
}

/// The paste form: one configuration file in, its servers added.
///
/// The text is read in full before anything is written, so a paste the app
/// cannot make sense of is answered in the field it was typed in and leaves the
/// list alone. What the file said that this app does not carry over — a server
/// it would have to launch itself, headers beyond the bearer token, a transport
/// it does not speak — is listed under the field rather than dropped quietly:
/// the user is the only one who can decide about their own config.
class _McpConfigDialog extends HookConsumerWidget {
  const _McpConfigDialog();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final config = useTextEditingController();
    final error = useState<String?>(null);
    final outcome = useState<McpConfigImport?>(null);
    final busy = useState(false);

    Future<void> import() async {
      busy.value = true;
      error.value = null;
      try {
        final imported = await ref
            .read(mcpServersProvider.notifier)
            .importConfig(config.text);
        if (!context.mounted) return;
        outcome.value = imported;
        // Emptied, so pressing Import twice cannot add the same servers twice.
        config.clear();
      } on FormatException catch (failure) {
        error.value = failure.message;
      } catch (failure) {
        error.value = 'couldNotStoreToken'.tr(namedArgs: {'error': '$failure'});
      } finally {
        busy.value = false;
      }
    }

    final result = outcome.value;
    return AlertDialog(
      title: Text('pasteMcpConfig'.tr()),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: config,
                autofocus: true,
                minLines: 6,
                maxLines: 12,
                style: const TextStyle(
                  fontFamily: PersynthFonts.mono,
                  fontSize: 12,
                  height: 1.4,
                ),
                decoration: InputDecoration(
                  labelText: 'configurationJson'.tr(),
                  alignLabelWithHint: true,
                  hintText:
                      '{"mcpServers": {"weather": {"url": '
                      '"https://example.com/mcp"}}}',
                ),
              ),
              if (error.value != null) ...[
                const SizedBox(height: 12),
                Text(
                  error.value!,
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ],
              if (result != null) ...[
                const SizedBox(height: 16),
                _ImportOutcome(outcome: result),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: busy.value ? null : () => Navigator.of(context).pop(),
          child: Text('close'.tr()),
        ),
        FilledButton(
          onPressed: busy.value ? null : import,
          child: Text('import'.tr()),
        ),
      ],
    );
  }
}

/// What one paste did: the servers it added, and the ones it left out.
class _ImportOutcome extends StatelessWidget {
  const _ImportOutcome({required this.outcome});

  final McpConfigImport outcome;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final added = outcome.servers.length;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          added == 0
              ? 'noServersAdded'.tr()
              : 'serversAdded'.plural(added),
          style: theme.textTheme.titleSmall,
        ),
        const SizedBox(height: 4),
        for (final server in outcome.servers) ...[
          Text(server.name, style: theme.textTheme.bodyMedium),
          Text(server.url.toString(), style: muted),
          if (server.note != null) Text(server.note!, style: muted),
          const SizedBox(height: 8),
        ],
        if (outcome.skipped.isNotEmpty) ...[
          Text('notAdded'.tr(), style: theme.textTheme.titleSmall),
          const SizedBox(height: 4),
          for (final line in outcome.skipped) Text(line, style: muted),
        ],
      ],
    );
  }
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
        error.value = 'couldNotStoreToken'.tr(namedArgs: {'error': '$failure'});
      } finally {
        busy.value = false;
      }
    }

    return AlertDialog(
      title: Text(editing ? 'editServer'.tr() : 'connectMcpServer'.tr()),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: name,
              autofocus: true,
              decoration: InputDecoration(
                labelText: 'name'.tr(),
                hintText: 'homeServerHint'.tr(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: url,
              keyboardType: TextInputType.url,
              decoration: InputDecoration(
                labelText: 'endpoint'.tr(),
                hintText: 'http://127.0.0.1:4317/mcp',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: token,
              obscureText: true,
              decoration: InputDecoration(
                labelText: 'accessToken'.tr(),
                hintText: editing
                    ? 'leaveBlankToKeepToken'.tr()
                    : 'optional'.tr(),
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
          child: Text('cancel'.tr()),
        ),
        FilledButton(
          onPressed: busy.value ? null : submit,
          child: Text(editing ? 'save'.tr() : 'connect'.tr()),
        ),
      ],
    );
  }
}
