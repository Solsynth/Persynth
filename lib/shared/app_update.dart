import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:solsynth_express/solsynth_express.dart';

import 'package:persynth/personality/personality_network.dart';

/// Where Persynth's releases are published, and which product in that
/// installation they belong to.
///
/// Both are build-time values: the release workflow passes the same repository
/// variables to the build that it uploads the artifacts with, so one release
/// carries the address of the distribution it was published to. The base URL
/// has a default because the instance is the one the app already talks to for
/// everything else; the product id does not, because the package's default is
/// another app's — a build that was not handed an id checks nothing rather
/// than asking for someone else's releases.
const String kDistributionApiBaseUrl = String.fromEnvironment(
  'DISTRIBUTION_API_BASE_URL',
  defaultValue: kDefaultDistributionApiBaseUrl,
);

const String kDistributionProductId = String.fromEnvironment(
  'DISTRIBUTION_PRODUCT_ID',
);

/// SharedPreferences key holding whether the app asks for updates on launch.
const kUpdateChecksStoreKey = 'persynth_update_checks';

/// Whether the launch check runs. The manual check in settings ignores it:
/// the preference is about a request the user did not make.
class UpdateChecksEnabledNotifier extends Notifier<bool> {
  @override
  bool build() {
    final stored = ref.watch(
      sharedPreferencesProvider.select(
        (prefs) => prefs.getBool(kUpdateChecksStoreKey),
      ),
    );
    return stored ?? true;
  }

  Future<void> setEnabled(bool enabled) async {
    state = enabled;
    await ref
        .read(sharedPreferencesProvider)
        .setBool(kUpdateChecksStoreKey, enabled);
  }
}

final updateChecksEnabledProvider =
    NotifierProvider<UpdateChecksEnabledNotifier, bool>(
      UpdateChecksEnabledNotifier.new,
    );

/// The Solsynth Express client the app asks for releases with. Unconfigured in
/// a build without the defines above, which is what makes such a build check
/// silently instead of failing.
final updateServiceProvider = Provider<UpdateService>(
  (ref) => UpdateService(
    apiBaseUrl: kDistributionApiBaseUrl,
    productId: kDistributionProductId,
  ),
);

/// The installed build, for the settings row that names it. Null while the
/// platform channel is silent — a widget test, or a platform the plugin does
/// not cover — which the row draws as no version at all.
final packageInfoProvider = FutureProvider<PackageInfo?>((ref) async {
  try {
    return await PackageInfo.fromPlatform();
  } catch (_) {
    return null;
  }
});

/// Runs the launch update check once, after the first frame.
///
/// The sheet is pushed onto the root navigator and names its release in the
/// app's locale, so the check waits for a frame rather than racing the first
/// build. Wrapped around the main window only: the pet window is a second
/// engine of the same app, and one check per launch is what the preference
/// offers.
class UpdateCheckOnLaunch extends ConsumerStatefulWidget {
  const UpdateCheckOnLaunch({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<UpdateCheckOnLaunch> createState() =>
      _UpdateCheckOnLaunchState();
}

class _UpdateCheckOnLaunchState extends ConsumerState<UpdateCheckOnLaunch> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _check());
  }

  Future<void> _check() async {
    if (!mounted) return;
    if (!ref.read(updateChecksEnabledProvider)) return;
    await ref.read(updateServiceProvider).checkForUpdates(context);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
