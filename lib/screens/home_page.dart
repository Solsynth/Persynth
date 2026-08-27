import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';

import 'package:synth_pet/auth/solar_auth_service.dart';
import 'package:synth_pet/personality/personality_service.dart';
import 'package:synth_pet/screens/conversation_page.dart';
import 'package:synth_pet/shared/desktop_window_service.dart';

@RoutePage()
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _selected = 0;

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 760;
    final content = AnimatedSwitcher(
      duration: const Duration(milliseconds: 180),
      switchInCurve: Curves.easeOut,
      switchOutCurve: Curves.easeOut,
      transitionBuilder: (child, animation) =>
          FadeTransition(opacity: animation, child: child),
      child: _selected == 0
          ? KeyedSubtree(
              key: const ValueKey('configuration'),
              child: _ConfigurationContent(wide: wide),
            )
          : const KeyedSubtree(
              key: ValueKey('conversation'),
              child: ConversationPage(),
            ),
    );

    if (!wide) {
      return Scaffold(
        backgroundColor: Theme.of(context).colorScheme.surfaceContainer,
        body: SafeArea(
          child: Column(
            children: [
              Expanded(child: content),
              NavigationBar(
                selectedIndex: _selected,
                onDestinationSelected: (i) => setState(() => _selected = i),
                destinations: const [
                  NavigationDestination(
                    icon: Icon(Icons.tune_outlined),
                    selectedIcon: Icon(Icons.tune_rounded),
                    label: 'Configuration',
                  ),
                  NavigationDestination(
                    icon: Icon(Icons.chat_bubble_outline),
                    selectedIcon: Icon(Icons.chat_bubble),
                    label: 'Conversation',
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.surfaceContainer,
      body: SafeArea(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _SideNavigation(
              selected: _selected,
              onSelect: (i) => setState(() => _selected = i),
            ),
            Expanded(
              child: ClipRRect(
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(14),
                ),
                child: ColoredBox(
                  color: Theme.of(context).colorScheme.surface,
                  child: content,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SideNavigation extends StatelessWidget {
  const _SideNavigation({required this.selected, required this.onSelect});

  final int selected;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    // Icon-only dock on the recessed shell tier; the content sheet's rounded
    // shoulder does the separating, so the rail paints no edge of its own.
    return SizedBox(
      width: 72,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 20, 4, 16),
        child: NavigationRail(
          backgroundColor: Colors.transparent,
          minWidth: 64,
          selectedIndex: selected,
          onDestinationSelected: onSelect,
          destinations: const [
            NavigationRailDestination(
              icon: Icon(Icons.tune_outlined),
              selectedIcon: Icon(Icons.tune_rounded),
              label: Text('Configuration'),
            ),
            NavigationRailDestination(
              icon: Icon(Icons.chat_bubble_outline),
              selectedIcon: Icon(Icons.chat_bubble),
              label: Text('Conversation'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ConfigurationContent extends StatefulWidget {
  const _ConfigurationContent({required this.wide});

  final bool wide;

  @override
  State<_ConfigurationContent> createState() => _ConfigurationContentState();
}

class _PetAffectionCard extends StatefulWidget {
  const _PetAffectionCard({required this.petId, required this.petName});

  final String petId;
  final String petName;

  @override
  State<_PetAffectionCard> createState() => _PetAffectionCardState();
}

class _PetAffectionCardState extends State<_PetAffectionCard> {
  final _personality = const PersonalityCoreService();
  PetAffection? _affection;
  bool _busy = true;
  bool _failed = false;
  bool _resetting = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _busy = true;
      _failed = false;
    });
    try {
      final affection = await _personality.getPetAffection(agentId: widget.petId);
      if (mounted) setState(() => _affection = affection);
    } on PersonalityCoreException {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _resetMemories() async {
    setState(() => _resetting = true);
    try {
      await _personality.deleteAgentMemories(agentId: widget.petId);
      await _load();
    } on PersonalityCoreException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not reset memories: ${error.message}')),
        );
      }
    } finally {
      if (mounted) setState(() => _resetting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final affection = _affection;

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 16, 16),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.petName,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 8),
                  if (_busy)
                    const LinearProgressIndicator(minHeight: 6)
                  else if (_failed)
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Could not load affection.',
                            style: theme.textTheme.bodySmall,
                          ),
                        ),
                        TextButton(
                          onPressed: _load,
                          child: const Text('Retry'),
                        ),
                      ],
                    )
                  else if (affection == null)
                    Text(
                      'No bond yet. Open the pet and say hello to start one.',
                      style: theme.textTheme.bodySmall,
                    )
                  else
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _AffectionMeter(fraction: affection.fraction),
                        const SizedBox(height: 6),
                        Row(
                          children: [
                            Text(
                              '${affection.affection}/100 · ${affection.level}',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: cs.onSurfaceVariant,
                              ),
                            ),
                            if (affection.reason != null) ...[
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  affection.reason!,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.bodySmall,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ],
                    ),
                ],
              ),
            ),
            if (!_busy && affection != null)
              TextButton.icon(
                onPressed: _resetting ? null : _resetMemories,
                icon: _resetting
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.delete_sweep_outlined, size: 16),
                label: const Text('Reset'),
                style: TextButton.styleFrom(
                  foregroundColor: cs.onSurfaceVariant,
                  textStyle: const TextStyle(fontSize: 12),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// A quiet progress bar for affection. Tone marks the bond level; the label
/// carries the exact number. No animation beyond the filled width.
class _AffectionMeter extends StatelessWidget {
  const _AffectionMeter({required this.fraction});

  final double fraction;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: LinearProgressIndicator(
        value: fraction,
        minHeight: 6,
        backgroundColor: cs.surfaceContainerHighest,
        valueColor: AlwaysStoppedAnimation<Color>(cs.primary),
      ),
    );
  }
}

class _PetLoadError extends StatelessWidget {
  const _PetLoadError({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 16, 16),
        child: Row(
          children: [
            Expanded(
              child: Text(
                'Could not load companions.',
                style: theme.textTheme.bodySmall,
              ),
            ),
            TextButton(onPressed: onRetry, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }
}

class _PetEmpty extends StatelessWidget {
  const _PetEmpty();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Text(
          'No pet agents on your account yet. Add a pet-capable agent to '
          'Personality Core to see it here.',
          style: theme.textTheme.bodySmall,
        ),
      ),
    );
  }
}
class _PetSignInHint extends StatelessWidget {
  const _PetSignInHint();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Text(
          'Sign in above to see your pets and their bond with you.',
          style: theme.textTheme.bodySmall,
        ),
      ),
    );
  }
}

class _ConfigurationContentState extends State<_ConfigurationContent> {
  final _personality = const PersonalityCoreService();
  List<PersonalityAgent> _pets = const [];
  bool _petsBusy = false;
  bool _petsFailed = false;

  bool _signedIn = false;

  @override
  void initState() {
    super.initState();
    _checkAuth();
  }

  Future<void> _checkAuth() async {
    // Pets are per-account; only reach the network once a session exists.
    // This also keeps the signed-out dashboard quiet in tests.
    String? token;
    try {
      token = await SolarAuthService().accessToken();
    } on SolarAuthException {
      token = null;
    }
    if (mounted) setState(() => _signedIn = token != null);
    if (token != null) _loadPets();
  }

  Future<void> _loadPets() async {
    setState(() {
      _petsBusy = true;
      _petsFailed = false;
    });
    try {
      final pets = await _personality.listAgents();
      if (mounted) setState(() => _pets = pets);
    } on PersonalityCoreException {
      if (mounted) setState(() => _petsFailed = true);
    } finally {
      if (mounted) setState(() => _petsBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final wide = widget.wide;
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(wide ? 32 : 20, 28, wide ? 40 : 20, 32),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                runSpacing: 12,
                children: [
                  Text(
                    'Configuration',
                    style: theme.textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  FilledButton.icon(
                    onPressed: DesktopWindowService.openPetWindow,
                    icon: const Icon(Icons.pets_outlined),
                    label: const Text('Show pet'),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              const _AccountCard(),
              const SizedBox(height: 16),
              Text(
                'Companions',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 10),
              if (!_signedIn)
                const _PetSignInHint()
              else if (_petsBusy)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 24),
                  child: Center(
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              else if (_petsFailed)
                _PetLoadError(onRetry: _loadPets)
              else if (_pets.isEmpty)
                const _PetEmpty()
              else ...[
                for (final pet in _pets) ...[
                  _PetAffectionCard(petId: pet.id, petName: pet.displayName),
                  const SizedBox(height: 10),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _AccountCard extends StatefulWidget {
  const _AccountCard();

  @override
  State<_AccountCard> createState() => _AccountCardState();
}

class _AccountCardState extends State<_AccountCard> {
  final _auth = SolarAuthService();
  SolarUser? _user;
  bool _authBusy = false;
  String? _authError;

  @override
  void initState() {
    super.initState();
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final signedIn = _user != null;

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
        child: Row(
          children: [
            Icon(
              signedIn
                  ? Icons.account_circle_rounded
                  : Icons.account_circle_outlined,
              size: 28,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    signedIn ? (_user!.name) : 'Solar Network',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    signedIn
                        ? (_user!.handle.isEmpty
                              ? 'Signed in'
                              : '@${_user!.handle}')
                        : (_authError ?? 'Sign in to connect Personality Core'),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: _authError == null
                          ? theme.colorScheme.onSurfaceVariant
                          : theme.colorScheme.error,
                    ),
                  ),
                ],
              ),
            ),
            if (!signedIn)
              _authBusy
                  ? const SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : FilledButton(
                      onPressed: _signIn,
                      child: const Text('Sign in'),
                    ),
          ],
        ),
      ),
    );
  }
}
