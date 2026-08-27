import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:synth_pet/conversation/conversation_controller.dart';
import 'package:synth_pet/conversation/personality_backend.dart';
import 'package:synth_pet/personality/personality_service.dart';
import 'package:synth_pet/screens/conversation_page.dart';
import 'package:synth_pet/theme/app_theme.dart';

/// Emits a full machinery turn: reasoning, one resolved tool call, then the
/// reply.
class _TraceBackend implements ChatBackend {
  @override
  Future<String> createConversation({
    required String agentId,
    String title = '',
    http.Client? client,
  }) async => 'conversation-1';

  @override
  Future<String> runConversation({
    required String conversationId,
    required String message,
    List<String> attachmentIds = const [],
    void Function(String delta)? onChunk,
    void Function(String id, String name, Map<String, dynamic> args)?
    onToolCall,
    void Function(
      String id,
      String name,
      Map<String, dynamic> args,
      String result,
    )?
    onToolResult,
    void Function(String delta)? onReasoning,
    http.Client? client,
  }) async {
    onReasoning?.call('the pet is hungry, let me');
    onReasoning?.call(' check the schedule');
    onToolCall?.call('call-1', 'remember', const {'note': 'walk at 8'});
    onToolResult?.call('call-1', 'remember', const {
      'note': 'walk at 8',
    }, 'Saved note: walk at 8.');
    onChunk?.call('Walk time!');
    return 'Walk time!';
  }

  @override
  Future<List<PersonalityAgent>> listAgents() async => const [
    PersonalityAgent(id: 'michan', name: 'Mochi', description: ''),
  ];

  @override
  Future<List<PersonalityConversation>> listConversations({
    int take = 50,
    int offset = 0,
  }) async => const [];

  @override
  Future<List<PersonalityMessage>> listMessages({
    required String conversationId,
    int take = 200,
    int offset = 0,
  }) async => const [];

  @override
  Future<String> uploadAttachment({
    required String filePath,
    String? contentType,
  }) async => 'file-1';
}

/// Starts a tool call but never resolves it; the turn ends first.
class _InterruptedBackend extends _TraceBackend {
  @override
  Future<String> runConversation({
    required String conversationId,
    required String message,
    List<String> attachmentIds = const [],
    void Function(String delta)? onChunk,
    void Function(String id, String name, Map<String, dynamic> args)?
    onToolCall,
    void Function(
      String id,
      String name,
      Map<String, dynamic> args,
      String result,
    )?
    onToolResult,
    void Function(String delta)? onReasoning,
    http.Client? client,
  }) async {
    onReasoning?.call('hold on');
    onToolCall?.call('call-9', 'search', const {'query': 'island'});
    onChunk?.call('One moment.');
    return 'One moment.';
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    // A stored Solar session lets the page skip the auth gate in tests.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async =>
              call.method == 'read' ? '{"access_token":"tok"}' : null,
        );
  });

  Future<void> pumpConversation(
    WidgetTester tester,
    ChatBackend backend,
  ) async {
    final controller = ConversationController(backend: backend);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildSynthPetTheme(Brightness.light),
        home: Scaffold(body: ConversationPage(controller: controller)),
      ),
    );
    await tester.pump(); // secure-storage read
    await tester.pump(); // agent list resolves
  }

  /// Sends a message the way a user does: typed into the input field, so the
  /// page's own send path (and its user bubble) is exercised.
  Future<void> sendViaInput(WidgetTester tester, String text) async {
    await tester.enterText(find.byType(TextField), text);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
  }

  testWidgets('folds thinking and tool traces once the reply lands', (
    tester,
  ) async {
    await pumpConversation(tester, _TraceBackend());
    await sendViaInput(tester, 'walk time?');

    // The reply is front and center…
    expect(find.text('Walk time!'), findsOneWidget);
    // …and the machinery folded to single log lines.
    expect(find.text('thought'), findsOneWidget);
    expect(
      find.text('the pet is hungry, let me check the schedule').hitTestable(),
      findsOneWidget,
    );
    expect(find.text('remember'), findsOneWidget);
    expect(find.text('Saved note: walk at 8.').hitTestable(), findsOneWidget);
    // Details stay tucked away until asked for.
    expect(find.text('note: walk at 8').hitTestable(), findsNothing);
  });

  testWidgets('tapping a trace opens its detail well', (tester) async {
    await pumpConversation(tester, _TraceBackend());
    await sendViaInput(tester, 'walk time?');

    await tester.tap(find.text('thought'));
    await tester.pumpAndSettle();
    expect(
      find.text('the pet is hungry, let me check the schedule').hitTestable(),
      findsOneWidget,
    );

    await tester.tap(find.text('remember'));
    await tester.pumpAndSettle();
    expect(find.text('note: walk at 8').hitTestable(), findsOneWidget);
    expect(find.text('Saved note: walk at 8.').hitTestable(), findsOneWidget);

    // Tapping again folds it back.
    await tester.tap(find.text('remember'));
    await tester.pumpAndSettle();
    expect(find.text('note: walk at 8').hitTestable(), findsNothing);
  });

  testWidgets('logs an interrupted tool call when the turn ends first', (
    tester,
  ) async {
    await pumpConversation(tester, _InterruptedBackend());
    await sendViaInput(tester, 'hold on');

    expect(find.text('search'), findsOneWidget);
    expect(find.text('interrupted').hitTestable(), findsOneWidget);
  });
}
