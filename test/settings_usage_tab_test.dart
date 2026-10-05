import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:persynth/personality/personality_network.dart';
import 'package:persynth/screens/ai_console_tabs.dart';
import 'package:persynth/screens/settings_page.dart';
import 'package:persynth/theme/app_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Serves one canned body per `METHOD /path` and records every request, so a
/// test can check both what the audit read and what it asked for when the
/// reader narrowed it.
class _LedgerAdapter implements HttpClientAdapter {
  final List<RequestOptions> requests = [];

  final Map<String, Object> routes = {
    'GET /personality/web/search/engines': {
      'currency': 'golds',
      'engines': [
        {'id': 'tavily', 'price': '0.50000000'},
        {'id': 'duckduckgo', 'free': true},
      ],
    },
    'GET /personality/web/search/preference': {
      'engine': 'tavily',
      'currency': 'golds',
    },
    'PUT /personality/web/search/preference': {
      'engine': 'tavily',
      'currency': 'golds',
    },
    'GET /personality/billing/me/ledger/summary': {
      'entries': 2,
      'by_action': [
        {
          'key': 'generation',
          'currency': 'golds',
          'entries': 1,
          'amount': '12.00000000',
        },
        {
          'key': 'web_search/tavily',
          'currency': 'golds',
          'entries': 1,
          'amount': '0.50000000',
        },
      ],
      'by_surface': [
        {
          'key': '/api/conversations/:id/runs',
          'currency': 'golds',
          'entries': 1,
          'amount': '12.00000000',
        },
      ],
      'by_currency': [
        {
          'key': 'golds',
          'currency': 'golds',
          'entries': 2,
          'amount': '12.50000000',
        },
      ],
      'by_device_id': [
        {
          'key': 'web-1',
          'currency': 'golds',
          'entries': 2,
          'amount': '12.50000000',
        },
      ],
      'by_client_ip': [
        {
          'key': '203.0.113.7',
          'currency': 'golds',
          'entries': 2,
          'amount': '12.50000000',
        },
      ],
      'by_credential': [
        {
          'key': '',
          'currency': 'golds',
          'entries': 2,
          'amount': '12.50000000',
        },
      ],
    },
    'GET /personality/billing/me/ledger': [
      {
        'id': 'led-1',
        'action': 'generation',
        'surface': '/api/conversations/:id/runs',
        'model': 'openai/gpt-4o',
        'currency': 'golds',
        'amount': '12.00000000',
        'original_amount': '12.00000000',
        'device_id': 'web-1',
        'client_ip': '203.0.113.7',
        'input_tokens': 1200,
        'output_tokens': 300,
        'created_at': '2026-03-01T10:00:00Z',
      },
      {
        'id': 'led-2',
        'action': 'web_search/tavily',
        'surface': '/api/web/search',
        'model': 'web_search/tavily',
        'currency': 'golds',
        'amount': '0.50000000',
        'original_amount': '0.50000000',
        'device_id': 'web-1',
        'client_ip': '203.0.113.7',
        'created_at': '2026-03-01T10:05:00Z',
      },
    ],
  };

  Iterable<RequestOptions> requestsTo(String path) =>
      requests.where((options) => options.path == path);

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final key = '${options.method} ${options.path}';
    final headers = {
      Headers.contentTypeHeader: ['application/json'],
    };
    final body = routes[key];
    if (body == null) {
      return ResponseBody.fromString(
        jsonEncode({'message': 'no stub for $key'}),
        404,
        headers: headers,
      );
    }
    return ResponseBody.fromString(jsonEncode(body), 200, headers: headers);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the usage tab reads the ledger and the breakdown narrows it', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    // The console reads the secure session; answer with no session so the
    // request path settles instead of hanging.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async => null,
        );
    final preferences = await SharedPreferences.getInstance();
    final adapter = _LedgerAdapter();
    final dio = Dio(BaseOptions(baseUrl: 'https://api.solian.app'))
      ..httpClientAdapter = adapter;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(preferences),
          personalityApiClientProvider.overrideWithValue(dio),
        ],
        child: MaterialApp(
          theme: buildPersynthTheme(Brightness.light),
          home: const SettingsPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Usage').first);
    await tester.pumpAndSettle();

    // The engine choice, with what each engine costs.
    expect(find.text('tavily'), findsOneWidget);
    expect(find.textContaining('0.50 golds a search'), findsOneWidget);
    expect(find.textContaining('free'), findsOneWidget);

    // The window total, and the breakdown it is made of.
    expect(find.textContaining('12.50 Golds'), findsWidgets);
    expect(find.text('Reply'), findsWidgets);
    expect(find.text('Search · tavily'), findsWidgets);

    // A breakdown row is the way into the charges behind it.
    await tester.ensureVisible(find.text('web-1'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('web-1'));
    await tester.pumpAndSettle();
    expect(find.text('Device: web-1'), findsOneWidget);

    final ledger = adapter.requestsTo(
      '/personality/billing/me/ledger',
    ).toList();
    expect(ledger.last.queryParameters['device_id'], 'web-1');
    expect(
      ledger.last.queryParameters['from'],
      isA<String>().having((value) => value.startsWith('20'), 'a window', true),
    );

    // The breakdown is the overview the filter is chosen from, so narrowing the
    // list must not narrow it: only the list is asked for the device.
    final summary = adapter.requestsTo(
      '/personality/billing/me/ledger/summary',
    ).toList();
    expect(summary.last.queryParameters.containsKey('device_id'), isFalse);

    // The charges themselves: what was priced, and where the call came from.
    expect(find.text('openai/gpt-4o'), findsOneWidget);
    expect(find.textContaining('203.0.113.7'), findsWidgets);
  });

  testWidgets('choosing an engine tells the server, and says so', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async => null,
        );
    final preferences = await SharedPreferences.getInstance();
    final adapter = _LedgerAdapter();
    final dio = Dio(BaseOptions(baseUrl: 'https://api.solian.app'))
      ..httpClientAdapter = adapter;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(preferences),
          personalityApiClientProvider.overrideWithValue(dio),
        ],
        child: MaterialApp(
          theme: buildPersynthTheme(Brightness.light),
          home: const SettingsPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Usage').first);
    await tester.pumpAndSettle();

    await tester.tap(find.text('duckduckgo'));
    await tester.pumpAndSettle();

    final put = adapter.requestsTo('/personality/web/search/preference')
        .where((options) => options.method == 'PUT')
        .toList();
    expect(put, hasLength(1));
    expect(put.last.data, {'engine': 'duckduckgo'});
  });

  testWidgets('the usage tab holds its shape in a narrow window', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async => null,
        );
    // A phone the settings page has to survive, narrower than anything a
    // desktop window shows.
    tester.view.physicalSize = const Size(320, 560);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final preferences = await SharedPreferences.getInstance();
    final adapter = _LedgerAdapter();
    final dio = Dio(BaseOptions(baseUrl: 'https://api.solian.app'))
      ..httpClientAdapter = adapter;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(preferences),
          personalityApiClientProvider.overrideWithValue(dio),
        ],
        child: MaterialApp(
          theme: buildPersynthTheme(Brightness.light),
          home: const Scaffold(body: AiConsoleUsageTab()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // A row that cannot fit throws, so a clean frame is the check.
    expect(tester.takeException(), isNull);
  });
}
