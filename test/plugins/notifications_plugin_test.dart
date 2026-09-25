import 'package:flutter_test/flutter_test.dart';
import 'package:persynth/plugins/notifications_plugin.dart';

import 'solar_test_support.dart';

/// One notification as the API returns it, for the stubs to build on.
///
/// The required keys only: a stub that a test wants full sets them itself, so
/// what a projection drops is visible in the test rather than in this default.
Map<String, dynamic> notificationJson({
  String id = 'n1',
  String topic = 'posts.mentions.new',
  String title = 'You were mentioned',
  String content = 'littleSheep mentioned you in a post.',
  bool read = false,
}) => {
  'id': id,
  'topic': topic,
  'title': title,
  'content': content,
  'created_at': '2026-09-20T10:00:00.000Z',
  'viewed_at': read ? '2026-09-21T08:00:00.000Z' : null,
  'account_id': 'acct-1',
};

/// The plugin builds its tools once per context, so each test builds the set
/// over its own adapter and reaches for the tool it is about.
void main() {
  const plugin = NotificationsPlugin();

  Future<Map<String, dynamic>> run(
    SolarStubAdapter adapter,
    String tool,
    Map<String, dynamic> arguments,
  ) async {
    final built = solarTool(
      plugin.buildTools(solarContext(solarDio(adapter))),
      tool,
    );
    return solarResult(await built.execute(arguments));
  }

  test('read_notifications projects each notification and passes take', () async {
    final adapter = SolarStubAdapter({
      'GET /metoer/notifications': [
        notificationJson(id: 'n1'),
        notificationJson(
          id: 'n2',
          topic: 'wallets.transactions',
          title: 'Payment received',
          content: 'You received 5 Sol.',
          read: true,
        ),
      ],
    });

    final result = await run(adapter, 'read_notifications', {'take': 2});

    expect(adapter.request('GET', '/metoer/notifications').queryParameters, {
      'offset': 0,
      'take': 2,
    });
    expect((result['notifications'] as List).first, {
      'id': 'n1',
      'topic': 'posts.mentions.new',
      'title': 'You were mentioned',
      'body': 'littleSheep mentioned you in a post.',
      'created_at': '2026-09-20T10:00:00Z',
      'read': false,
    });
    expect((result['notifications'] as List).last['read'], isTrue);
  });

  test('read_notifications clamps what the model asks for', () async {
    final adapter = SolarStubAdapter({'GET /metoer/notifications': <Object>[]});

    await run(adapter, 'read_notifications', {'take': 5000});
    expect(
      adapter.request('GET', '/metoer/notifications').queryParameters['take'],
      30,
    );

    adapter.requests.clear();
    // A model that passes the number as text still gets its answer.
    await run(adapter, 'read_notifications', {'take': '3'});
    expect(
      adapter.request('GET', '/metoer/notifications').queryParameters['take'],
      3,
    );

    adapter.requests.clear();
    await run(adapter, 'read_notifications', {});
    expect(
      adapter.request('GET', '/metoer/notifications').queryParameters['take'],
      10,
    );
  });

  test('a notification with nothing filled in stays compact', () async {
    final adapter = SolarStubAdapter({
      'GET /metoer/notifications': [
        {
          'id': 'n9',
          'topic': 'gifts.claimed',
          'title': '',
          'content': '',
          'subtitle': '',
          'meta': {'order_id': 'o-1', 'trace': 'x' * 400},
          'created_at': '2026-09-19T00:00:00.000Z',
          'viewed_at': null,
          'account_id': 'acct-1',
          'app_id': 'app-1',
        },
      ],
    });

    final result = await run(adapter, 'read_notifications', {});

    // The empty title and body say nothing, and the metadata blob the model
    // cannot act on is not carried along.
    expect((result['notifications'] as List).single, {
      'id': 'n9',
      'topic': 'gifts.claimed',
      'created_at': '2026-09-19T00:00:00Z',
      'read': false,
    });
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

  test('unread_notifications reads the count', () async {
    final adapter = SolarStubAdapter({'GET /metoer/notifications/count': 7});

    final result = await run(adapter, 'unread_notifications', {});

    expect(
      adapter.request('GET', '/metoer/notifications/count').queryParameters,
      isEmpty,
    );
    expect(result, {'unread': 7});
  });

  test('mark_notification_read reads the one it names', () async {
    final adapter = SolarStubAdapter({
      'POST /metoer/notifications/n1/read': <String, dynamic>{},
    });

    final result = await run(adapter, 'mark_notification_read', {
      'notification_id': 'n1',
    });

    final sent = adapter.request('POST', '/metoer/notifications/n1/read');
    expect(sent.data, isNull);
    expect(result, {'ok': true, 'notification_id': 'n1'});
  });

  test('mark_all_notifications_read posts to the all-read endpoint', () async {
    final adapter = SolarStubAdapter({
      'POST /metoer/notifications/all/read': <String, dynamic>{},
    });

    final result = await run(adapter, 'mark_all_notifications_read', {});

    expect(
      adapter.request('POST', '/metoer/notifications/all/read').queryParameters,
      isEmpty,
    );
    expect(result, {'ok': true});
  });

  test('a blank required argument is reported, not called', () async {
    final adapter = SolarStubAdapter({});

    final result = await run(adapter, 'mark_notification_read', {
      'notification_id': '   ',
    });

    expect(result['error'], contains('"notification_id"'));
    expect(adapter.requests, isEmpty);
  });

  test('a 401 reads as a session to renew, not as a status code', () async {
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

  test('the plugin rides every run, and says what marking read costs', () {
    expect(plugin.id, 'notifications');
    expect(plugin.onDemand, isFalse);
    expect(plugin.enabledByDefault, isFalse);
    expect(plugin.description, contains('mark them read'));
    final prompt = plugin.systemPrompt(solarContext(solarDio(SolarStubAdapter({}))));
    expect(prompt, anyElement(contains('unread count')));
    expect(prompt, anyElement(contains('when they ask')));
  });
}
