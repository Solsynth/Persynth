import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:gap/gap.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';

import 'package:persynth/auth/solar_auth_controller.dart';
import 'package:persynth/auth/solar_auth_service.dart';
import 'package:persynth/auth/solar_sign_in_panel.dart';
import 'package:persynth/personality/personality_network.dart';
import 'package:persynth/personality/personality_service.dart';
import 'package:persynth/personality/personality_session.dart';
import 'package:persynth/plugins/mcp_servers_section.dart';
import 'package:persynth/plugins/plugin.dart';
import 'package:persynth/plugins/plugin_registry.dart';
import 'package:persynth/screens/ai_console_tabs.dart';

/// The width the settings content is held to, matching the conversation's
/// reading column so a wide window shows the same measure everywhere.
const double _kSettingsContentWidth = 760;

/// The pushed settings page: the account and server in General, with the AI
/// console (agents, models, billing, credentials) folded in as its own tabs.
///
/// The page is a phone layout that also has to survive a desktop window, so
/// both the tab strip and the tab bodies are held to
/// [_kSettingsContentWidth] and centered: cards keep an 800px-wide window
/// from stretching a row of controls across it, and the tabs stay listed
/// under the cards' left edge instead of spreading out over the whole
/// toolbar.
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
          // Aligned rather than centered on the vertical axis so the strip
          // sits exactly where a full-width TabBar would, indicator included.
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(kTextTabBarHeight),
            child: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: _kSettingsContentWidth,
                ),
                child: const TabBar(
                  // Not `fill`: equal-width tabs would either clip a label on
                  // a phone or hand each of the four a quarter of a desktop
                  // window. The strip scrolls once the labels stop fitting.
                  isScrollable: true,
                  tabAlignment: TabAlignment.start,
                  padding: EdgeInsets.symmetric(horizontal: 16),
                  tabs: [
                    _SettingsTab(Symbols.tune_rounded, 'General'),
                    _SettingsTab(Symbols.extension, 'Catalog'),
                    _SettingsTab(Symbols.receipt_long, 'Billing'),
                    _SettingsTab(Symbols.key, 'Credentials'),
                  ],
                ),
              ),
            ),
          ),
        ),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: _kSettingsContentWidth),
            child: const TabBarView(
              children: [
                _GeneralSettingsTab(),
                AiConsoleCatalogTab(),
                AiConsoleBillingTab(),
                AiConsoleCredentialsTab(),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// One tab, drawn as its icon beside its label rather than stacked above it.
///
/// The colors come from the surrounding `TabBar` — `_TabStyle` hands the tab
/// an `IconTheme` and a `DefaultTextStyle` for the selected and unselected
/// states — so nothing here has to know whether the tab is current.
class _SettingsTab extends StatelessWidget {
  const _SettingsTab(this.icon, this.label);

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Tab(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 18),
          const Gap(8),
          Text(label, softWrap: false, overflow: TextOverflow.fade),
        ],
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
                _AccountAvatar(user: authState.user),
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
      ],
    );
  }
}

/// The signed-in account's picture on the tinted disc, or the neutral person
/// where there is none to draw: signed out, a profile that never set a
/// picture, and a file whose bytes never arrive all land on the same fallback.
///
/// The picture is a drive file behind the account, so it is fetched with the
/// bearer token — read here rather than threaded through, because the widget
/// that draws it is the only thing that needs it.
class _AccountAvatar extends ConsumerWidget {
  const _AccountAvatar({this.user});

  /// The account on the card, or null while nobody is signed in.
  final SolarUser? user;

  /// The disc's diameter: the pixels a picture is decoded down to, so a
  /// full-size photo is never held in memory to fill a 40px circle.
  static const double _diameter = 40;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final fallback = Icon(
      Symbols.person_rounded,
      color: scheme.onPrimaryContainer,
    );
    final pictureId = user?.pictureId;
    final token = ref.watch(solarAccessTokenProvider).value?.trim() ?? '';
    if (pictureId == null || token.isEmpty) {
      return CircleAvatar(
        backgroundColor: scheme.primaryContainer,
        child: fallback,
      );
    }
    final provider = NetworkImage(
      user!.pictureUrl ??
          PersonalityCoreService.driveFileUrl(
            ref.watch(personalityDriveBaseUrlProvider),
            pictureId,
          ),
      headers: {'Authorization': 'Bearer $token'},
    );
    return CircleAvatar(
      backgroundColor: scheme.primaryContainer,
      foregroundImage: ResizeImage(
        provider,
        width: (_diameter * MediaQuery.devicePixelRatioOf(context)).round(),
        policy: ResizeImagePolicy.fit,
      ),
      // Keeps the icon up rather than throwing when the picture cannot be
      // drawn — a file since deleted, a refused request, a non-image.
      onForegroundImageError: (_, _) {},
      child: fallback,
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
