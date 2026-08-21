import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';

import 'package:synth_pet/auth/solar_auth_service.dart';
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

class _ConfigurationContent extends StatelessWidget {
  const _ConfigurationContent({required this.wide});

  final bool wide;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
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
