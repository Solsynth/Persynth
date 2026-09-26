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

  test('read_timeline asks the feed endpoint and unwraps its envelope', () async {
    final adapter = SolarStubAdapter({
      'GET /sphere/timeline': pageJson([
        postJson(id: 'p1'),
        postJson(id: 'p2', publisherName: 'ada', publisherNick: 'Ada', replies: 4),
      ]),
    });

    final result = await run(adapter, 'read_timeline', {'take': 2});

    // `/sphere/timeline/home` is a route the service does not have; this is
    // the one it does, and it answers with the items inside an envelope.
    expect(adapter.request('GET', '/sphere/timeline').queryParameters, {
      'offset': 0,
      'take': 2,
    });
    expect((result['posts'] as List).map((post) => post['id']), ['p1', 'p2']);
    expect((result['posts'] as List).first, {
      'id': 'p1',
      'author': 'Little Sheep',
      'username': 'littleSheep',
      'posted_at': '2026-09-20T10:00:00Z',
      'content': 'hello',
      // A number is kept even at zero: no replies is an answer.
      'replies': 0,
    });
    expect((result['posts'] as List).last['replies'], 4);
  });

  test('read_timeline clamps what the model asks for', () async {
    final adapter = SolarStubAdapter({'GET /sphere/timeline': pageJson([])});

    await run(adapter, 'read_timeline', {'take': 5000});
    expect(adapter.request('GET', '/sphere/timeline').queryParameters['take'], 30);

    adapter.requests.clear();
    // A model that passes the number as text still gets its answer.
    await run(adapter, 'read_timeline', {'take': '3'});
    expect(adapter.request('GET', '/sphere/timeline').queryParameters['take'], 3);

    adapter.requests.clear();
    await run(adapter, 'read_timeline', {});
    expect(adapter.request('GET', '/sphere/timeline').queryParameters['take'], 10);
  });

  test('read_post returns the post and its replies', () async {
    final adapter = SolarStubAdapter({
      'GET /sphere/posts/p1': postJson(id: 'p1', replies: 1),
      'GET /sphere/posts/p1/replies': [postJson(id: 'r1', content: 'nice')],
    });

    final result = await run(adapter, 'read_post', {'post_id': 'p1', 'take': 5});

    expect(adapter.request('GET', '/sphere/posts/p1/replies').queryParameters['take'], 5);
    expect(result['post']['id'], 'p1');
    expect((result['replies'] as List).single['content'], 'nice');
  });

  test('search_posts searches the post listing, not a search service', () async {
    final adapter = SolarStubAdapter({
      'GET /sphere/posts': [postJson(id: 'p9')],
    });

    final result = await run(adapter, 'search_posts', {'query': 'duckdb'});

    final query = adapter.request('GET', '/sphere/posts').queryParameters;
    expect(query['query'], 'duckdb');
    expect(query.containsKey('q'), isFalse, reason: '`q` is a 404');
    expect((result['posts'] as List).single['id'], 'p9');
  });

  test('read_profile finds a publisher\'s posts by filtering', () async {
    final adapter = SolarStubAdapter({
      'GET /sphere/publishers/littleSheep': {
        'id': 'pub-1',
        'name': 'littleSheep',
        'nick': 'Little Sheep',
        'bio': 'builds things',
        'rating': 120.5,
      },
      'GET /sphere/posts': [postJson(id: 'p1')],
    });

    final result = await run(adapter, 'read_profile', {'username': 'littleSheep'});

    // A publisher's posts are the listing filtered: `/publishers/{n}/posts` is
    // a route the service does not have.
    expect(adapter.request('GET', '/sphere/posts').queryParameters['pub'], 'littleSheep');
    expect(result['publisher'], {
      'username': 'littleSheep',
      'display_name': 'Little Sheep',
      'bio': 'builds things',
      'rating': 120.5,
    });
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

  test('reply_to_post replies through the post route that accepts a parent', () async {
    final adapter = SolarStubAdapter({
      'POST /sphere/posts': postJson(id: 'r1', content: 'congrats'),
    });

    final reply = await run(adapter, 'reply_to_post', {
      'post_id': 'p1',
      'content': 'congrats',
    });

    // The reply route is the post route with a parent, not `/posts/{id}/replies`
    // — that one answers 405 to a write.
    expect(adapter.request('POST', '/sphere/posts').data, {
      'content': 'congrats',
      'repliedPostId': 'p1',
    });
    expect(reply['id'], 'r1');
  });

  test('react_to_post sends a symbol and an attitude', () async {
    final adapter = SolarStubAdapter({
      'POST /sphere/posts/p1/reactions': {'ok': true},
    });

    final reaction = await run(adapter, 'react_to_post', {
      'post_id': 'p1',
      'reaction': '🎉',
    });

    // `type` is the field the SDK invented; the service reads `symbol`.
    expect(adapter.request('POST', '/sphere/posts/p1/reactions').data, {
      'symbol': '🎉',
      'attitude': 0,
    });
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
        'GET /sphere/timeline': {'message': 'token expired'},
      },
      statuses: {'GET /sphere/timeline': 401},
    );

    final result = await run(adapter, 'read_timeline', {});

    expect(result['error'], contains('not signed in'));
    expect(result['error'], contains('token expired'));
  });

  test('the server\'s own words reach the model when it explains itself', () async {
    final adapter = SolarStubAdapter(
      {
        'GET /sphere/timeline': {'message': 'scope sphere.read is missing'},
      },
      statuses: {'GET /sphere/timeline': 403},
    );

    final result = await run(adapter, 'read_timeline', {});

    expect(result['error'], contains('not allowed'));
    expect(result['error'], contains('HTTP 403'));
    expect(result['error'], contains('scope sphere.read is missing'));
  });

  test('a post the wire barely fills in still answers', () async {
    // The failure this replaced: the response was parsed into a model whose
    // fields are declared non-nullable, so one absent or null field ended the
    // call with a cast error. A projection reads what is there and reports
    // nothing for what is not.
    final adapter = SolarStubAdapter({
      'GET /sphere/timeline': pageJson([
        {
          'id': 'p1',
          'content': null,
          'published_at': null,
          'created_at': null,
          'replies_count': null,
          'reactions_count': null,
          'tags': null,
          'publisher': null,
          'replied_post_id': null,
        },
      ]),
      'GET /sphere/posts/p1': {
        'id': 'p1',
        'content': 'only the id and this',
        'tags': ['solar', {'slug': 'network'}],
      },
      'GET /sphere/posts/p1/replies': <Object>[],
    });

    final timeline = await run(adapter, 'read_timeline', {});
    expect((timeline['posts'] as List).single, {'id': 'p1'});

    final post = await run(adapter, 'read_post', {'post_id': 'p1'});
    expect(post['post'], {
      'id': 'p1',
      'content': 'only the id and this',
      'tags': ['solar', 'network'],
    });
    expect(post['replies'], isEmpty);
  });

  test('a post id the service does not know is named as such', () async {
    final adapter = SolarStubAdapter({'GET /sphere/posts/nope': null});

    final result = await run(adapter, 'read_post', {'post_id': 'nope'});

    expect(result['error'], contains('no post nope'));
  });

  test('a long post body is clipped and marked', () async {
    final adapter = SolarStubAdapter({
      'GET /sphere/timeline': pageJson([postJson(id: 'p1', content: 'x' * 900)]),
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
