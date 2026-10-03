import 'dart:async';

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
import 'package:persynth/personality/insight_chat_controller.dart';
import 'package:persynth/personality/local_tool.dart';
import 'package:persynth/personality/personality_api.dart';
import 'package:persynth/personality/personality_network.dart';
import 'package:persynth/personality/personality_service.dart';
import 'package:persynth/personality/reasoning_settings.dart';
import 'package:persynth/router.dart';
import 'package:persynth/screens/settings_page.dart';
import 'package:persynth/theme/app_theme.dart';
import 'package:persynth/widgets/media_lightbox.dart';

const _agent = SnPersonalityAgent(id: 'a1', name: 'Michan', enabled: true);

class _FakePersonalityApi extends PersonalityApi {
  _FakePersonalityApi({
    this.reply = const [],
    this.history = const [],
    this.usageTotal,
    this.failure,
    List<SnPersonalityConversation>? conversations,
    List<SnConversationGroup>? groups,
  }) : conversations =
           conversations ??
           [
             SnPersonalityConversation(
               id: 'c1',
               agentId: 'a1',
               title: 'First thread',
               lastMessageAt: DateTime(2026, 1, 2),
             ),
           ],
       groups = groups ?? [],
       super(Dio());

  final List<PersonalityRunEvent> reply;
  final List<SnPersonalityMessage> history;

  /// The account's threads, mutated in place so a refetch after a delete or a
  /// group change reads back what the server would now return.
  final List<SnPersonalityConversation> conversations;

  /// The account's groups, mutated in place the same way.
  final List<SnConversationGroup> groups;

  /// Every delete, batch delete, assignment and group delete the page asked
  /// for, in order.
  final List<String> deleted = [];
  final List<List<String>> batchDeleted = [];
  final List<({List<String> ids, String? groupId})> groupAssignments = [];
  final List<String> deletedGroups = [];

  /// Every rename/archive the page asked for, in order.
  final List<({String id, String? name, bool? archived})> groupUpdates = [];

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
  }) async => List.of(conversations);

  @override
  Future<void> deleteConversation(String id) async {
    deleted.add(id);
    conversations.removeWhere((conversation) => conversation.id == id);
  }

  @override
  Future<int> deleteConversations(List<String> ids) async {
    batchDeleted.add(List.of(ids));
    final before = conversations.length;
    conversations.removeWhere((conversation) => ids.contains(conversation.id));
    return before - conversations.length;
  }

  @override
  Future<int> setConversationGroup(List<String> ids, String? groupId) async {
    groupAssignments.add((ids: List.of(ids), groupId: groupId));
    var updated = 0;
    for (var i = 0; i < conversations.length; i++) {
      final conversation = conversations[i];
      if (!ids.contains(conversation.id)) continue;
      conversations[i] = _regroup(conversation, groupId);
      updated++;
    }
    return updated;
  }

  @override
  Future<List<SnConversationGroup>> listConversationGroups() async => [
    for (final group in groups)
      SnConversationGroup(
        id: group.id,
        name: group.name,
        description: group.description,
        archived: group.archived,
        conversationCount: conversations
            .where((conversation) => conversation.groupId == group.id)
            .length,
      ),
  ];

  @override
  Future<SnConversationGroup> createConversationGroup({
    required String name,
    String description = '',
  }) async {
    final group = SnConversationGroup(
      id: 'g${groups.length + 1}',
      name: name,
      description: description,
    );
    groups.add(group);
    return group;
  }

  @override
  Future<SnConversationGroup> updateConversationGroup(
    String id, {
    String? name,
    String? description,
    bool? archived,
  }) async {
    groupUpdates.add((id: id, name: name, archived: archived));
    final index = groups.indexWhere((group) => group.id == id);
    final current = groups[index];
    final updated = SnConversationGroup(
      id: current.id,
      name: name ?? current.name,
      description: description ?? current.description,
      archived: archived ?? current.archived,
      conversationCount: current.conversationCount,
    );
    groups[index] = updated;
    return updated;
  }

  @override
  Future<void> deleteConversationGroup(String id) async {
    deletedGroups.add(id);
    groups.removeWhere((group) => group.id == id);
    for (var i = 0; i < conversations.length; i++) {
      if (conversations[i].groupId == id) {
        conversations[i] = _regroup(conversations[i], null);
      }
    }
  }

  SnPersonalityConversation _regroup(
    SnPersonalityConversation conversation,
    String? groupId,
  ) => SnPersonalityConversation(
    id: conversation.id,
    agentId: conversation.agentId,
    title: conversation.title,
    lastMessageAt: conversation.lastMessageAt,
    groupId: groupId,
  );

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

/// A drive whose uploads the test finishes by hand, so an attachment can be
/// watched while it is still going up — the tile, its progress, the turn
/// waiting on it — instead of only once it has landed.
class _FakeDrive extends PersonalityCoreService {
  _FakeDrive({this.files = const []});

  /// What the drive listing answers with, newest first.
  final List<PersonalityDriveFile> files;

  /// Every search the picker ran, in order — the bare listing when the sheet
  /// opens, then whatever was typed into it.
  final List<String?> searched = [];

  /// Every path an upload was started for, in the order they were started.
  final List<String> started = [];

  /// Every path whose upload was aborted from this end.
  final List<String> aborted = [];

  final Map<String, _PendingUpload> _pending = {};

  @override
  Future<List<PersonalityDriveFile>> listDriveFiles({
    String driveBaseUrl = PersonalityCoreService.productionDriveBaseUrl,
    String? query,
    int offset = 0,
    int take = 40,
  }) async {
    searched.add(query);
    final needle = query?.toLowerCase() ?? '';
    if (needle.isEmpty) return files;
    return [
      for (final file in files)
        if (file.displayName.toLowerCase().contains(needle)) file,
    ];
  }

  @override
  Future<PersonalityDriveFile> driveFile(
    String fileId, {
    String driveBaseUrl = PersonalityCoreService.productionDriveBaseUrl,
  }) async {
    for (final file in files) {
      if (file.id == fileId) return file;
    }
    throw PersonalityCoreException('No file "$fileId" in the drive.');
  }

  /// Reports progress for an upload still in flight, as a socket would.
  void reportProgress(String path, double ratio) {
    final upload = _pending[path]!;
    upload.onProgress?.call((ratio * upload.total).round(), upload.total);
  }

  /// Answers an upload with the drive id the run will reference it by.
  void finish(String path, {String id = 'file-1'}) =>
      _pending.remove(path)!.completer.complete(id);

  void fail(String path, String message) => _pending
      .remove(path)!
      .completer
      .completeError(PersonalityCoreException(message));

  @override
  Future<String> uploadAttachment({
    required String filePath,
    String driveBaseUrl = PersonalityCoreService.productionDriveBaseUrl,
    String? contentType,
    void Function(int sent, int total)? onProgress,
    Future<void>? abortTrigger,
  }) {
    started.add(filePath);
    final completer = Completer<String>();
    _pending[filePath] = _PendingUpload(
      completer: completer,
      onProgress: onProgress,
    );
    abortTrigger?.then((_) {
      aborted.add(filePath);
      if (!completer.isCompleted) {
        completer.completeError(StateError('upload aborted'));
      }
    });
    return completer.future;
  }
}

class _PendingUpload {
  _PendingUpload({required this.completer, this.onProgress});

  final Completer<String> completer;
  final void Function(int sent, int total)? onProgress;

  /// The body length progress is reported against.
  final int total = 100;
}

/// The chat controller behind the pumped page, for driving the pieces a test
/// cannot pick by hand.
InsightChatController _chatOf(WidgetTester tester) => ProviderScope.containerOf(
  tester.element(find.byType(TextField)),
).read(insightChatControllerProvider.notifier);

/// The composer's send button, whatever it is doing at the moment.
IconButton _sendButton(WidgetTester tester) => tester.widget<IconButton>(
  find.ancestor(
    of: find.byIcon(Symbols.send_rounded),
    matching: find.byType(IconButton),
  ),
);

/// A tooltip whose message contains [text] — where a tile keeps what it cannot
/// say in 60 pixels.
Finder _tooltipSaying(String text) => find.byWidgetPredicate(
  (widget) => widget is Tooltip && (widget.message ?? '').contains(text),
);

/// A real image in the repository, for the tests that need a picked file to
/// exist on disk: `Image.file` decodes it instead of falling back.
const kTestImagePath = 'test/fixtures/pet_image.png';

/// The provider an image actually decodes with: a bounded decode wraps the
/// real provider in a [ResizeImage], which is what a picture drawn at the size
/// of its box always has.
ImageProvider _decodedBy(Image image) {
  final provider = image.image;
  return provider is ResizeImage ? provider.imageProvider : provider;
}

/// Pictures drawn from a drive id — what a linked or replayed image wears,
/// and what the placeholder is not.
Finder _drivePictures(String fileId) => find.byWidgetPredicate((widget) {
  if (widget is! Image) return false;
  final provider = _decodedBy(widget);
  return provider is NetworkImage &&
      provider.url.contains('/drive/files/$fileId') &&
      provider.headers?['Authorization'] == 'Bearer test-token';
});

/// Pictures drawn from a file on this device.
Finder _filePictures(String path) => find.byWidgetPredicate((widget) {
  if (widget is! Image) return false;
  final provider = _decodedBy(widget);
  return provider is FileImage && provider.file.path == path;
});

/// The attach sheet's search field, by the hint it carries.
Finder _driveSearch() => find.byWidgetPredicate(
  (widget) =>
      widget is TextField && widget.decoration?.hintText == 'Search your drive',
);

Future<void> _pumpConversationPage(
  WidgetTester tester,
  _FakePersonalityApi api, {
  SolarAuthState authState = const SolarAuthState(
    SolarAuthStatus.signedIn,
    _signedInUser,
  ),
  PersonalityCoreService? drive,
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
          // A drive preview is an `Image.network` carrying the account token,
          // which in the app is read from the session; the test states one so
          // the picture is asked for rather than falling back to the tile.
          solarAccessTokenProvider.overrideWith((ref) => 'test-token'),
          if (drive != null)
            personalityCoreServiceProvider.overrideWithValue(drive),
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
            widget is SelectableText && (widget.data?.contains('"q"') ?? false),
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

    expect(find.text('7.2k / 128k · 57.5k tok · 12 runs'), findsOneWidget);
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

    // The pill is the three levels, and nothing is lit on the model default.
    expect(find.text('Low'), findsOneWidget);
    expect(find.text('Medium'), findsOneWidget);
    expect(find.text('High'), findsOneWidget);
    expect(find.byTooltip('Reasoning effort: Model default'), findsOneWidget);

    await tester.tap(find.text('High'));
    await tester.pumpAndSettle();

    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getString(kReasoningSettingStoreKey), 'high');
    expect(
      find.byTooltip('Reasoning effort: High\nTap again for the model default'),
      findsOneWidget,
    );

    // Tapping the lit level again gives the turn back to the model's default,
    // so the untouched state is reachable from the pill alone.
    await tester.tap(find.text('High'));
    await tester.pumpAndSettle();
    expect(preferences.getString(kReasoningSettingStoreKey), 'default');
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
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '',
    );
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
    expect(tester.widget<TextField>(dialogField).controller!.text.length, 1200);

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

  testWidgets('a picked image is on the strip before its upload lands', (
    tester,
  ) async {
    final api = _FakePersonalityApi();
    final drive = _FakeDrive();
    await _pumpConversationPage(tester, api, drive: drive);

    _chatOf(tester).queueImages(const [
      InsightPickedImage(name: 'sheep.png', path: '/tmp/sheep.png'),
    ]);
    await tester.pump();

    // The file is on the strip from the moment it is picked, and the turn waits
    // for it: sending now would leave the image behind.
    expect(drive.started, ['/tmp/sheep.png']);
    expect(find.byTooltip('Uploading sheep.png'), findsOneWidget);
    expect(_sendButton(tester).onPressed, isNull);

    drive.reportProgress('/tmp/sheep.png', 0.42);
    await tester.pump();
    expect(find.text('42%'), findsOneWidget);

    drive.finish('/tmp/sheep.png');
    await tester.pump();

    // Landed: the progress is gone, the tile stays, and a turn with nothing
    // typed still carries the image — the attachment-only send.
    expect(find.text('42%'), findsNothing);
    expect(find.byTooltip('sheep.png'), findsOneWidget);

    await tester.tap(find.byIcon(Symbols.send_rounded));
    await tester.pumpAndSettle();

    expect(api.sentMessages, ['']);
    expect(api.sentAttachments, [
      ['file-1'],
    ]);
  });

  testWidgets('a failed upload stays queued until it is retried', (
    tester,
  ) async {
    final api = _FakePersonalityApi();
    final drive = _FakeDrive();
    await _pumpConversationPage(tester, api, drive: drive);

    _chatOf(tester).queueImages(const [
      InsightPickedImage(name: 'sheep.png', path: '/tmp/sheep.png'),
    ]);
    await tester.pump();

    drive.fail('/tmp/sheep.png', 'the drive said no');
    await tester.pump();

    // The file is still the reader's and the turn is still held: a failed
    // attachment is never dropped out of the message behind their back.
    expect(_tooltipSaying('the drive said no'), findsOneWidget);
    expect(find.byIcon(Symbols.refresh_rounded), findsOneWidget);
    expect(_sendButton(tester).onPressed, isNull);

    await tester.tap(find.byIcon(Symbols.refresh_rounded));
    await tester.pump();
    expect(drive.started, ['/tmp/sheep.png', '/tmp/sheep.png']);

    drive.finish('/tmp/sheep.png', id: 'file-2');
    await tester.pump();
    expect(find.byIcon(Symbols.refresh_rounded), findsNothing);

    await tester.enterText(find.byType(TextField), 'look at this');
    await tester.pump();
    await tester.tap(find.byIcon(Symbols.send_rounded));
    await tester.pumpAndSettle();

    expect(api.sentAttachments, [
      ['file-2'],
    ]);
  });

  testWidgets('a file the drive already holds is linked, not uploaded', (
    tester,
  ) async {
    final api = _FakePersonalityApi(
      reply: const [PersonalityRunCompleted('Got it')],
    );
    final drive = _FakeDrive(
      files: const [
        PersonalityDriveFile(
          id: 'drive-9',
          name: 'sunset.png',
          mimeType: 'image/png',
          byteSize: 2400000,
        ),
      ],
    );
    await _pumpConversationPage(tester, api, drive: drive);

    await tester.tap(find.byIcon(Symbols.attach_file_rounded));
    await tester.pumpAndSettle();

    // The sheet opens on the account's own drive: whatever was uploaded
    // before, offered as it is — beside the device option, not instead of it.
    expect(drive.searched, [null]);
    expect(find.text('Photo from this device'), findsOneWidget);
    expect(find.text('sunset.png'), findsOneWidget);
    expect(find.text('2.4MB'), findsOneWidget);

    await tester.tap(find.text('sunset.png'));
    await tester.pumpAndSettle();

    // Queued as the drive's file: no upload was started, and the turn is
    // ready to leave with it.
    expect(drive.started, isEmpty);
    expect(find.byTooltip('sunset.png'), findsOneWidget);
    expect(_sendButton(tester).onPressed, isNotNull);

    await tester.tap(find.byIcon(Symbols.send_rounded));
    await tester.pumpAndSettle();

    expect(api.sentMessages, ['']);
    expect(api.sentAttachments, [
      ['drive-9'],
    ]);

    // The sent turn wears the same picture, drawn from the id: a linked file
    // has nothing on this device to preview it with.
    expect(_drivePictures('drive-9'), findsOneWidget);
  });

  testWidgets('the link sheet searches the drive by name', (tester) async {
    final drive = _FakeDrive(
      files: const [
        PersonalityDriveFile(
          id: 'drive-1',
          name: 'sunset.png',
          mimeType: 'image/png',
        ),
        PersonalityDriveFile(
          id: 'drive-2',
          name: 'sheep.png',
          mimeType: 'image/png',
        ),
      ],
    );
    await _pumpConversationPage(tester, _FakePersonalityApi(), drive: drive);

    await tester.tap(find.byIcon(Symbols.attach_file_rounded));
    await tester.pumpAndSettle();
    expect(find.text('sunset.png'), findsOneWidget);
    expect(find.text('sheep.png'), findsOneWidget);

    await tester.enterText(_driveSearch(), 'sheep');
    await tester.pump();
    // A keystroke is not a question: the drive is asked once typing stops.
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    expect(drive.searched, [null, 'sheep']);
    expect(find.text('sunset.png'), findsNothing);
    expect(find.text('sheep.png'), findsOneWidget);
  });

  testWidgets('a file linked by id is resolved by the drive', (tester) async {
    final api = _FakePersonalityApi(
      reply: const [PersonalityRunCompleted('Got it')],
    );
    final drive = _FakeDrive(
      files: const [
        PersonalityDriveFile(
          id: 'drive-7',
          name: 'old-photo.jpg',
          mimeType: 'image/jpeg',
        ),
      ],
    );
    await _pumpConversationPage(tester, api, drive: drive);

    await tester.tap(find.byIcon(Symbols.attach_file_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Link a file by id'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      ),
      'drive-7',
    );
    await tester.tap(find.text('Link'));
    await tester.pumpAndSettle();

    // The tile wears the name the drive keeps, not the id that was pasted.
    expect(find.byTooltip('old-photo.jpg'), findsOneWidget);

    await tester.tap(find.byIcon(Symbols.send_rounded));
    await tester.pumpAndSettle();
    expect(api.sentAttachments, [
      ['drive-7'],
    ]);
  });

  testWidgets('a picked image keeps its picture after it is sent', (
    tester,
  ) async {
    final api = _FakePersonalityApi();
    final drive = _FakeDrive();
    await _pumpConversationPage(tester, api, drive: drive);

    _chatOf(tester).queueImages(const [
      InsightPickedImage(name: 'pet.png', path: kTestImagePath),
    ]);
    await tester.pump();
    drive.finish(kTestImagePath, id: 'file-1');
    await tester.pump();

    await tester.tap(find.byIcon(Symbols.send_rounded));
    await tester.pumpAndSettle();

    expect(api.sentAttachments, [
      ['file-1'],
    ]);
    // The sent turn draws the file it was picked as: the preview the strip
    // showed does not disappear at the send, and no request stands between the
    // reader and their own file.
    expect(_filePictures(kTestImagePath), findsOneWidget);
  });

  testWidgets('a replayed image is drawn from the drive', (tester) async {
    final api = _FakePersonalityApi(
      history: const [
        SnPersonalityMessage(
          role: 'user',
          content: 'look at this',
          attachmentIds: ['file-1'],
        ),
      ],
    );
    await _pumpConversationPage(tester, api);

    await tester.tap(find.text('First thread'));
    await tester.pumpAndSettle();

    // A restored thread has ids and nothing else, so the picture has to come
    // from the drive — and it does, with the account's own token.
    expect(_drivePictures('file-1'), findsOneWidget);
  });

  testWidgets('a queued picture opens in the viewer off the strip', (
    tester,
  ) async {
    final api = _FakePersonalityApi();
    final drive = _FakeDrive();
    await _pumpConversationPage(tester, api, drive: drive);

    _chatOf(tester).queueImages(const [
      InsightPickedImage(name: 'pet.png', path: kTestImagePath),
    ]);
    await tester.pump();
    drive.finish(kTestImagePath, id: 'file-1');
    await tester.pump();

    await tester.tap(_filePictures(kTestImagePath));
    await tester.pumpAndSettle();

    expect(find.byType(MediaLightbox), findsOneWidget);
    expect(find.text('pet.png'), findsWidgets);
  });

  testWidgets('a sent picture opens in the viewer, and escape leaves it', (
    tester,
  ) async {
    final api = _FakePersonalityApi();
    final drive = _FakeDrive();
    await _pumpConversationPage(tester, api, drive: drive);

    _chatOf(tester).queueImages(const [
      InsightPickedImage(name: 'pet.png', path: kTestImagePath),
    ]);
    await tester.pump();
    drive.finish(kTestImagePath, id: 'file-1');
    await tester.pump();

    await tester.tap(find.byIcon(Symbols.send_rounded));
    await tester.pumpAndSettle();

    await tester.tap(_filePictures(kTestImagePath));
    await tester.pumpAndSettle();

    // The viewer opens on the file the bubble is showing, under its name.
    expect(find.byType(MediaLightbox), findsOneWidget);
    expect(find.text('pet.png'), findsWidgets);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(MediaLightbox), findsNothing);
    expect(find.text('pet.png'), findsNothing);
  });

  testWidgets('a linked picture opens from the drive, token and all', (
    tester,
  ) async {
    final api = _FakePersonalityApi();
    final drive = _FakeDrive(
      files: const [
        PersonalityDriveFile(
          id: 'drive-9',
          name: 'sunset.png',
          mimeType: 'image/png',
        ),
      ],
    );
    await _pumpConversationPage(tester, api, drive: drive);

    await tester.tap(find.byIcon(Symbols.attach_file_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.text('sunset.png'));
    await tester.pumpAndSettle();

    await tester.tap(_drivePictures('drive-9'));
    await tester.pumpAndSettle();

    // A linked file has nothing on this device, so the viewer asks the drive
    // for it with the account's own token.
    expect(find.byType(MediaLightbox), findsOneWidget);
    expect(find.text('sunset.png'), findsWidgets);
    expect(_drivePictures('drive-9'), findsWidgets);
  });

  testWidgets('taking a tile back aborts its upload', (tester) async {
    final api = _FakePersonalityApi();
    final drive = _FakeDrive();
    await _pumpConversationPage(tester, api, drive: drive);

    _chatOf(tester).queueImages(const [
      InsightPickedImage(name: 'sheep.png', path: '/tmp/sheep.png'),
    ]);
    await tester.pump();
    expect(find.byTooltip('Uploading sheep.png'), findsOneWidget);

    await tester.tap(find.byIcon(Symbols.close_rounded));
    await tester.pump();

    expect(drive.aborted, ['/tmp/sheep.png']);
    expect(find.byTooltip('Uploading sheep.png'), findsNothing);
    // The reader's own undo is not a failure to report.
    expect(_tooltipSaying('upload aborted'), findsNothing);
    expect(_sendButton(tester).onPressed, isNull);
  });

  testWidgets('selects conversations and batch-deletes them', (tester) async {
    final api = _FakePersonalityApi(
      conversations: [
        SnPersonalityConversation(
          id: 'c1',
          agentId: 'a1',
          title: 'First thread',
        ),
        SnPersonalityConversation(
          id: 'c2',
          agentId: 'a1',
          title: 'Second thread',
        ),
      ],
    );
    await _pumpConversationPage(tester, api);

    expect(find.text('First thread'), findsOneWidget);
    expect(find.text('Second thread'), findsOneWidget);

    // A long-press enters selection mode with that row already chosen.
    await tester.longPress(find.text('First thread'));
    await tester.pumpAndSettle();
    expect(find.text('1 selected'), findsOneWidget);

    // While selecting, a tap toggles the next row in rather than opening it.
    await tester.tap(find.text('Second thread'));
    await tester.pumpAndSettle();
    expect(find.text('2 selected'), findsOneWidget);

    await tester.tap(find.byTooltip('Delete'));
    await tester.pumpAndSettle();
    expect(find.text('Delete 2 conversations?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();

    expect(api.batchDeleted, [
      ['c1', 'c2'],
    ]);
    expect(api.deleted, isEmpty);
    expect(find.text('First thread'), findsNothing);
    expect(find.text('Second thread'), findsNothing);
    // The strip left with the selection.
    expect(find.text('2 selected'), findsNothing);
  });

  testWidgets('deletes one conversation from its row menu', (tester) async {
    final api = _FakePersonalityApi(
      conversations: [
        SnPersonalityConversation(
          id: 'c1',
          agentId: 'a1',
          title: 'First thread',
        ),
        SnPersonalityConversation(
          id: 'c2',
          agentId: 'a1',
          title: 'Second thread',
        ),
      ],
    );
    await _pumpConversationPage(tester, api);

    await tester.tap(find.byIcon(Symbols.more_vert).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(find.text('Delete conversation?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();

    expect(api.deleted, ['c1']);
    expect(api.batchDeleted, isEmpty);
    expect(find.text('First thread'), findsNothing);
    expect(find.text('Second thread'), findsOneWidget);
  });

  testWidgets('creates a group tile and moves a conversation into it', (
    tester,
  ) async {
    final api = _FakePersonalityApi(
      conversations: [
        SnPersonalityConversation(
          id: 'c1',
          agentId: 'a1',
          title: 'First thread',
        ),
        SnPersonalityConversation(
          id: 'c2',
          agentId: 'a1',
          title: 'Second thread',
        ),
      ],
    );
    await _pumpConversationPage(tester, api);

    // No groups yet: today's plain list, plus the tile that makes one.
    expect(find.text('Ungrouped'), findsNothing);
    expect(find.text('New group'), findsOneWidget);

    await tester.tap(find.text('New group'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      ),
      'Work',
    );
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    // The new group appears collapsed, with the ungrouped rows now labelled.
    expect(find.text('Work'), findsOneWidget);
    expect(find.text('0 conversations'), findsOneWidget);
    expect(find.text('Ungrouped'), findsOneWidget);

    await tester.tap(find.byTooltip('Conversation actions').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Move to group…'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(SimpleDialog),
        matching: find.text('Work'),
      ),
    );
    await tester.pumpAndSettle();

    expect(api.groupAssignments, hasLength(1));
    expect(api.groupAssignments.single.ids, ['c1']);
    expect(api.groupAssignments.single.groupId, 'g1');
    // The tile counts the thread it now holds.
    expect(find.text('1 conversation'), findsOneWidget);

    // Opening the tile shows the thread, with its group beside the agent.
    await tester.tap(find.text('Work'));
    await tester.pumpAndSettle();
    expect(find.text('First thread'), findsOneWidget);
    expect(find.text('Work'), findsNWidgets(2));
  });

  testWidgets('a group tile starts collapsed and expands on tap', (
    tester,
  ) async {
    final api = _FakePersonalityApi(
      conversations: [
        SnPersonalityConversation(
          id: 'c1',
          agentId: 'a1',
          title: 'First thread',
          groupId: 'g1',
        ),
        SnPersonalityConversation(
          id: 'c2',
          agentId: 'a1',
          title: 'Second thread',
        ),
      ],
      groups: [const SnConversationGroup(id: 'g1', name: 'Work')],
    );
    await _pumpConversationPage(tester, api);

    // The grouped thread is hidden until the tile opens; the ungrouped one is
    // always there.
    expect(find.text('First thread'), findsNothing);
    expect(find.text('Second thread'), findsOneWidget);

    await tester.tap(find.text('Work').first);
    await tester.pumpAndSettle();
    expect(find.text('First thread'), findsOneWidget);

    await tester.tap(find.text('Work').first);
    await tester.pumpAndSettle();
    expect(find.text('First thread'), findsNothing);
  });

  testWidgets('archiving gathers a group and its threads under Archived', (
    tester,
  ) async {
    final api = _FakePersonalityApi(
      conversations: [
        SnPersonalityConversation(
          id: 'c1',
          agentId: 'a1',
          title: 'First thread',
          groupId: 'g1',
        ),
        SnPersonalityConversation(
          id: 'c2',
          agentId: 'a1',
          title: 'Second thread',
        ),
      ],
      groups: [const SnConversationGroup(id: 'g1', name: 'Work')],
    );
    await _pumpConversationPage(tester, api);

    expect(find.text('Work'), findsOneWidget);
    expect(find.text('Archived'), findsNothing);

    // Archive from the tile's menu: immediate, no confirmation.
    await tester.tap(find.byTooltip('Group actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Archive'));
    await tester.pumpAndSettle();

    expect(api.groupUpdates, [(id: 'g1', name: null, archived: true)]);
    // Gone from the top level, and so is its thread.
    expect(find.text('Work'), findsNothing);
    expect(find.text('First thread'), findsNothing);
    expect(find.text('Archived'), findsOneWidget);

    // Reachable under Archived: open the tile, then the group inside it.
    await tester.tap(find.text('Archived'));
    await tester.pumpAndSettle();
    expect(find.text('Work'), findsOneWidget);
    await tester.tap(find.text('Work').first);
    await tester.pumpAndSettle();
    expect(find.text('First thread'), findsOneWidget);

    // Unarchiving puts the group back at the top level.
    await tester.tap(find.byTooltip('Group actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Unarchive'));
    await tester.pumpAndSettle();

    expect(api.groupUpdates.last, (id: 'g1', name: null, archived: false));
    expect(find.text('Archived'), findsNothing);
    expect(find.text('First thread'), findsOneWidget);
  });

  testWidgets('moves a selection into an active group only', (tester) async {
    final api = _FakePersonalityApi(
      conversations: [
        SnPersonalityConversation(
          id: 'c1',
          agentId: 'a1',
          title: 'First thread',
        ),
        SnPersonalityConversation(
          id: 'c2',
          agentId: 'a1',
          title: 'Second thread',
        ),
      ],
      groups: [
        const SnConversationGroup(id: 'g1', name: 'Work'),
        const SnConversationGroup(id: 'g2', name: 'Old', archived: true),
      ],
    );
    await _pumpConversationPage(tester, api);

    await tester.longPress(find.text('First thread'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Second thread'));
    await tester.pumpAndSettle();
    expect(find.text('2 selected'), findsOneWidget);

    await tester.tap(find.byTooltip('Move to group'));
    await tester.pumpAndSettle();
    // The archived group is not offered.
    expect(
      find.descendant(
        of: find.byType(SimpleDialog),
        matching: find.text('Old'),
      ),
      findsNothing,
    );
    await tester.tap(
      find.descendant(
        of: find.byType(SimpleDialog),
        matching: find.text('Work'),
      ),
    );
    await tester.pumpAndSettle();

    expect(api.groupAssignments, hasLength(1));
    expect(api.groupAssignments.single.ids, ['c1', 'c2']);
    expect(api.groupAssignments.single.groupId, 'g1');
  });

  testWidgets('deleting the open conversation resets the thread', (
    tester,
  ) async {
    final api = _FakePersonalityApi(
      history: const [
        SnPersonalityMessage(role: 'user', content: 'what is up'),
      ],
    );
    await _pumpConversationPage(tester, api);

    await tester.tap(find.text('First thread'));
    await tester.pumpAndSettle();
    expect(find.text('what is up'), findsOneWidget);

    await tester.tap(find.byIcon(Symbols.more_vert).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();

    expect(api.deleted, ['c1']);
    // The composer and the log are back to a fresh conversation, and the row
    // is gone from the list.
    expect(find.text('what is up'), findsNothing);
    expect(
      find.textContaining('start a conversation with Michan'),
      findsOneWidget,
    );
    expect(find.text('First thread'), findsNothing);
  });
}

/// Matches a plain [Text] by its data, ignoring selectable trace detail.
Finder _plainText(String data) =>
    find.byWidgetPredicate((widget) => widget is Text && widget.data == data);

/// A server refusal of the request the app was authenticated for.
DioException _forbidden() {
  final options = RequestOptions(path: '/personality/conversations/c1/runs');
  return DioException(
    requestOptions: options,
    response: Response(requestOptions: options, statusCode: 403),
  );
}
