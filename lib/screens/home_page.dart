import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:island_ui_foundation/island_ui_foundation.dart';

import 'package:synth_pet/auth/solar_auth_service.dart';
import 'package:synth_pet/personality/personality_service.dart';
import 'package:synth_pet/pet/pet_appearance_settings.dart';
import 'package:synth_pet/shared/desktop_window_service.dart';
import 'package:synth_pet/widgets/pet_avatar.dart';

@RoutePage()
class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final wide = isWideScreen(context);

    return Scaffold(
      backgroundColor: colors.surface,
      body: SafeArea(
        child: wide
            ? Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const _SideNavigation(),
                  Expanded(child: _DashboardContent(wide: wide)),
                ],
              )
            : _DashboardContent(wide: wide),
      ),
      bottomNavigationBar: wide ? null : const _CompactNavigation(),
    );
  }
}

class _SideNavigation extends StatelessWidget {
  const _SideNavigation();

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return SizedBox(
      width: 224,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 12, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'synth.pet',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w700,
                letterSpacing: -.4,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'A small place to land',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant),
            ),
            const SizedBox(height: 28),
            SizedBox(
              height: 176,
              child: NavigationRail(
                backgroundColor: Colors.transparent,
                selectedIndex: 0,
                onDestinationSelected: (_) {},
                labelType: NavigationRailLabelType.all,
                destinations: const [
                  NavigationRailDestination(
                    icon: Icon(Icons.home_outlined),
                    selectedIcon: Icon(Icons.home_rounded),
                    label: Text('Configuration'),
                  ),
                  NavigationRailDestination(
                    icon: Icon(Icons.insights_outlined),
                    selectedIcon: Icon(Icons.insights_rounded),
                    label: Text('Insights'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            Text(
              'v0.1 · local only',
              style: Theme.of(
                context,
              ).textTheme.labelSmall?.copyWith(color: colors.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

class _CompactNavigation extends StatelessWidget {
  const _CompactNavigation();

  @override
  Widget build(BuildContext context) {
    return NavigationBar(
      selectedIndex: 0,
      onDestinationSelected: (_) {},
      destinations: const [
        NavigationDestination(
          icon: Icon(Icons.home_outlined),
          selectedIcon: Icon(Icons.home_rounded),
          label: 'Configuration',
        ),
        NavigationDestination(
          icon: Icon(Icons.insights_outlined),
          selectedIcon: Icon(Icons.insights_rounded),
          label: 'Insights',
        ),
      ],
    );
  }
}

class _DashboardContent extends StatelessWidget {
  const _DashboardContent({required this.wide});

  final bool wide;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(wide ? 20 : 20, 20, 20, 28),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 980),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Builder(
                builder: (context) {
                  final greeting = Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Configure your companion.',
                        style: Theme.of(context).textTheme.headlineSmall
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        "Set up Mochi's presence, rhythm, and window behavior.",
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                  );
                  final openButton = FilledButton.icon(
                    onPressed: DesktopWindowService.openPetWindow,
                    icon: const Icon(Icons.open_in_new_rounded),
                    label: const Text('Open floating pet'),
                  );

                  return wide
                      ? Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(child: greeting),
                            openButton,
                          ],
                        )
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            greeting,
                            const SizedBox(height: 16),
                            Align(
                              alignment: Alignment.centerLeft,
                              child: openButton,
                            ),
                          ],
                        );
                },
              ),
              const SizedBox(height: 24),
              _CompanionCard(colors: colors, wide: wide),
              const SizedBox(height: 16),
              const _ConfigurationCard(),
              const SizedBox(height: 16),
              Wrap(
                spacing: 16,
                runSpacing: 16,
                children: const [
                  _MetricCard(
                    label: 'Mood',
                    value: 'Content',
                    detail: 'A calm start',
                    icon: Icons.wb_sunny_outlined,
                  ),
                  _MetricCard(
                    label: 'Energy',
                    value: '78%',
                    detail: 'Plenty for today',
                    icon: Icons.bolt_outlined,
                  ),
                  _MetricCard(
                    label: 'Last visit',
                    value: 'Yesterday',
                    detail: 'You kept a rhythm',
                    icon: Icons.history_rounded,
                  ),
                ],
              ),
              const SizedBox(height: 24),
              Text(
                'Current snapshot',
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 10),
              _RitualList(colors: colors),
            ],
          ),
        ),
      ),
    );
  }
}

class _CompanionCard extends StatelessWidget {
  const _CompanionCard({required this.colors, required this.wide});

  final ColorScheme colors;
  final bool wide;

  @override
  Widget build(BuildContext context) {
    final details = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Mochi',
          style: Theme.of(context).textTheme.headlineMedium?.copyWith(
            color: colors.onPrimaryContainer,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Your soft-spoken desktop companion.\nAlways nearby, never noisy.',
          style: Theme.of(
            context,
          ).textTheme.bodyLarge?.copyWith(color: colors.onPrimaryContainer),
        ),
        const SizedBox(height: 18),
        FilledButton.tonalIcon(
          onPressed: DesktopWindowService.openPetWindow,
          icon: const Icon(Icons.favorite_border_rounded),
          label: const Text('Spend a minute together'),
        ),
      ],
    );

    return Card(
      color: colors.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: wide
            ? Row(
                children: [
                  const PetAvatar(size: 144),
                  const SizedBox(width: 24),
                  Expanded(child: details),
                ],
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const PetAvatar(size: 128),
                  const SizedBox(height: 16),
                  details,
                ],
              ),
      ),
    );
  }
}

class _ConfigurationCard extends StatefulWidget {
  const _ConfigurationCard();

  @override
  State<_ConfigurationCard> createState() => _ConfigurationCardState();
}

class _ConfigurationCardState extends State<_ConfigurationCard> {
  final _auth = SolarAuthService();
  final _personalityConfig = PersonalityCoreConfig.fromEnvironment();
  final _appearanceSettings = const PetAppearanceSettings();
  SolarUser? _user;
  PetAppearance _appearance = PetAppearance.defaultValue;
  bool _authBusy = false;
  String? _authError;
  bool _alwaysOnTop = true;
  double _checkInMinutes = 45;

  @override
  void initState() {
    super.initState();
    _loadAppearance();
    _loadAccount();
  }

  Future<void> _loadAccount() async {
    try {
      final user = await _auth.currentUser();
      if (mounted) setState(() => _user = user);
    } on SolarAuthException {
      if (mounted) setState(() => _user = null);
    }
  }

  Future<void> _loadAppearance() async {
    try {
      final appearance = await _appearanceSettings.load();
      if (mounted) setState(() => _appearance = appearance);
    } catch (_) {
      // The default face remains available when local storage is unavailable.
    }
  }

  Future<void> _saveAppearance(PetAppearance appearance) async {
    setState(() => _appearance = appearance);
    try {
      await _appearanceSettings.save(appearance);
    } catch (_) {
      // The current selection still previews in this session.
    }
  }

  Future<void> _signIn() async {
    setState(() {
      _authBusy = true;
      _authError = null;
    });
    try {
      final user = await _auth.signIn();
      if (mounted) setState(() => _user = user);
    } on SolarAuthException catch (error) {
      if (mounted) setState(() => _authError = error.message);
    } finally {
      if (mounted) setState(() => _authBusy = false);
    }
  }

  Future<void> _signOut() async {
    await _auth.signOut();
    if (mounted) setState(() => _user = null);
  }

  Future<void> _setAlwaysOnTop(bool value) async {
    setState(() => _alwaysOnTop = value);
    await DesktopWindowService.setPetAlwaysOnTop(value);
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Column(
          children: [
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.account_circle_outlined),
              title: Text(_user?.name ?? 'Solar Network account'),
              subtitle: Text(
                _user == null
                    ? (_authError ?? 'Sign in with Solar Network OAuth')
                    : (_user!.handle.isEmpty
                          ? 'Signed in'
                          : '@${_user!.handle}'),
              ),
              trailing: _authBusy
                  ? const SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : _user == null
                  ? FilledButton(
                      onPressed: _signIn,
                      child: const Text('Sign in'),
                    )
                  : TextButton(
                      onPressed: _signOut,
                      child: const Text('Sign out'),
                    ),
            ),
            const Divider(height: 1),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('ASCII face'),
              subtitle: Text('Current expression: ${_appearance.face}'),
              trailing: PetAvatar(size: 64, face: _appearance.face),
            ),
            Row(
              children: [
                Expanded(
                  child: _FacePartSelector(
                    label: 'Left eye',
                    value: _appearance.leftEye,
                    options: const ['0', 'o', '^', '>', '<', '-'],
                    onChanged: (value) {
                      if (value != null) {
                        _saveAppearance(_appearance.copyWith(leftEye: value));
                      }
                    },
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _FacePartSelector(
                    label: 'Mouth',
                    value: _appearance.mouth,
                    options: const ['.', '-', '^', '_', 'o'],
                    onChanged: (value) {
                      if (value != null) {
                        _saveAppearance(_appearance.copyWith(mouth: value));
                      }
                    },
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _FacePartSelector(
                    label: 'Right eye',
                    value: _appearance.rightEye,
                    options: const ['0', 'o', '^', '>', '<', '-'],
                    onChanged: (value) {
                      if (value != null) {
                        _saveAppearance(_appearance.copyWith(rightEye: value));
                      }
                    },
                  ),
                ),
              ],
            ),
            const Divider(height: 1),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.auto_awesome_outlined),
              title: const Text('Personality Core'),
              subtitle: Text(
                _user != null
                    ? 'Ready · agent ${_personalityConfig.agentId}'
                    : 'Sign in above to use Personality Core',
              ),
            ),
            const Divider(height: 1),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Keep Mochi above your work'),
              subtitle: const Text('Keep the floating companion nearby'),
              value: _alwaysOnTop,
              onChanged: _setAlwaysOnTop,
            ),
            const Divider(height: 1),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Check-in rhythm'),
              subtitle: const Text(
                'How often Mochi gently gets your attention',
              ),
              trailing: Text('${_checkInMinutes.round()} min'),
            ),
            Slider(
              value: _checkInMinutes,
              min: 15,
              max: 90,
              divisions: 5,
              label: '${_checkInMinutes.round()} min',
              onChanged: (value) => setState(() => _checkInMinutes = value),
            ),
          ],
        ),
      ),
    );
  }
}

class _FacePartSelector extends StatelessWidget {
  const _FacePartSelector({
    required this.label,
    required this.value,
    required this.options,
    required this.onChanged,
  });

  final String label;
  final String value;
  final List<String> options;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    return DropdownButtonFormField<String>(
      initialValue: value,
      decoration: InputDecoration(labelText: label),
      items: [
        for (final option in options)
          DropdownMenuItem(value: option, child: Text(option)),
      ],
      onChanged: onChanged,
    );
  }
}

class _MetricCard extends StatelessWidget {
  const _MetricCard({
    required this.label,
    required this.value,
    required this.detail,
    required this.icon,
  });

  final String label;
  final String value;
  final String detail;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 250,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 20),
              const SizedBox(height: 16),
              Text(label, style: Theme.of(context).textTheme.labelLarge),
              const SizedBox(height: 4),
              Text(
                value,
                style: Theme.of(
                  context,
                ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 3),
              Text(
                detail,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RitualList extends StatelessWidget {
  const _RitualList({required this.colors});

  final ColorScheme colors;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Column(
        children: [
          ListTile(
            leading: Icon(Icons.coffee_rounded, color: colors.primary),
            title: const Text('Take a quiet break'),
            subtitle: const Text('A soft reminder after 45 minutes'),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: DesktopWindowService.openPetWindow,
          ),
          const Divider(height: 1),
          ListTile(
            leading: Icon(Icons.nightlight_outlined, color: colors.primary),
            title: const Text('Wind down together'),
            subtitle: const Text('Mochi will dim the room at night'),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: DesktopWindowService.openPetWindow,
          ),
        ],
      ),
    );
  }
}
