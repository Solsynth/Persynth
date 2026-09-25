import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:persynth/personality/insight_chat_controller.dart';
import 'package:persynth/personality/local_tool.dart';
import 'package:persynth/personality/personality_api.dart';
import 'package:persynth/personality/personality_network.dart';
import 'package:persynth/personality/mcp_client.dart';
import 'package:persynth/plugins/plugin.dart';
import 'package:persynth/plugins/plugin_registry.dart';
import 'package:solar_network_sdk/solar_network_sdk.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _agent = SnPersonalityAgent(id: 'a1', name: 'Michan', enabled: true);

Future<String> _stubSearch(Map<String, dynamic> arguments) async =>
    'device result for ${arguments['query']}';

/// A tool as a plugin registers it: under the app's own name. The server is
/// what namespaces it, so nothing here mentions the namespace.
final _stubTool = SnLocalTool(
  name: 'web_search',
  description: 'Executes on this device in tests.',
  parameters: const {
    'type': 'object',
    'properties': {
      'query': {'type': 'string'},
    },
    'required': ['query'],
  },
  execute: _stubSearch,
);

/// Streams one client-tool handoff (optionally for an unknown tool) and then a
/// finished turn, recording what the controller asked the server to resume.
class _HandoffApi extends PersonalityApi {
  /// The name the model calls, which is the namespaced one.
  _HandoffApi({
    this.callName = 'local_web_search',
    this.callArguments = const {'query': 'duckdb'},
  }) : super(Dio());

  final String callName;
  final Map<String, dynamic> callArguments;
  List<SnLocalTool>? receivedClientTools;
  List<SnClientSkill>? receivedClientSkills;
  List<String>? receivedOverrides;
  List<String>? receivedContext;
  final List<(String, String, String, String)> resumed = [];
  final List<List<SnLocalTool>> resumedTools = [];
  final List<List<String>> resumedOverrides = [];

  @override
  Future<String> createConversation({
    required String agentId,
    String title = '',
  }) async => 'conv-h';

  @override
  Stream<PersonalityRunEvent> runConversation({
    required String conversationId,
    required String message,
    List<String> attachmentIds = const [],
    List<SnLocalTool> clientTools = const [],
    List<SnClientSkill> clientSkills = const [],
    List<String> overrides = const [],
    List<String> context = const [],
    CancelToken? cancelToken,
  }) async* {
    receivedClientTools = clientTools;
    receivedClientSkills = clientSkills;
    receivedOverrides = overrides;
    receivedContext = context;
    yield PersonalityToolCallClient(
      runId: 'run-1',
      id: 'call-local',
      name: callName,
      arguments: callArguments,
    );
    yield PersonalityToolCallCompleted(
      id: 'call-local',
      name: callName,
      arguments: callArguments,
      result: 'Local search via Bing — 1 result(s)',
    );
    yield const PersonalityMessageDelta('Found it.');
    yield const PersonalityRunCompleted('Found it.');
  }

  @override
  Future<void> submitClientToolResult({
    required String conversationId,
    required String runId,
    required String toolCallId,
    required String result,
    List<SnLocalTool> clientTools = const [],
    List<String> overrides = const [],
  }) async {
    resumed.add((conversationId, runId, toolCallId, result));
    resumedTools.add(clientTools);
    resumedOverrides.add(overrides);
  }
}

/// A container over the real registry, so a run can load a plugin for real
/// rather than through a stub tool list.
ProviderContainer _pluginContainer(SharedPreferences prefs, _HandoffApi api) {
  return ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      personalityApiProvider.overrideWithValue(api),
      personalityAgentsProvider.overrideWith((ref) async => [_agent]),
      pluginContextProvider.overrideWith(
        (ref) => SnPluginContext(
          api: ref.watch(personalityApiClientProvider),
          http: ref.watch(pluginHttpClientProvider),
          mcp: _NoDaemon(),
          solar: SolarNetworkClient.fromDio(
            ref.watch(personalityApiClientProvider),
          ),
        ),
      ),
    ],
  );
}

class _NoDaemon implements McpGateway {
  @override
  Future<List<McpDaemonTool>> listTools() async => const [];

  @override
  Future<String> callTool(String name, Map<String, dynamic> arguments) async =>
      throw StateError('no daemon in this test');

  @override
  void dispose() {}
}

ProviderContainer _container(SharedPreferences prefs, _HandoffApi api) {
  return ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      personalityApiProvider.overrideWithValue(api),
      personalityAgentsProvider.overrideWith((ref) async => [_agent]),
      pluginToolsProvider.overrideWithValue([_stubTool]),
    ],
  );
}

Future<(ProviderContainer, InsightChatController)> _launch(
  _HandoffApi api,
) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final container = _container(prefs, api);
  addTearDown(container.dispose);
  final controller = container.read(insightChatControllerProvider.notifier);
  controller.selectAgent('a1');
  return (container, controller);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
  });

  test('offers the on-device tools on every run', () async {
    final api = _HandoffApi();
    final (_, controller) = await _launch(api);

    await controller.send('hello');

    expect(api.receivedClientTools, isNotNull);
    expect(api.receivedClientTools!.map((tool) => tool.name), ['web_search']);
  });

  test('sends the loaded plugins\' prompt text as the run context', () async {
    final api = _HandoffApi();
    final (_, controller) = await _launch(api);

    await controller.send('hello');

    expect(api.receivedContext, isNotNull);
    expect(api.receivedContext!.single, contains('local_web_search'));
  });

  test('executes a client tool on this device and resumes the run', () async {
    final api = _HandoffApi();
    final (container, controller) = await _launch(api);

    await controller.send('search duckdb');

    expect(api.resumed, hasLength(1));
    final (conversationId, runId, toolCallId, result) = api.resumed.single;
    expect(conversationId, 'conv-h');
    expect(runId, 'run-1');
    expect(toolCallId, 'call-local');
    expect(result, 'device result for duckdb');
    // Nothing was loaded by that call, so the resume adds no tools.
    expect(api.resumedTools.single, isEmpty);

    // The trace renders and the server's completion finishes it.
    final state = container.read(insightChatControllerProvider);
    expect(state.bubbles.map((bubble) => bubble.kind).toList(), [
      InsightBubbleKind.user,
      InsightBubbleKind.tool,
      InsightBubbleKind.assistant,
    ]);
    final toolBubble = state.bubbles[1];
    expect(toolBubble.toolRunning, isFalse);
    expect(toolBubble.toolResult, 'Local search via Bing — 1 result(s)');
    expect(state.bubbles.last.text, 'Found it.');
  });

  test('a namespaced tool the app does not have becomes an error result', () async {
    final api = _HandoffApi(callName: '${kLocalToolNamespace}nope');
    final (_, controller) = await _launch(api);

    await controller.send('do the thing');

    expect(api.resumed, hasLength(1));
    expect(api.resumed.single.$4, contains('unknown tool'));
    expect(api.resumed.single.$4, contains('nope'));
  });

  test('a plugin loaded mid-run is handed to the server on resume', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    // The model loads the device set: the call arrives under the server's
    // namespace, and the skill is the one the registry advertises.
    final api = _HandoffApi(
      callName: '${kLocalToolNamespace}load_skill',
      callArguments: const {'skill': 'local_device'},
    );
    final container = _pluginContainer(prefs, api);
    addTearDown(container.dispose);
    await container
        .read(pluginEnablementProvider.notifier)
        .setEnabled('device', true);
    final controller = container.read(insightChatControllerProvider.notifier);
    controller.selectAgent('a1');

    // Before loading, the device tools are not offered at all.
    final offeredBefore = api.receivedClientTools;
    await controller.send('what is on this machine');

    expect(offeredBefore, isNull, reason: 'the fake answers only once');
    expect(
      api.receivedClientTools!.map((tool) => tool.name),
      contains(loadSkillToolName),
    );

    // Loading happened here, and the resume is what tells the server so: the
    // tools it just made callable ride with the result.
    expect(api.resumedTools, hasLength(1));
    expect(api.resumedTools.single.map((tool) => tool.name), [
      'read_file',
      'list_dir',
      'run_command',
    ]);
    expect(api.resumed.single.$4, contains('"ok":true'));
  });

  test('the run claims the server tools the loaded plugins replace', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    // A name the app does not have: this test is about what the run carries,
    // and the default call would otherwise run a real search.
    final api = _HandoffApi(callName: '${kLocalToolNamespace}nope');
    final container = _pluginContainer(prefs, api);
    addTearDown(container.dispose);
    final controller = container.read(insightChatControllerProvider.notifier);
    controller.selectAgent('a1');

    await controller.send('anything');

    // The web set is loaded out of the box, so the very first run already
    // replaces the server's own search and page reader.
    expect(api.receivedOverrides, ['read_webpage', 'web_search']);
  });

  test('a capability loaded mid-run hands its replacements over with it', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final api = _HandoffApi(
      callName: '${kLocalToolNamespace}load_skill',
      callArguments: const {'skill': 'social'},
    );
    final container = _pluginContainer(prefs, api);
    addTearDown(container.dispose);
    await container
        .read(pluginEnablementProvider.notifier)
        .setEnabled('social', true);
    final controller = container.read(insightChatControllerProvider.notifier);
    controller.selectAgent('a1');

    await controller.send('what is happening');

    // Enabled is not loaded: the tools were not on this run, so neither were
    // the replacements, and the server kept its own copies.
    expect(api.receivedOverrides, ['read_webpage', 'web_search']);

    // Loading is what moves the job — the resume drops the server's post
    // tools in the same step that it adds the local ones.
    expect(api.resumedOverrides.single, [
      'create_post',
      'get_post',
      'get_post_replies',
      'list_feed',
      'list_post_replies',
      'list_user_posts',
      'react_to_post',
      'reply_to_post',
      'search_posts',
    ]);
  });

  test('a server-owned name is never treated as a client tool', () async {
    // The namespace is the whole of the routing decision: a call without it
    // belongs to the server, so the app must not answer it.
    final api = _HandoffApi(callName: 'web_search');
    final (_, controller) = await _launch(api);

    await controller.send('look it up');

    expect(api.resumed, hasLength(1));
    expect(api.resumed.single.$4, contains('unknown tool'));
  });
}
