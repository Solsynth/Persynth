import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:persynth/personality/insight_chat_controller.dart';
import 'package:persynth/personality/local_tool.dart';
import 'package:persynth/personality/personality_api.dart';
import 'package:persynth/personality/personality_network.dart';
import 'package:persynth/plugins/plugin_registry.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _agent = SnPersonalityAgent(id: 'a1', name: 'Michan', enabled: true);

Stream<List<int>> _bytes(List<String> chunks) =>
    Stream.fromIterable(chunks.map(utf8.encode));

/// Streams one finished turn and answers the conversation total, recording
/// what the controller asked of it.
class _UsageApi extends PersonalityApi {
  _UsageApi({this.usage, this.reportedUsage}) : super(Dio());

  /// What the run reports on `run.completed`.
  final SnRunUsage? usage;

  /// What the conversation usage endpoint answers with.
  final SnConversationUsage? reportedUsage;

  int usageRequests = 0;
  String? usageConversationId;

  @override
  Future<String> createConversation({
    required String agentId,
    String title = '',
  }) async => 'conv-usage';

  @override
  Stream<PersonalityRunEvent> runConversation({
    required String conversationId,
    required String message,
    List<String> attachmentIds = const [],
    List<SnRunInputPart> inputParts = const [],
    List<SnLocalTool> clientTools = const [],
    List<SnClientSkill> clientSkills = const [],
    List<String> overrides = const [],
    List<String> context = const [],
    String? reasoningEffort,
    bool disableReasoning = false,
    CancelToken? cancelToken,
  }) async* {
    yield const PersonalityMessageDelta('Paris.');
    yield const PersonalityRunCompleted('Paris.');
    final reported = usage;
    if (reported != null) {
      yield PersonalityUsageReported(reported);
    }
  }

  @override
  Future<SnConversationUsage> conversationUsage(String conversationId) async {
    usageRequests++;
    usageConversationId = conversationId;
    return reportedUsage ??
        const SnConversationUsage(
          runs: 0,
          inputTokens: 0,
          outputTokens: 0,
          totalTokens: 0,
        );
  }
}

ProviderContainer _container(SharedPreferences prefs, _UsageApi api) {
  return ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      personalityApiProvider.overrideWithValue(api),
      personalityAgentsProvider.overrideWith((ref) async => [_agent]),
      pluginToolsProvider.overrideWithValue(const <SnLocalTool>[]),
    ],
  );
}

Future<(ProviderContainer, InsightChatController)> _launch(_UsageApi api) async {
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

  group('SnRunUsage', () {
    test('reads a summed run with a known context window', () {
      final usage = SnRunUsage.fromJson({
        'input_tokens': 1005,
        'output_tokens': 507,
        'total_tokens': 1512,
        'rounds': 2,
        'context': {
          'used_tokens': 1000,
          'window_tokens': 128000,
          'used_ratio': 0.007813,
        },
      });

      expect(usage, isNotNull);
      expect(usage!.inputTokens, 1005);
      expect(usage.outputTokens, 507);
      expect(usage.totalTokens, 1512);
      expect(usage.rounds, 2);
      expect(usage.contextUsedTokens, 1000);
      expect(usage.contextWindowTokens, 128000);
      expect(usage.contextUsedRatio, closeTo(0.007813, 1e-9));
      expect(usage.hasContextWindow, isTrue);
    });

    test('keeps the prompt size when the window is unknown', () {
      final usage = SnRunUsage.fromJson({
        'input_tokens': 40,
        'output_tokens': 6,
        'total_tokens': 46,
        'rounds': 1,
        'context': {'used_tokens': 40},
      });

      expect(usage!.contextUsedTokens, 40);
      expect(usage.contextWindowTokens, isNull);
      expect(usage.contextUsedRatio, isNull);
      expect(usage.hasContextWindow, isFalse);
    });

    test('derives a total when the provider omitted one', () {
      final usage = SnRunUsage.fromJson({
        'input_tokens': 7,
        'output_tokens': 3,
        'rounds': 1,
      });
      expect(usage!.totalTokens, 10);
    });

    test('an empty payload is no usage rather than zeros', () {
      // A run the provider reported nothing for stores `{}`, so the reply must
      // render no footer instead of a "0 tokens" one.
      expect(SnRunUsage.fromJson(const <String, dynamic>{}), isNull);
      expect(SnRunUsage.fromJson({'rounds': 0}), isNull);
      expect(SnRunUsage.fromJson(null), isNull);
      expect(SnRunUsage.fromJson('nonsense'), isNull);
    });
  });

  test('SnConversationUsage reads the account total', () {
    final usage = SnConversationUsage.fromJson({
      'runs': 12,
      'input_tokens': 48210,
      'output_tokens': 9310,
      'total_tokens': 57520,
      'peak_context_used_tokens': 7204,
      'context_window_tokens': 128000,
    });

    expect(usage.runs, 12);
    expect(usage.totalTokens, 57520);
    expect(usage.peakContextUsedTokens, 7204);
    expect(usage.contextWindowTokens, 128000);
  });

  group('run.completed parsing', () {
    test('carries the usage the finished run reported', () async {
      final events = await parsePersonalityRunEvents(
        _bytes([
          'event: message.completed\ndata: {"content":"Paris."}\n\n',
          'event: run.completed\n'
              'data: {"run_id":"r1","message_id":"m1","usage":{"input_tokens":40,'
              '"output_tokens":6,"total_tokens":46,"rounds":1,'
              '"context":{"used_tokens":40,"window_tokens":32768,"used_ratio":0.001221}}}\n\n',
        ]),
      ).toList();

      expect(events, hasLength(2));
      expect((events[0] as PersonalityRunCompleted).content, 'Paris.');
      final reported = events[1] as PersonalityUsageReported;
      expect(reported.usage.totalTokens, 46);
      expect(reported.usage.contextWindowTokens, 32768);
    });

    test('drops a run.completed that reported no tokens', () async {
      final events = await parsePersonalityRunEvents(
        _bytes(['event: run.completed\ndata: {"usage":{}}\n\n']),
      ).toList();
      expect(events, isEmpty);
    });
  });

  test('attaches a turn\'s usage to its reply and refreshes the total', () async {
    const turnUsage = SnRunUsage(
      inputTokens: 40,
      outputTokens: 6,
      totalTokens: 46,
      rounds: 1,
      contextUsedTokens: 40,
      contextWindowTokens: 32768,
      contextUsedRatio: 0.001221,
    );
    const total = SnConversationUsage(
      runs: 1,
      inputTokens: 40,
      outputTokens: 6,
      totalTokens: 46,
      peakContextUsedTokens: 40,
      contextWindowTokens: 32768,
    );
    final api = _UsageApi(usage: turnUsage, reportedUsage: total);
    final (container, controller) = await _launch(api);

    await controller.send('capital of France?');

    final chat = container.read(insightChatControllerProvider);
    final assistant = chat.bubbles.lastWhere(
      (b) => b.kind == InsightBubbleKind.assistant,
    );
    expect(assistant.usage, isNotNull);
    expect(assistant.usage!.totalTokens, 46);
    expect(assistant.usage!.contextWindowTokens, 32768);

    // The total is read from the server, not accumulated locally, so every
    // client shows the same number.
    expect(api.usageRequests, greaterThan(0));
    expect(api.usageConversationId, 'conv-usage');
    expect(chat.conversationUsage, isNotNull);
    expect(chat.conversationUsage!.totalTokens, 46);
    expect(chat.conversationUsage!.runs, 1);
  });

  test('a run that reports nothing leaves the reply without a footer', () async {
    final api = _UsageApi();
    final (container, controller) = await _launch(api);

    await controller.send('hello');

    final chat = container.read(insightChatControllerProvider);
    final assistant = chat.bubbles.lastWhere(
      (b) => b.kind == InsightBubbleKind.assistant,
    );
    expect(assistant.usage, isNull);
  });
}
