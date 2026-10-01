import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';

import 'package:persynth/auth/solar_auth_controller.dart';
import 'package:persynth/auth/solar_sign_in_panel.dart';
import 'package:persynth/personality/personality_network.dart';
import 'package:persynth/personality/personality_session.dart';
import 'package:persynth/personality/reasoning_settings.dart';
import 'package:persynth/plugins/mcp_servers_section.dart';
import 'package:persynth/plugins/plugin.dart';
import 'package:persynth/plugins/plugin_registry.dart';
import 'package:persynth/screens/ai_console_tabs.dart';

/// The pushed settings page: the account and server in General, with the AI
/// console (agents, models, billing, credentials) folded in as its own tabs.
@RoutePage()
class SettingsPage extends HookConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return DefaultTabController(
      length: 4,
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Symbols.arrow_back),
            tooltip: 'Back',
            onPressed: () => context.router.maybePop(),
          ),
          title: const Text('Settings'),
          bottom: const TabBar(
            tabs: [
              Tab(icon: Icon(Symbols.tune_rounded), text: 'General'),
              Tab(icon: Icon(Symbols.extension), text: 'Catalog'),
              Tab(icon: Icon(Symbols.receipt_long), text: 'Billing'),
              Tab(icon: Icon(Symbols.key), text: 'Credentials'),
            ],
          ),
        ),
        body: const TabBarView(
          children: [
            _GeneralSettingsTab(),
            AiConsoleCatalogTab(),
            AiConsoleBillingTab(),
            AiConsoleCredentialsTab(),
          ],
        ),
      ),
    );
  }
}

/// Account and Personality server settings.
class _GeneralSettingsTab extends HookConsumerWidget {
  const _GeneralSettingsTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final authState = ref.watch(solarAuthStateProvider);
    final savingUrl = useState(false);

    final urlController = useTextEditingController(
      text: ref.read(personalityServerUrlProvider),
    );

    Future<void> signOut() async {
      await ref.read(solarAuthStateProvider.notifier).signOut();
      // The account's agents, threads and open conversation go with the
      // session, so the next one never draws the last one's.
      invalidatePersonalitySession(ref);
    }

    Future<void> saveServerUrl() async {
      savingUrl.value = true;
      try {
        await ref
            .read(personalityServerUrlProvider.notifier)
            .set(urlController.text);
        if (context.mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('Settings saved')));
        }
      } finally {
        savingUrl.value = false;
      }
    }

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _SectionHeader('Account'),
        Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
            child: Row(
              children: [
                CircleAvatar(
                  backgroundColor: scheme.primaryContainer,
                  child: Icon(
                    Symbols.person_rounded,
                    color: scheme.onPrimaryContainer,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: authState.user == null
                      ? Text('Not signed in', style: theme.textTheme.bodyMedium)
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              authState.user!.name,
                              style: theme.textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            if (authState.user!.handle.isNotEmpty)
                              Text(
                                '@${authState.user!.handle}',
                                style: theme.textTheme.bodySmall,
                              ),
                          ],
                        ),
                ),
                if (authState.status == SolarAuthStatus.checking ||
                    authState.status == SolarAuthStatus.signingIn)
                  const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else if (authState.user != null)
                  TextButton(onPressed: signOut, child: const Text('Sign out')),
              ],
            ),
          ),
        ),
        if (authState.user == null) ...[
          const SizedBox(height: 12),
          const SolarSignInPanel(),
        ],
        const SizedBox(height: 20),
        _SectionHeader('Server'),
        Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Personality server URL',
                  style: theme.textTheme.titleSmall,
                ),
                const SizedBox(height: 4),
                Text(
                  'Where the AI companion reaches its Personality backend.',
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: urlController,
                        decoration: const InputDecoration(
                          hintText: 'https://api.solian.app',
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: savingUrl.value ? null : saveServerUrl,
                      child: const Text('Save'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 20),
        _SectionHeader('Plugins'),
        const _PluginsSection(),
        const SizedBox(height: 20),
        // The servers the companions' server-backed plugins point at sit below
        // the switches rather than above them: the switches are what the user
        // works with daily, and a list that only grows when a server is
        // connected must not push them down the page.
        _SectionHeader('Connections'),
        const McpServersSection(),
        const SizedBox(height: 20),
        _SectionHeader('Reasoning'),
        const _ReasoningSection(),
      ],
    );
  }
}

/// How much the companion thinks before it answers.
///
/// The choice is sent with every run, because the backend applies a run's
/// reasoning controls when the run starts and never remembers them. Levels
/// beyond Low and High are provider-specific: the picker offers the whole set
/// the backend accepts and says plainly that a model may refuse one.
class _ReasoningSection extends ConsumerWidget {
  const _ReasoningSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final setting = ref.watch(reasoningSettingProvider);

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Thinking', style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
            Text(
              'How much the companion reasons before answering. Higher effort '
              'buys care at the cost of time, and Off turns thinking off '
              'where the model allows it. A model that does not support the '
              'chosen level will refuse the message and say so.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<ReasoningSetting>(
              initialValue: setting,
              decoration: const InputDecoration(labelText: 'Reasoning effort'),
              items: [
                for (final option in ReasoningSetting.values)
                  DropdownMenuItem(value: option, child: Text(option.label)),
              ],
              onChanged: (value) {
                if (value != null) {
                  ref.read(reasoningSettingProvider.notifier).set(value);
                }
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// The switches behind which the companion's on-device capabilities sit.
///
/// A plugin's tools and its prompt text are not a server-side ability: the app
/// runs the calls on this machine, so the switches are the whole permission
/// model, and a plugin that is off is never offered to the model at all. Each
/// plugin supplies its own title and its own account of what turning it on
/// grants — including the script plugins, which were discovered rather than
/// compiled in, and appear here without an edit.
class _PluginsSection extends ConsumerWidget {
  const _PluginsSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final plugins = ref.watch(pluginRegistryProvider);
    final enabled = ref.watch(pluginEnablementProvider);
    final notifier = ref.read(pluginEnablementProvider.notifier);

    if (plugins.isEmpty) {
      return const Card(
        margin: EdgeInsets.zero,
        child: ListTile(
          title: Text('No plugins'),
          subtitle: Text('This build has no companion capabilities to grant.'),
        ),
      );
    }

    return Card(
      margin: EdgeInsets.zero,
      child: Column(
        children: [
          for (final (index, plugin) in plugins.indexed) ...[
            if (index > 0) const Divider(height: 1),
            SwitchListTile(
              value: enabled.contains(plugin.id),
              onChanged: (value) => notifier.setEnabled(plugin.id, value),
              title: Text(plugin.label),
              subtitle: Text(
                '${plugin.description}${_replaces(plugin)}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            ...plugin.settingsRows(ref),
          ],
        ],
      ),
    );
  }
}

/// What a plugin takes over from the server, as a sentence to append to its
/// own account of itself.
///
/// A plugin that replaces a server tool changes where the call comes from,
/// which is the whole reason to prefer it — so the row has to say so. Derived
/// from the plugin's own declaration rather than written into its description,
/// so a plugin cannot claim a replacement the rest of the app does not know
/// about, and the list cannot go stale.
String _replaces(SnPlugin plugin) {
  final names = plugin.overrides.keys.toList()..sort();
  if (names.isEmpty) return '';
  return ' Replaces the server\'s ${names.join(', ')}.';
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        title,
        style: theme.textTheme.titleMedium?.copyWith(
          color: theme.colorScheme.primary,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}
