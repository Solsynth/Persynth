import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';

import 'package:synth_pet/auth/solar_auth_controller.dart';
import 'package:synth_pet/auth/solar_auth_service.dart';
import 'package:synth_pet/personality/personality_network.dart';
import 'package:synth_pet/screens/ai_console_tabs.dart';

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

    Future<void> signIn() async {
      try {
        await ref.read(solarAuthStateProvider.notifier).signIn();
      } on SolarAuthException catch (error) {
        if (context.mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(error.message)));
        }
      }
    }

    Future<void> signOut() async {
      await ref.read(solarAuthStateProvider.notifier).signOut();
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
                if (authState.status == SolarAuthStatus.checking)
                  const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else if (authState.user == null)
                  FilledButton(onPressed: signIn, child: const Text('Sign in'))
                else
                  TextButton(onPressed: signOut, child: const Text('Sign out')),
              ],
            ),
          ),
        ),
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
      ],
    );
  }
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
