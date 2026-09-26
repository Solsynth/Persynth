import 'package:flutter_test/flutter_test.dart';
import 'package:persynth/personality/local_tool.dart';
import 'package:persynth/plugins/notifications_plugin.dart';

import 'solar_test_support.dart';

/// One notification as the API returns it, for the stubs to build on.
///
/// The wire includes nulls rather than omitting them, so the default carries
/// the whole DTO and a test that wants a field set passes it — what a
/// projection drops is then visible in the test rather than in this helper.
Map<String, dynamic> notificationJson({
  String id = 'n1',
  String topic = 'posts.mentions.new',
  String? title = 'You were mentioned',
  String? content = 'littleSheep mentioned you in a post.',
  String? viewedAt,
}) => {
  'id': id,
  'created_at': '2026-09-20T10:00:00.000Z',
  'updated_at': '2026-09-20T10:00:00.000Z',
  'deleted_at': null,
  'topic': topic,
  'title': title,
  'subtitle': null,
  'content': content,
  'meta': <String, dynamic>{},
  'priority': 0,
  'viewed_at': viewedAt,
  'app_id': null,
  'push_type': 'apple',
  'account_id': 'acct-1',
};

/// The plugin builds its tools once per context, so each test builds the set
/// over its own adapter and reaches for the tool it is about.
void main() {
  const plugin = NotificationsPlugin();

  List<SnLocalTool> built(SolarStubAdapter adapter) =>
      plugin.buildTools(solarContext(solarDio(adapter)));

  Future<Map<String, dynamic>> run(
    SolarStubAdapter adapter,
    String tool,
    Map<String, dynamic> arguments,
  ) async => solarResult(await solarTool(built(adapter), tool).execute(arguments));

  test('read_notifications asks for a page it will not mark viewed', () async {
    final adapter = SolarStubAdapter({
      'GET /metoer/notifications': [
        notificationJson(id: 'n1'),
        notificationJson(
          id: 'n2',
          topic: 'wallets.transactions',
          title: 'Payment received',
          content: 'You received 5 Sol.',
          viewedAt: '2026-09-21T08:00:00.000Z',
        ),
      ],
    });

    final result = await run(adapter, 'read_notifications', {'take': 2});

    // `unmark=true` is the whole point of this tool: without it the route
    // marks the page it returns as viewed, so a read would spend the unread
    // count it is answering about.
    expect(adapter.request('GET', '/metoer/notifications').queryParameters, {
      'offset': 0,
      'take': 2,
      'unmark': true,
    });
    final items = result['notifications'] as List;
    expect(items.first, {
      'id': 'n1',
      'topic': 'posts.mentions.new',
      'title': 'You were mentioned',
      'body': 'littleSheep mentioned you in a post.',
      'created_at': '2026-09-20T10:00:00Z',
      'read': false,
    });
    expect((items.last as Map)['read'], isTrue);
  });

  test('read_notifications clamps what the model asks for', () async {
    final adapter = SolarStubAdapter({'GET /metoer/notifications': <Object>[]});

    Map<String, dynamic> sent() =>
        adapter.request('GET', '/metoer/notifications').queryParameters;

    await run(adapter, 'read_notifications', {'take': 5000});
    expect(sent(), {'offset': 0, 'take': 30, 'unmark': true});

    adapter.requests.clear();
    // A model that passes the number as text still gets its answer.
    await run(adapter, 'read_notifications', {'take': '3'});
    expect(sent(), {'offset': 0, 'take': 3, 'unmark': true});

    adapter.requests.clear();
    await run(adapter, 'read_notifications', {});
    expect(sent(), {'offset': 0, 'take': 10, 'unmark': true});
  });

  test('a long notification body is clipped and marked', () async {
    final adapter = SolarStubAdapter({
      'GET /metoer/notifications': [
        notificationJson(id: 'n1', content: 'x' * 900),
      ],
    });

    final result = await run(adapter, 'read_notifications', {});
    final body = (result['notifications'] as List).single['body'] as String;

    expect(body, endsWith('… [truncated]'));
    expect(body.length, lessThan(700));
  });

  test('a notification the wire barely fills in still projects', () async {
    final adapter = SolarStubAdapter({
      'GET /metoer/notifications': [
        // Every optional field present and null.
        {
          'id': 'n9',
          'created_at': '2026-09-19T00:00:00.000Z',
          'updated_at': '2026-09-19T00:00:00.000Z',
          'deleted_at': null,
          'topic': 'gifts.claimed',
          'title': null,
          'subtitle': null,
          'content': null,
          'meta': null,
          'priority': 0,
          'viewed_at': null,
          'app_id': null,
          'push_type': null,
          'account_id': 'acct-1',
        },
        // The keys a later version stopped sending are simply not there.
        {'id': 'n10'},
        // Empty strings say nothing either; a viewed timestamp is the read.
        {
          'id': 'n11',
          'created_at': '2026-09-18T00:00:00.000Z',
          'title': '',
          'content': '',
          'viewed_at': '2026-09-21T08:00:00.000Z',
        },
      ],
    });

    final result = await run(adapter, 'read_notifications', {});

    expect(result['notifications'], [
      {
        'id': 'n9',
        'topic': 'gifts.claimed',
        'created_at': '2026-09-19T00:00:00Z',
        'read': false,
      },
      {'id': 'n10', 'read': false},
      {
        'id': 'n11',
        'created_at': '2026-09-18T00:00:00Z',
        'read': true,
      },
    ]);
  });

  test('unread_notifications reads the bare number the route returns', () async {
    final adapter = SolarStubAdapter({'GET /metoer/notifications/count': 7});

    final result = await run(adapter, 'unread_notifications', {});

    expect(
      adapter.request('GET', '/metoer/notifications/count').queryParameters,
      isEmpty,
    );
    expect(result, {'unread': 7});
  });

  test('unread_notifications keeps a count of zero, which is an answer', () async {
    final adapter = SolarStubAdapter({'GET /metoer/notifications/count': 0});

    expect(await run(adapter, 'unread_notifications', {}), {'unread': 0});

    adapter.requests.clear();
    // The number can reach the wire as text; it is still the count.
    adapter.routes['GET /metoer/notifications/count'] = '0';
    expect(await run(adapter, 'unread_notifications', {}), {'unread': 0});
  });

  test('mark_all_notifications_read posts the one write, with no body', () async {
    final adapter = SolarStubAdapter({
      'POST /metoer/notifications/all/read': <String, dynamic>{},
    });

    final result = await run(adapter, 'mark_all_notifications_read', {});

    final sent = adapter.request('POST', '/metoer/notifications/all/read');
    expect(sent.queryParameters, isEmpty);
    expect(sent.data, isNull);
    expect(result, {'ok': true});
  });

  test('a refused write is reported rather than thrown', () async {
    final adapter = SolarStubAdapter(
      {
        'POST /metoer/notifications/all/read': {'message': 'read only'},
      },
      statuses: {'POST /metoer/notifications/all/read': 403},
    );

    final result = await run(adapter, 'mark_all_notifications_read', {});

    expect(result['error'], contains('not allowed'));
    expect(result['error'], contains('HTTP 403'));
    expect(result['error'], contains('read only'));
  });

  test('a 401 on the read reads as a session to renew', () async {
    final adapter = SolarStubAdapter(
      {
        'GET /metoer/notifications': {'message': 'token expired'},
      },
      statuses: {'GET /metoer/notifications': 401},
    );

    final result = await run(adapter, 'read_notifications', {});

    expect(result['error'], contains('not signed in'));
    expect(result['error'], contains('token expired'));
  });

  test('the plugin rides every run and offers only the tools that exist', () {
    final adapter = SolarStubAdapter({});
    final tools = built(adapter);

    expect(plugin.id, 'notifications');
    expect(plugin.label, 'Notifications');
    expect(plugin.onDemand, isFalse);
    expect(plugin.enabledByDefault, isFalse);
    expect(
      [for (final tool in tools) tool.name],
      ['read_notifications', 'unread_notifications', 'mark_all_notifications_read'],
    );
    // There is no per-notification read in the service, so no tool for one and
    // nothing in the map for the server's list to claim.
    expect(plugin.overrides.values, isNot(contains('mark_notification_read')));
    expect(plugin.overrides, {
      'list_notifications': 'read_notifications',
      'get_unread_notification_count': 'unread_notifications',
      'mark_all_notifications_read': 'mark_all_notifications_read',
    });
  });

  test('the prompt says reading marks nothing and the write clears everything', () {
    final prompt = plugin.systemPrompt(
      solarContext(solarDio(SolarStubAdapter({}))),
    );

    expect(prompt, hasLength(2));
    expect(prompt.first, contains('real ones'));
    expect(prompt, anyElement(contains('unread count')));
    expect(prompt, anyElement(contains('does not mark anything read')));
    expect(prompt, anyElement(contains('clears every unread')));
  });
}
