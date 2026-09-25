import 'package:dio/dio.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:persynth/personality/local_tool.dart';
import 'package:persynth/personality/local_web_tools.dart';
import 'package:persynth/personality/mcp_device_tools.dart';
import 'package:persynth/personality/personality_network.dart';

/// SharedPreferences key for the web tool set (`web_search_local`,
/// `web_fetch_local`).
const kLocalWebToolsStoreKey = 'persynth_local_tools_web';

/// SharedPreferences key for the device tool set (`mcp_read_file`,
/// `mcp_list_dir`, `mcp_run_command`).
const kLocalDeviceToolsStoreKey = 'persynth_local_tools_device';

/// Which on-device tool sets are switched on.
///
/// The web set is on by default: it only makes requests the server would have
/// made anyway, merely from the user's own connection. The device set is off
/// by default and stays off until the user turns it on — it reads this
/// machine's files and runs shell commands (through the MCP daemon), which is
/// not something to grant on someone's behalf.
class LocalToolSettings {
  const LocalToolSettings({required this.web, required this.device});

  final bool web;
  final bool device;

  /// True when at least one set is on, i.e. the model is offered local tools.
  bool get any => web || device;

  LocalToolSettings copyWith({bool? web, bool? device}) => LocalToolSettings(
    web: web ?? this.web,
    device: device ?? this.device,
  );

  @override
  bool operator ==(Object other) =>
      other is LocalToolSettings && other.web == web && other.device == device;

  @override
  int get hashCode => Object.hash(web, device);
}

/// The tool-set switches, persisted across launches.
class LocalToolSettingsNotifier extends Notifier<LocalToolSettings> {
  @override
  LocalToolSettings build() {
    final prefs = ref.watch(sharedPreferencesProvider);
    return LocalToolSettings(
      web: prefs.getBool(kLocalWebToolsStoreKey) ?? true,
      device: prefs.getBool(kLocalDeviceToolsStoreKey) ?? false,
    );
  }

  Future<void> setWeb(bool enabled) => _set(state.copyWith(web: enabled));

  Future<void> setDevice(bool enabled) => _set(state.copyWith(device: enabled));

  Future<void> _set(LocalToolSettings next) async {
    state = next;
    final prefs = ref.read(sharedPreferencesProvider);
    await prefs.setBool(kLocalWebToolsStoreKey, next.web);
    await prefs.setBool(kLocalDeviceToolsStoreKey, next.device);
  }
}

final localToolSettingsProvider =
    NotifierProvider<LocalToolSettingsNotifier, LocalToolSettings>(
      LocalToolSettingsNotifier.new,
    );

/// Every enabled local tool, in the order the model sees them: the web set
/// first, then the MCP device set.
///
/// Anything switched off is absent from the list, so the model is never told
/// the tool exists — switching a set off is a capability boundary, not a
/// refusal the model could talk its way past.
final localToolsProvider = Provider<List<SnLocalTool>>((ref) {
  final settings = ref.watch(localToolSettingsProvider);
  return [
    // A bare client: web traffic must not carry the app's Authorization
    // header, so search-engine requests leave without the account token.
    if (settings.web) ...buildLocalWebTools(Dio()),
    if (settings.device) ...ref.watch(mcpDeviceToolsProvider),
  ];
});
