import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:persynth/personality/insight_chat_controller.dart';
import 'package:persynth/personality/local_tool.dart';
import 'package:persynth/personality/personality_api.dart';
import 'package:persynth/personality/personality_network.dart';

const _agent = SnPersonalityAgent(id: 'a1', name: 'Michan', enabled: true);

/// A turn whose events the test pushes one at a time, so the log can be read
/// mid-stream rather than only once the turn settled.
class _ScriptedApi extends PersonalityApi {
  _ScriptedApi() : super(Dio());

  StreamController<PersonalityRunEvent> events = StreamController();

  @override
  Future<String> createConversation({
    required String agentId,
    String title = '',
  }) async => 'c1';

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
  }) => events.stream;
}

/// Lets the controller drain whatever was just pushed into the stream.
Future<void> _settle() => Future<void>.delayed(const Duration(milliseconds: 10));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _ScriptedApi api;
  late ProviderContainer container;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    api = _ScriptedApi();
    container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(preferences),
        personalityApiProvider.overrideWithValue(api),
        personalityAgentsProvider.overrideWith((ref) async => [_agent]),
      ],
    );
    // The controller is auto-dispose: without a listener the container throws
    // the instance away between awaits, exactly as a popped page would.
    container.listen(insightChatControllerProvider, (_, _) {});
    container.read(insightChatControllerProvider);
  });

  tearDown(() {
    if (!api.events.isClosed) api.events.close();
    container.dispose();
  });

  List<InsightBubble> thoughts() => container
      .read(insightChatControllerProvider)
      .bubbles
      .where((bubble) => bubble.kind == InsightBubbleKind.thinking)
      .toList();

  test('a new thought opens where the trace above it sits', () async {
    final controller = container.read(insightChatControllerProvider.notifier);
    controller.selectAgent('a1');
    final pending = controller.send('hi');

    api.events.add(const PersonalityReasoningDelta('first thought'));
    await _settle();
    api.events.add(
      const PersonalityToolCallStarted(
        id: 'c1',
        name: 'search',
        arguments: {'q': 'x'},
      ),
    );
    api.events.add(
      const PersonalityToolCallCompleted(
        id: 'c1',
        name: 'search',
        arguments: {'q': 'x'},
        result: 'ok',
      ),
    );
    await _settle();
    api.events.add(const PersonalityReasoningDelta('second thought'));
    await _settle();

    final streamed = thoughts();
    expect(streamed.map((bubble) => bubble.text).toList(), [
      'first thought',
      'second thought',
    ]);
    // Nothing above the first thought of a turn, so it streams open.
    expect(streamed.first.collapsed, isFalse);
    // The trace above the second is a settled row: folded, so it stays folded.
    expect(streamed.last.streaming, isTrue);
    expect(streamed.last.collapsed, isTrue);

    api.events.add(const PersonalityRunCompleted('done'));
    // Closing is not awaited: a single-subscription controller only reports
    // `done` once the stream has a listener, and `send` is that listener.
    api.events.close();
    await pending;

    expect(thoughts().last.collapsed, isTrue);
  });

  test('a thought the reader opened keeps the next one open', () async {
    final notifier = container.read(insightChatControllerProvider.notifier);
    notifier.selectAgent('a1');

    final firstTurn = notifier.send('hi');
    api.events.add(const PersonalityReasoningDelta('first thought'));
    api.events.add(const PersonalityRunCompleted('done'));
    api.events.close();
    await firstTurn;

    // The reader taps the folded thought open.
    final index = container
        .read(insightChatControllerProvider)
        .bubbles
        .indexWhere((bubble) => bubble.kind == InsightBubbleKind.thinking);
    expect(index, isNonNegative);
    notifier.toggleTrace(index);
    final opened = container.read(insightChatControllerProvider).bubbles[index];
    expect(opened.collapsed, isFalse);

    api.events = StreamController();
    final secondTurn = notifier.send('again');
    api.events.add(const PersonalityReasoningDelta('second thought'));
    api.events.add(const PersonalityRunCompleted('done'));
    api.events.close();
    await secondTurn;

    // The next thought arrives as the reader left the last one — and the fold
    // that settles a finished turn leaves a row the reader pinned alone.
    final streamed = thoughts();
    expect(streamed.length, 2);
    expect(streamed.last.collapsed, isFalse);
    expect(streamed.last.touched, isTrue);
  });
}
