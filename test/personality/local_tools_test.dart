import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:persynth/personality/local_tools.dart';
import 'package:persynth/personality/personality_network.dart';

/// The wired names of every tool the model would be offered.
List<String> _names(ProviderContainer container) =>
    container.read(localToolsProvider).map((tool) => tool.name).toList();

Future<ProviderContainer> _launch([Map<String, Object> stored = const {}]) async {
  SharedPreferences.setMockInitialValues(stored);
  final preferences = await SharedPreferences.getInstance();
  final container = ProviderContainer(
    overrides: [sharedPreferencesProvider.overrideWithValue(preferences)],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('offers the web set by default and keeps the device set back', () async {
    final container = await _launch();

    expect(container.read(localToolSettingsProvider).web, isTrue);
    expect(container.read(localToolSettingsProvider).device, isFalse);
    expect(_names(container), ['web_search_local', 'web_fetch_local']);
  });

  test('adds the device tools once their switch is on', () async {
    final container = await _launch();

    await container.read(localToolSettingsProvider.notifier).setDevice(true);

    expect(_names(container), [
      'web_search_local',
      'web_fetch_local',
      'mcp_read_file',
      'mcp_list_dir',
      'mcp_run_command',
    ]);
  });

  test('offers nothing at all when both switches are off', () async {
    final container = await _launch();

    final notifier = container.read(localToolSettingsProvider.notifier);
    await notifier.setWeb(false);
    await notifier.setDevice(false);

    expect(_names(container), isEmpty);
    expect(container.read(localToolSettingsProvider).any, isFalse);
  });

  test('remembers the switches across launches', () async {
    final container = await _launch();
    await container.read(localToolSettingsProvider.notifier).setDevice(true);

    final preferences = container.read(sharedPreferencesProvider);
    expect(preferences.getBool(kLocalDeviceToolsStoreKey), isTrue);
    expect(preferences.getBool(kLocalWebToolsStoreKey), isTrue);

    // The next launch reads the same switches back.
    final relaunched = ProviderContainer(
      overrides: [sharedPreferencesProvider.overrideWithValue(preferences)],
    );
    addTearDown(relaunched.dispose);

    expect(relaunched.read(localToolSettingsProvider).device, isTrue);
    expect(_names(relaunched), contains('mcp_run_command'));
  });
}
