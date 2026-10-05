import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:persynth/personality/personality_network.dart';

/// How much the companion should reason before answering.
///
/// The run request carries two independent reasoning controls and this is one
/// choice covering both: an effort level, which the backend forwards to the
/// provider verbatim, or [off], which turns the provider's thinking mode off
/// outright. The levels are the union of what the supported providers
/// document, not a set every model accepts — a model handed one it does not
/// know refuses the turn in its own words.
///
/// The composer's pill offers the three a reader can hold in mind — [low],
/// [medium] and [high] — and leaves the rest to what is already stored: this
/// enum is the store's vocabulary as well as the wire's, so a level a build
/// once wrote still reads back as itself rather than as the default.
enum ReasoningSetting {
  modelDefault('default', 'Model default', null, false),
  off('off', 'Off (no thinking)', null, true),
  minimal('minimal', 'Minimal', 'minimal', false),
  low('low', 'Low', 'low', false),
  medium('medium', 'Medium', 'medium', false),
  high('high', 'High', 'high', false),
  xhigh('xhigh', 'Extra high', 'xhigh', false),
  max('max', 'Max', 'max', false),
  ultra('ultra', 'Ultra', 'ultra', false);

  const ReasoningSetting(
    this.token,
    this.label,
    this.effort,
    this.disabled,
  );

  /// Stable name the choice is stored under. Kept apart from [label] so the
  /// wording can change without orphaning what is already on disk.
  final String token;

  /// What the picker shows.
  final String label;

  /// The `reasoning_effort` to send, or null to leave the request without one.
  final String? effort;

  /// Whether to send the run's `disable_reasoning` switch.
  final bool disabled;

  /// The run's `disable_reasoning` switch as the wire carries it: true turns
  /// thinking off, false is an explicit "reason — the level I named" that
  /// overrides an agent shipped with thinking disabled, and null leaves the
  /// agent's own setting in charge.
  ///
  /// An effort without this would be a request the server drops on any agent
  /// whose config disables thinking, so the pill would read as a control that
  /// does nothing.
  bool? get disableReasoning =>
      disabled ? true : (effort == null ? null : false);

  /// Reads a stored token back, treating anything unrecognized — including a
  /// level a newer build knows and this one does not — as the default. A
  /// half-remembered setting is worse than an explicit one.
  static ReasoningSetting fromToken(String? token) {
    for (final setting in values) {
      if (setting.token == token) return setting;
    }
    return ReasoningSetting.modelDefault;
  }
}

/// SharedPreferences key holding the chosen reasoning setting.
const kReasoningSettingStoreKey = 'persynth_reasoning_setting';

/// The reasoning preference, persisted across launches and sent with every
/// run. A run cannot change it midway — the server reads the controls when the
/// run starts — so this is a standing choice, not a per-message one.
class ReasoningSettingNotifier extends Notifier<ReasoningSetting> {
  @override
  ReasoningSetting build() {
    final stored = ref.watch(
      sharedPreferencesProvider.select(
        (prefs) => prefs.getString(kReasoningSettingStoreKey),
      ),
    );
    return ReasoningSetting.fromToken(stored);
  }

  Future<void> set(ReasoningSetting setting) async {
    state = setting;
    await ref
        .read(sharedPreferencesProvider)
        .setString(kReasoningSettingStoreKey, setting.token);
  }
}

final reasoningSettingProvider =
    NotifierProvider<ReasoningSettingNotifier, ReasoningSetting>(
      ReasoningSettingNotifier.new,
    );
