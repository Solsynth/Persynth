import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:persynth/personality/local_tool.dart';
import 'package:persynth/personality/mcp_client.dart';
import 'package:persynth/personality/personality_network.dart';
import 'package:persynth/plugins/device_tools_plugin.dart';
import 'package:persynth/plugins/plugin.dart';
import 'package:persynth/plugins/plugin_registry.dart';
import 'package:persynth/plugins/web_tools_plugin.dart';

/// A plugin that exists only in the test: proof that a capability added to the
/// registry is offered, loadable and explained without anything else changing.
class _EchoPlugin extends SnPlugin {
  const _EchoPlugin();

  @override
  String get id => 'echo';

  @override
  String get label => 'Echo';

  @override
  String get description => 'Repeats what it is given.';

  @override
  String get summary => 'Repeat text back';

  @override
  bool get onDemand => true;

  @override
  List<SnLocalTool> buildTools(SnPluginContext context) => [
    SnLocalTool(
      name: 'echo',
      description: 'Repeat the text.',
      parameters: const {
        'type': 'object',
        'properties': {
          'text': {'type': 'string'},
        },
        'required': ['text'],
      },
      execute: (arguments) async => '${arguments['text']}',
    ),
  ];

  @override
  List<String> systemPrompt(SnPluginContext context) => const [
    'An echo tool is loaded.',
  ];
}

/// The wired names the model would be offered.
List<String> _names(ProviderContainer container) =>
    container.read(pluginToolsProvider).map((tool) => tool.name).toList();

Future<ProviderContainer> _launch([
  Map<String, Object> stored = const {},
  List<SnPlugin>? registry,
]) async {
  SharedPreferences.setMockInitialValues(stored);
  return _containerWith(await SharedPreferences.getInstance(), registry);
}

/// A container over an already-loaded preferences instance, which is what a
/// relaunch looks like: same stored switches, no app in between.
ProviderContainer _containerWith(
  SharedPreferences preferences,
  List<SnPlugin>? registry,
) {
  final container = ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(preferences),
      if (registry != null) pluginRegistryProvider.overrideWithValue(registry),
      // The device plugin's tools are built from the daemon gateway; nothing
      // here starts one, because nothing here calls a tool through it.
      pluginContextProvider.overrideWith(
        (ref) => SnPluginContext(
          api: ref.watch(personalityApiClientProvider),
          http: ref.watch(pluginHttpClientProvider),
          mcp: _UnreachableGateway(),
        ),
      ),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

/// Answers nothing, so a test that reaches the daemon fails loudly rather than
/// hanging.
class _UnreachableGateway implements McpGateway {
  @override
  Future<List<McpDaemonTool>> listTools() async => const [];

  @override
  Future<String> callTool(String name, Map<String, dynamic> arguments) async =>
      throw StateError('the test gateway must not be called');

  @override
  void dispose() {}
}

/// Runs the activation tool the registry advertises, by the name the model
/// calls it under.
Future<String> _load(ProviderContainer container, String skillName) async {
  final tool = container
      .read(pluginToolsProvider)
      .firstWhere((tool) => tool.name == loadSkillToolName);
  return tool.execute({'skill': namespacedToolName(skillName)});
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('offers the web tools by default and holds the device set back', () async {
    final container = await _launch();

    expect(_names(container), ['web_search', 'web_fetch']);
    expect(container.read(pluginSkillsProvider), isEmpty);
  });

  test('an on-demand plugin costs one definition until it is loaded', () async {
    final container = await _launch();
    await container
        .read(pluginEnablementProvider.notifier)
        .setEnabled('device', true);

    // The device tools are not offered — only the way to load them, and the
    // name the model would ask for.
    expect(_names(container), ['web_search', 'web_fetch', loadSkillToolName]);
    expect(container.read(pluginSkillsProvider).map((skill) => skill.name), [
      'device',
    ]);

    final loaded = await _load(container, 'device');
    expect(loaded, contains('"ok":true'));

    // Loading is what puts them on the run, in registry order, with the
    // activation tool gone because nothing is left to load.
    expect(_names(container), [
      'web_search',
      'web_fetch',
      'read_file',
      'list_dir',
      'run_command',
    ]);
    expect(container.read(pluginSkillsProvider), isEmpty);
  });

  test('a loaded plugin contributes its prompt text, an unloaded one does not', () async {
    final container = await _launch();

    expect(container.read(pluginSystemPromptProvider).length, 1);
    expect(
      container.read(pluginSystemPromptProvider).single,
      contains('local_web_search'),
    );

    await container
        .read(pluginEnablementProvider.notifier)
        .setEnabled('device', true);
    expect(
      container.read(pluginSystemPromptProvider).length,
      1,
      reason: 'an unloaded plugin has said nothing yet',
    );

    await _load(container, 'device');
    final fragments = container.read(pluginSystemPromptProvider);
    expect(fragments.length, 2);
    expect(fragments.last, contains('local_run_command'));
  });

  test('an unknown skill is answered with what can be loaded', () async {
    final container = await _launch();
    await container
        .read(pluginEnablementProvider.notifier)
        .setEnabled('device', true);

    final answer = await _load(container, 'nope');

    expect(answer, contains('"ok":false'));
    expect(answer, contains('local_device'));
  });

  test('switching a plugin off takes its tools off the run', () async {
    final container = await _launch();
    final enablement = container.read(pluginEnablementProvider.notifier);
    await enablement.setEnabled('device', true);
    await _load(container, 'device');
    expect(_names(container), contains('run_command'));

    await enablement.setEnabled('device', false);

    // The grant is withdrawn, not merely declined: the tools are no longer
    // offered at all, and the model is never told they exist.
    expect(_names(container), ['web_search', 'web_fetch']);
    expect(container.read(pluginSkillsProvider), isEmpty);
  });

  test('offers nothing at all when every switch is off', () async {
    final container = await _launch();
    final enablement = container.read(pluginEnablementProvider.notifier);
    await enablement.setEnabled('web', false);
    await enablement.setEnabled('device', false);

    expect(_names(container), isEmpty);
    expect(container.read(pluginSystemPromptProvider), isEmpty);
  });

  test('remembers the switches across launches', () async {
    final container = await _launch();
    await container
        .read(pluginEnablementProvider.notifier)
        .setEnabled('device', true);

    final preferences = container.read(sharedPreferencesProvider);
    expect(
      preferences.getBool(const DeviceToolsPlugin().storeKey),
      isTrue,
      reason: 'the switch must keep the key it has always used',
    );
    // The web plugin is on by default, so nothing has had to be stored for it.
    expect(preferences.getBool(const WebToolsPlugin().storeKey), isNull);

    // The next launch reads the same switches back.
    final relaunched = _containerWith(preferences, null);
    expect(relaunched.read(pluginEnablementProvider), contains('device'));
    expect(relaunched.read(pluginEnablementProvider), contains('web'));
  });

  test('ignores a switch left behind by an older build', () async {
    // The stored set only ever names plugins this build has, so a stale id
    // cannot grant anything.
    final container = await _launch({
      pluginStoreKey('removed_plugin'): true,
    });

    expect(container.read(pluginEnablementProvider), isNot(contains('removed_plugin')));
    expect(_names(container), ['web_search', 'web_fetch']);
  });

  test('a plugin added to the registry is offered and loadable', () async {
    final container = await _launch(const {}, const [WebToolsPlugin(), _EchoPlugin()]);

    // Its own switch key, its own label, and the model loads it by its own
    // name — no edit anywhere outside the plugin.
    expect(const _EchoPlugin().storeKey, pluginStoreKey('echo'));
    await container.read(pluginEnablementProvider.notifier).setEnabled('echo', true);
    expect(_names(container), ['web_search', 'web_fetch', loadSkillToolName]);

    await _load(container, 'echo');
    expect(_names(container), ['web_search', 'web_fetch', 'echo']);
    expect(container.read(pluginSystemPromptProvider).last, 'An echo tool is loaded.');

    final echo = container
        .read(pluginToolsProvider)
        .firstWhere((tool) => tool.name == 'echo');
    expect(await echo.execute({'text': 'hi'}), 'hi');
  });
}
