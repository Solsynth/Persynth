import 'package:flutter_test/flutter_test.dart';
import 'package:persynth/plugins/social_plugin.dart';

import 'solar_test_support.dart';

/// The plugin builds its tools once per context, so each test builds the set
/// over its own adapter and reaches for the tool it is about.
void main() {
  const plugin = SocialPlugin();

  Future<Map<String, dynamic>> run(
    SolarStubAdapter adapter,
    String tool,
    Map<String, dynamic> arguments,
  ) async {
    final built = solarTool(plugin.buildTools(solarContext(solarDio(adapter))), tool);
    return solarResult(await built.execute(arguments));
  }

  test('read_timeline projects each post and reports the total', () async {
    final adapter = SolarStubAdapter(
      {
        'GET /sphere/timeline/home': [
          postJson(id: 'p1'),
          postJson(id: 'p2', publisherName: 'ada', publisherNick: 'Ada', replies: 4),
        ],
      },
      totals: {'GET /sphere/timeline/home': 57},
    );

    final result = await run(adapter, 'read_timeline', {'take': 2});

    expect(adapter.request('GET', '/sphere/timeline/home').queryParameters, {
      'offset': 0,
      'take': 2,
    });
    expect(result['total'], 57);
    expect((result['posts'] as List).map((post) => post['id']), ['p1', 'p2']);
    // Only the fields that carry meaning, and none of the wire's empties.
    expect((result['posts'] as List).first, {
      'id': 'p1',
      'author': 'Little Sheep',
      'username': 'littleSheep',
      'content': 'hello',
      'posted_at': '2026-09-20T10:00:00Z',
    });
    expect((result['posts'] as List).last['replies'], 4);
  });

  test('read_timeline clamps what the model asks for', () async {
    final adapter = SolarStubAdapter({'GET /sphere/timeline/home': <Object>[]});

    await run(adapter, 'read_timeline', {'take': 5000});
    expect(adapter.request('GET', '/sphere/timeline/home').queryParameters['take'], 30);

    adapter.requests.clear();
    // A model that passes the number as text still gets its answer.
    await run(adapter, 'read_timeline', {'take': '3'});
    expect(adapter.request('GET', '/sphere/timeline/home').queryParameters['take'], 3);

    adapter.requests.clear();
    await run(adapter, 'read_timeline', {});
    expect(adapter.request('GET', '/sphere/timeline/home').queryParameters['take'], 10);
  });

  test('read_post returns the post and its replies', () async {
    final adapter = SolarStubAdapter(
      {
        'GET /sphere/posts/p1': postJson(id: 'p1', replies: 1),
        'GET /sphere/posts/p1/replies': [postJson(id: 'r1', content: 'nice')],
      },
      totals: {'GET /sphere/posts/p1/replies': 9},
    );

    final result = await run(adapter, 'read_post', {'post_id': 'p1', 'take': 5});

    expect(adapter.request('GET', '/sphere/posts/p1/replies').queryParameters['take'], 5);
    expect(result['post']['id'], 'p1');
    expect(result['replies_total'], 9);
    expect((result['replies'] as List).single['content'], 'nice');
  });

  test('search_posts passes the query through', () async {
    final adapter = SolarStubAdapter({
      'GET /sphere/search/posts': [postJson(id: 'p9')],
    });

    final result = await run(adapter, 'search_posts', {'query': 'duckdb'});

    expect(
      adapter.request('GET', '/sphere/search/posts').queryParameters,
      containsPair('q', 'duckdb'),
    );
    expect((result['posts'] as List).single['id'], 'p9');
  });

  test('read_profile returns the publisher and their posts', () async {
    final adapter = SolarStubAdapter({
      'GET /sphere/publishers/littleSheep': {
        'id': 'pub-1',
        'name': 'littleSheep',
        'nick': 'Little Sheep',
        'bio': 'builds things',
        'rating': 120.5,
      },
      'GET /sphere/publishers/littleSheep/posts': [postJson(id: 'p1')],
    }, totals: {'GET /sphere/publishers/littleSheep/posts': 3});

    final result = await run(adapter, 'read_profile', {'username': 'littleSheep'});

    expect(result['publisher'], {
      'username': 'littleSheep',
      'display_name': 'Little Sheep',
      'bio': 'builds things',
      'rating': 120.5,
    });
    expect(result['posts_total'], 3);
  });

  test('create_post posts the content and returns the created post', () async {
    final adapter = SolarStubAdapter({
      'POST /sphere/posts': postJson(id: 'new', content: 'shipped it'),
    });

    final result = await run(adapter, 'create_post', {'content': 'shipped it'});

    expect(adapter.request('POST', '/sphere/posts').data, {'content': 'shipped it'});
    expect(result['id'], 'new');
    expect(result['content'], 'shipped it');
  });

  test('reply_to_post and react_to_post carry what they were given', () async {
    final adapter = SolarStubAdapter({
      'POST /sphere/posts/p1/replies': postJson(id: 'r1', content: 'congrats'),
      'POST /sphere/posts/p1/reactions': {'ok': true},
    });

    final reply = await run(adapter, 'reply_to_post', {
      'post_id': 'p1',
      'content': 'congrats',
    });
    expect(adapter.request('POST', '/sphere/posts/p1/replies').data, {
      'content': 'congrats',
    });
    expect(reply['id'], 'r1');

    final reaction = await run(adapter, 'react_to_post', {
      'post_id': 'p1',
      'reaction': '🎉',
    });
    expect(adapter.request('POST', '/sphere/posts/p1/reactions').data, {'type': '🎉'});
    expect(reaction, {'ok': true, 'post_id': 'p1', 'reaction': '🎉'});
  });

  test('a blank required argument is reported, not called', () async {
    final adapter = SolarStubAdapter({});

    final result = await run(adapter, 'create_post', {'content': '   '});

    expect(result['error'], contains('"content"'));
    expect(adapter.requests, isEmpty);
  });

  test('a reaction that is not one emoji is refused before the wire', () async {
    final adapter = SolarStubAdapter({});

    final result = await run(adapter, 'react_to_post', {
      'post_id': 'p1',
      'reaction': 'this is a sentence',
    });

    expect(result['error'], contains('one emoji'));
    expect(adapter.requests, isEmpty);
  });

  test('a 401 reads as a session to renew, not as a status code', () async {
    final adapter = SolarStubAdapter(
      {
        'GET /sphere/timeline/home': {'message': 'token expired'},
      },
      statuses: {'GET /sphere/timeline/home': 401},
    );

    final result = await run(adapter, 'read_timeline', {});

    expect(result['error'], contains('not signed in'));
    expect(result['error'], contains('token expired'));
  });

  test('the server\'s own words reach the model when it explains itself', () async {
    final adapter = SolarStubAdapter(
      {
        'GET /sphere/timeline/home': {'message': 'scope sphere.read is missing'},
      },
      statuses: {'GET /sphere/timeline/home': 403},
    );

    final result = await run(adapter, 'read_timeline', {});

    expect(result['error'], contains('not allowed'));
    expect(result['error'], contains('HTTP 403'));
    expect(result['error'], contains('scope sphere.read is missing'));
  });

  test('an unreachable gateway is reported, not thrown', () async {
    final adapter = SolarStubAdapter(
      {'GET /sphere/timeline/home': {'message': 'upstream is down'}},
      statuses: {'GET /sphere/timeline/home': 503},
    );

    final result = await run(adapter, 'read_timeline', {});

    expect(result['error'], contains('internal error'));
  });

  test('a long post body is clipped and marked', () async {
    final adapter = SolarStubAdapter({
      'GET /sphere/timeline/home': [postJson(id: 'p1', content: 'x' * 900)],
    });

    final result = await run(adapter, 'read_timeline', {});
    final content = (result['posts'] as List).single['content'] as String;

    expect(content, endsWith('… [truncated]'));
    expect(content.length, lessThan(700));
  });

  test('the plugin is on demand, and says what it may do to the user\'s account', () {
    expect(plugin.onDemand, isTrue);
    expect(plugin.enabledByDefault, isFalse);
    expect(plugin.description, contains('as them'));
    expect(
      plugin.systemPrompt(solarContext(solarDio(SolarStubAdapter({})))),
      anyElement(contains('attributed')),
    );
  });
}
