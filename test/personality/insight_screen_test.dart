import 'package:auto_route/auto_route.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:persynth/auth/solar_auth_controller.dart';
import 'package:persynth/auth/solar_auth_service.dart';
import 'package:persynth/personality/local_tool.dart';
import 'package:persynth/personality/personality_api.dart';
import 'package:persynth/personality/personality_network.dart';
import 'package:persynth/personality/reasoning_settings.dart';
import 'package:persynth/router.dart';
import 'package:persynth/screens/settings_page.dart';
import 'package:persynth/theme/app_theme.dart';

const _agent = SnPersonalityAgent(id: 'a1', name: 'Michan', enabled: true);

class _FakePersonalityApi extends PersonalityApi {
  _FakePersonalityApi({
    this.reply = const [],
    this.history = const [],
    this.usageTotal,
    this.failure,
  }) : super(Dio());

  final List<PersonalityRunEvent> reply;
  final List<SnPersonalityMessage> history;

  /// What the conversation total endpoint answers with. Null stands for a
  /// server that has nothing to report yet.
  final SnConversationUsage? usageTotal;

  @override
  Future<SnConversationUsage> conversationUsage(String conversationId) async {
    final usage = usageTotal;
    if (usage == null) throw StateError('no usage to report');
    return usage;
  }

  /// When set, a run fails with it instead of streaming [reply].
  final Object? failure;

  final List<String> sentMessages = [];
  final List<List<String>> sentAttachments = [];
  final List<List<SnRunInputPart>> sentInputParts = [];
  List<SnLocalTool> lastClientTools = const [];

  @override
  Future<List<SnPersonalityConversation>> listConversations({
    int take = 50,
    int offset = 0,
  }) async => [
    SnPersonalityConversation(
      id: 'c1',
      agentId: 'a1',
      title: 'First thread',
      lastMessageAt: DateTime(2026, 1, 2),
    ),
  ];

  @override
  Future<List<SnPersonalityMessage>> listMessages(
    String conversationId, {
    int take = 200,
    int offset = 0,
  }) async => history;

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
    List<SnRunInputPart> inputParts = const [],
    List<SnLocalTool> clientTools = const [],
    List<SnClientSkill> clientSkills = const [],
    List<String> overrides = const [],
    List<String> context = const [],
    String? reasoningEffort,
    bool disableReasoning = false,
    CancelToken? cancelToken,
  }) async* {
    sentMessages.add(message);
    sentAttachments.add(attachmentIds);
    sentInputParts.add(inputParts);
    lastClientTools = clientTools;
    final error = failure;
    if (error != null) throw error;
    yield* Stream.fromIterable(reply);
  }
}

/// The screen needs an AutoRouter ancestor for its header actions, so the test
/// mounts the generated `/` route in a throwaway router.
class _ConversationTestRouter extends RootStackRouter {
  @override
  List<AutoRoute> get routes => [
    AutoRoute(page: ConversationRoute.page, path: '/', initial: true),
    AutoRoute(page: SettingsRoute.page, path: '/settings'),
  ];
}

const _signedInUser = SolarUser(name: 'Test', handle: 'tester');

/// A deterministic auth notifier: starts in [initial]; signing in flips the
/// state to signed-in (the OAuth flow itself is never run in tests).
class _StubSolarAuthNotifier extends SolarAuthNotifier {
  _StubSolarAuthNotifier(this.initial);

  final SolarAuthState initial;

  @override
  SolarAuthState build() => initial;

  @override
  Future<SolarUser> signIn() async {
    state = const SolarAuthState(SolarAuthStatus.signedIn, _signedInUser);
    return _signedInUser;
  }
}

Future<void> _pumpConversationPage(
  WidgetTester tester,
  _FakePersonalityApi api, {
  SolarAuthState authState = const SolarAuthState(
    SolarAuthStatus.signedIn,
    _signedInUser,
  ),
}) async {
  final preferences = await SharedPreferences.getInstance();
  final routerConfig = _ConversationTestRouter().config();
  await tester.runAsync(() async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(preferences),
          personalityApiProvider.overrideWithValue(api),
          personalityAgentsProvider.overrideWith((ref) async => [_agent]),
          solarAuthStateProvider.overrideWith(
            () => _StubSolarAuthNotifier(authState),
          ),
        ],
        child: MaterialApp.router(
          routerConfig: routerConfig,
          theme: buildPersynthTheme(Brightness.light),
        ),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));
  });
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    // The Personality client's auth interceptor reads the secure session;
    // answer with no session so requests proceed unauthenticated.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async => null,
        );
  });

  testWidgets('shows the companion, the thread list, and the start hint', (
    tester,
  ) async {
    await _pumpConversationPage(tester, _FakePersonalityApi());

    // The agent appears twice: in the header picker and as the row subtitle.
    expect(find.text('Michan'), findsNWidgets(2));
    expect(
      tester
          .widget<DropdownButton<String>>(find.byType(DropdownButton<String>))
          .value,
      'a1',
    );
    expect(find.text('First thread'), findsOneWidget);
    expect(
      find.textContaining('start a conversation with Michan'),
      findsOneWidget,
    );
    // The thread list is bare: its title and new-chat live in the app bar.
    expect(find.text('Conversations'), findsNothing);
    expect(find.byIcon(Symbols.edit_square_rounded), findsOneWidget);
  });

  testWidgets('streams a turn into the thread log', (tester) async {
    final api = _FakePersonalityApi(
      reply: const [
        PersonalityReasoningDelta('weighing the options'),
        PersonalityMessageDelta('Hel'),
        PersonalityMessageDelta('lo'),
        PersonalityRunCompleted('Hello there'),
      ],
    );
    await _pumpConversationPage(tester, api);

    await tester.enterText(find.byType(TextField), 'hi there');
    await tester.pump();
    await tester.tap(find.byIcon(Symbols.send_rounded));
    await tester.pumpAndSettle();

    expect(api.sentMessages, ['hi there']);
    expect(find.text('hi there'), findsOneWidget);
    expect(find.text('Hello there', findRichText: true), findsOneWidget);
    // The reasoning trace folds itself once the reply starts.
    expect(find.text('thought'), findsOneWidget);
  });

  testWidgets('folds finished tool calls into one expandable row', (
    tester,
  ) async {
    final api = _FakePersonalityApi(
      reply: const [
        PersonalityToolCallStarted(
          id: 'c1',
          name: 'search',
          arguments: {'q': 'x'},
        ),
        PersonalityToolCallCompleted(
          id: 'c1',
          name: 'search',
          arguments: {'q': 'x'},
          result: 'ok',
        ),
        PersonalityRunCompleted('Done'),
      ],
    );
    await _pumpConversationPage(tester, api);

    await tester.enterText(find.byType(TextField), 'look it up');
    await tester.pump();
    await tester.tap(find.byIcon(Symbols.send_rounded));
    await tester.pumpAndSettle();

    expect(find.text('search'), findsOneWidget);
    // Settled machinery shows a one-line summary, not the full trace.
    expect(_plainText('ok'), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is SelectableText &&
            (widget.data?.contains('"q"') ?? false),
      ),
      findsOneWidget,
    );

    await tester.tap(find.text('search'));
    await tester.pumpAndSettle();

    // Opening the row swaps the summary for the arguments/result detail.
    expect(_plainText('ok'), findsNothing);
    expect(find.text('arguments'), findsOneWidget);
    expect(find.text('result'), findsOneWidget);
  });

  testWidgets('opens the thread list in a sheet on narrow screens', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await _pumpConversationPage(tester, _FakePersonalityApi());

    // The side panel is a wide-screen affordance.
    expect(find.text('First thread'), findsNothing);

    await tester.tap(find.byIcon(Symbols.forum_rounded));
    await tester.pumpAndSettle();

    expect(find.text('Conversations'), findsOneWidget);
    expect(find.text('First thread'), findsOneWidget);
  });

  testWidgets('opens the settings page from the header', (tester) async {
    await _pumpConversationPage(tester, _FakePersonalityApi());

    await tester.tap(find.byIcon(Symbols.tune_rounded));
    await tester.pumpAndSettle();

    expect(find.byType(SettingsPage), findsOneWidget);
    expect(find.text('Settings'), findsOneWidget);
    // The account/server settings and the AI console share the one page.
    expect(find.text('General'), findsOneWidget);
    expect(find.text('Catalog'), findsOneWidget);
    expect(find.text('Billing'), findsOneWidget);
    expect(find.text('Credentials'), findsOneWidget);
  });

  testWidgets('shows its unauthorized status, and recovers, when signed out', (
    tester,
  ) async {
    await _pumpConversationPage(
      tester,
      _FakePersonalityApi(),
      authState: const SolarAuthState(SolarAuthStatus.signedOut, null),
    );

    // No session is a status of the screen, not a banner over a chat that
    // cannot send: the composer is gone and the sign-in is in its place.
    expect(find.text('Unauthorized'), findsOneWidget);
    expect(find.textContaining('Solar Network session ended'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    expect(find.text('Continue with Solar Network'), findsOneWidget);

    await tester.tap(find.text('Continue with Solar Network'));
    await tester.pumpAndSettle();

    // The fresh session brings the chat surface back.
    expect(find.text('Unauthorized'), findsNothing);
    expect(find.byType(TextField), findsOneWidget);
  });

  testWidgets('shows its unauthorized status when the server refuses a turn', (
    tester,
  ) async {
    final api = _FakePersonalityApi(failure: _forbidden());
    await _pumpConversationPage(tester, api);

    await tester.enterText(find.byType(TextField), 'hi there');
    await tester.pump();
    await tester.tap(find.byIcon(Symbols.send_rounded));
    await tester.pumpAndSettle();

    // A refusal is not a hiccup to retry past, so it does not read like one:
    // the chat surface gives way to the status and the sign-in it needs.
    expect(find.text('Unauthorized'), findsOneWidget);
    expect(find.textContaining('refused the last request'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);

    // The session is still there, so the reader can put the chat back.
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();

    expect(find.text('Unauthorized'), findsNothing);
    expect(find.byType(TextField), findsOneWidget);
  });

  testWidgets('replays a persisted thread into the same rows', (tester) async {
    final api = _FakePersonalityApi(
      history: const [
        SnPersonalityMessage(
          role: 'user',
          content: 'what is up',
          attachmentIds: ['file-1'],
        ),
        SnPersonalityMessage(
          role: 'assistant',
          content: 'All good.\n\nSecond paragraph.',
          reasoningContent: 'checked the sky',
          toolCalls: [
            SnPersonalityToolCall(
              id: 't1',
              name: 'weather',
              arguments: '{"city":"Oslo"}',
            ),
          ],
        ),
        SnPersonalityMessage(role: 'tool', content: 'sunny'),
      ],
    );
    await _pumpConversationPage(tester, api);

    await tester.tap(find.text('First thread'));
    await tester.pumpAndSettle();

    expect(find.text('what is up'), findsOneWidget);
    // Blank lines split the assistant reply into paragraph rows.
    expect(find.text('All good.', findRichText: true), findsOneWidget);
    expect(find.text('Second paragraph.', findRichText: true), findsOneWidget);
    // Reasoning and tool calls survive the round trip as folded traces.
    expect(find.text('thought'), findsOneWidget);
    expect(find.text('weather'), findsOneWidget);
    expect(_plainText('earlier turn'), findsOneWidget);
  });

  testWidgets('shows the conversation context and tokens in the composer', (
    tester,
  ) async {
    final api = _FakePersonalityApi(
      usageTotal: const SnConversationUsage(
        runs: 12,
        inputTokens: 48210,
        outputTokens: 9310,
        totalTokens: 57520,
        peakContextUsedTokens: 7204,
        contextWindowTokens: 128000,
      ),
    );
    await _pumpConversationPage(tester, api);

    // The composer starts bare; the numbers arrive with the open thread.
    expect(find.textContaining('/ 128k'), findsNothing);

    await tester.tap(find.text('First thread'));
    await tester.pumpAndSettle();

    expect(
      find.text('7.2k / 128k · 57.5k tok · 12 runs'),
      findsOneWidget,
    );
    // The title is the companion's name, not a ledger.
    expect(find.textContaining('tokens ·'), findsNothing);
  });

  testWidgets('moves a finished turn\'s spend into the composer readout', (
    tester,
  ) async {
    const runUsage = SnRunUsage(
      inputTokens: 1005,
      outputTokens: 507,
      totalTokens: 1512,
      rounds: 2,
      contextUsedTokens: 1000,
      contextWindowTokens: 128000,
      contextUsedRatio: 0.007813,
    );
    final api = _FakePersonalityApi(
      reply: const [
        PersonalityMessageDelta('Paris.'),
        PersonalityRunCompleted('Paris.'),
        PersonalityUsageReported(runUsage),
      ],
      usageTotal: const SnConversationUsage(
        runs: 1,
        inputTokens: 1005,
        outputTokens: 507,
        totalTokens: 1512,
        peakContextUsedTokens: 1000,
        contextWindowTokens: 128000,
      ),
    );
    await _pumpConversationPage(tester, api);

    await tester.enterText(find.byType(TextField), 'capital of France?');
    await tester.pump();
    await tester.tap(find.byIcon(Symbols.send_rounded));
    await tester.pumpAndSettle();

    // The reply no longer carries its own footer; the composer does.
    expect(find.textContaining('tokens ·'), findsNothing);
    expect(find.text('1k / 128k · 1.5k tok · 1 run'), findsOneWidget);
  });

  testWidgets('sets the reasoning effort from the composer and remembers it', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await _pumpConversationPage(tester, _FakePersonalityApi());

    // The control sits quiet on the model default.
    expect(find.text('Default'), findsOneWidget);

    await tester.tap(find.text('Default'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Off (no thinking)').last);
    await tester.pumpAndSettle();

    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getString(kReasoningSettingStoreKey), 'off');
    expect(find.text('No thinking'), findsOneWidget);
  });

  testWidgets('a short paste stays in the message field', (tester) async {
    await _pumpConversationPage(tester, _FakePersonalityApi());

    await tester.enterText(find.byType(TextField), 'hello there');
    await tester.pump();

    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'hello there',
    );
    expect(find.textContaining('Pasted text'), findsNothing);
  });

  testWidgets('a long paste becomes an attachment instead of message text', (
    tester,
  ) async {
    await _pumpConversationPage(tester, _FakePersonalityApi());

    await tester.enterText(find.byType(TextField), 'x' * 1500);
    await tester.pump();

    // The field keeps the message; the document keeps the document.
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, '');
    expect(find.textContaining('Pasted text'), findsOneWidget);
    expect(find.text('1.5k characters · Edit'), findsOneWidget);
  });

  testWidgets('a queued text attachment can be edited before it is sent', (
    tester,
  ) async {
    await _pumpConversationPage(tester, _FakePersonalityApi());

    await tester.enterText(find.byType(TextField), 'y' * 1200);
    await tester.pump();

    await tester.tap(find.textContaining('Pasted text'));
    await tester.pumpAndSettle();

    // The editor opens holding the pasted block whole.
    final dialogField = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(TextField),
    );
    expect(
      tester.widget<TextField>(dialogField).controller!.text.length,
      1200,
    );

    await tester.enterText(dialogField, 'edited body');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(find.text('11 characters · Edit'), findsOneWidget);
  });

  testWidgets('a pasted block is sent as a text part, never uploaded', (
    tester,
  ) async {
    final api = _FakePersonalityApi(
      reply: const [PersonalityRunCompleted('Got it')],
    );
    await _pumpConversationPage(tester, api);

    await tester.enterText(find.byType(TextField), 'z' * 1500);
    await tester.pump();

    await tester.tap(find.byIcon(Symbols.send_rounded));
    await tester.pumpAndSettle();

    // The run carries the text itself, under the name the reader saw, and no
    // drive id to fetch a file with.
    final part = api.sentInputParts.single.single;
    expect(part.type, 'text');
    expect(part.text, 'z' * 1500);
    expect(part.name, startsWith('Pasted text'));
    expect(part.name, endsWith('.txt'));
    expect(api.sentAttachments.single, isEmpty);
    expect(api.sentMessages.single, '');

    // The sent turn shows the document it carried, not an image placeholder.
    expect(find.text('1.5k characters'), findsOneWidget);
    expect(find.textContaining('Got it'), findsOneWidget);
  });

  testWidgets('an emptied text attachment leaves the queue', (tester) async {
    final api = _FakePersonalityApi();
    await _pumpConversationPage(tester, api);

    await tester.enterText(find.byType(TextField), 'q' * 1200);
    await tester.pump();
    await tester.tap(find.textContaining('Pasted text'));
    await tester.pumpAndSettle();

    final dialogField = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(TextField),
    );
    await tester.enterText(dialogField, '   ');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    // An empty attachment would make the run invalid, so it is simply gone.
    expect(find.textContaining('Pasted text'), findsNothing);
    expect(find.text('1.2k characters · Edit'), findsNothing);
  });

  testWidgets('a replayed text attachment survives the round trip', (
    tester,
  ) async {
    final api = _FakePersonalityApi(
      history: [
        SnPersonalityMessage(
          role: 'user',
          content: 'what does this say?',
          inputParts: [
            SnRunInputPart.text(
              'a' * 1200,
              name: 'Pasted text 2026-10-02 143005.txt',
            ),
          ],
        ),
      ],
    );
    await _pumpConversationPage(tester, api);

    await tester.tap(find.text('First thread'));
    await tester.pumpAndSettle();

    expect(find.text('what does this say?'), findsOneWidget);
    expect(find.text('Pasted text 2026-10-02 143005.txt'), findsOneWidget);
    expect(find.text('1.2k characters'), findsOneWidget);
  });
}

/// Matches a plain [Text] by its data, ignoring selectable trace detail.
Finder _plainText(String data) => find.byWidgetPredicate(
  (widget) => widget is Text && widget.data == data,
);

/// A server refusal of the request the app was authenticated for.
DioException _forbidden() {
  final options = RequestOptions(path: '/personality/conversations/c1/runs');
  return DioException(
    requestOptions: options,
    response: Response(requestOptions: options, statusCode: 403),
  );
}
