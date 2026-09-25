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
import 'package:persynth/personality/mcp_client.dart';
import 'package:persynth/personality/personality_api.dart';
import 'package:persynth/personality/personality_network.dart';
import 'package:persynth/router.dart';
import 'package:persynth/screens/settings_page.dart';
import 'package:persynth/theme/app_theme.dart';

const _agent = SnPersonalityAgent(id: 'a1', name: 'Michan', enabled: true);

class _FakePersonalityApi extends PersonalityApi {
  _FakePersonalityApi({this.reply = const [], this.history = const []})
    : super(Dio());

  final List<PersonalityRunEvent> reply;
  final List<SnPersonalityMessage> history;
  final List<String> sentMessages = [];
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
    List<SnLocalTool> clientTools = const [],
    List<SnClientSkill> clientSkills = const [],
    List<String> overrides = const [],
    List<String> context = const [],
    CancelToken? cancelToken,
  }) {
    sentMessages.add(message);
    lastClientTools = clientTools;
    return Stream.fromIterable(reply);
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
          // The settings page probes the MCP daemon over the loopback; tests
          // answer for it instead of going near the network.
          mcpDaemonStatusProvider.overrideWith(
            (ref) async => const McpDaemonStatus(reachable: false),
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

  testWidgets('invites a signed-out user to sign in and recovers', (
    tester,
  ) async {
    await _pumpConversationPage(
      tester,
      _FakePersonalityApi(),
      authState: const SolarAuthState(SolarAuthStatus.signedOut, null),
    );

    expect(
      find.textContaining("You're signed out"),
      findsOneWidget,
    );
    expect(find.text('Sign in'), findsOneWidget);

    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();

    // The fresh session hides the banner; the chat surface is usable again.
    expect(find.textContaining("You're signed out"), findsNothing);
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
}

/// Matches a plain [Text] by its data, ignoring selectable trace detail.
Finder _plainText(String data) => find.byWidgetPredicate(
  (widget) => widget is Text && widget.data == data,
);
