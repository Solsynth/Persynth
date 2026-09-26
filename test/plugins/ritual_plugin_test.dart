import 'package:flutter_test/flutter_test.dart';
import 'package:persynth/plugins/ritual_plugin.dart';

import 'solar_test_support.dart';

/// The plugin builds its tools once per context, so each test builds the set
/// over its own adapter and reaches for the tool it is about.
void main() {
  const plugin = RitualPlugin();

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

  /// What the sayings say, for checking that the draw came from the list
  /// rather than from anywhere else.
  List<String> sayingContents() => const [
    '天行健，君子以自强不息。',
    'A closed door is a wall you have not leaned on.',
    'The best preparation for tomorrow is doing your best today.',
  ];

  /// The sayings the fortune endpoint serves as it serves them: a bare array,
  /// each one a saying with where it came from.
  List<Object?> sayingsJson() => [
    {
      'content': '天行健，君子以自强不息。',
      'source': '周易',
      'language': 'zh',
    },
    {
      'content': 'A closed door is a wall you have not leaned on.',
      'source': 'Sun Tzu, apocryphal',
      'language': 'en',
    },
    {
      'content': 'The best preparation for tomorrow is doing your best today.',
      'source': 'H. Jackson Brown Jr.',
      'language': 'en',
    },
  ];

  /// One claimed check-in as the API returns it, with most of the report's
  /// slots empty the way the generator leaves the ones it did not use.
  Map<String, Object?> claimedJson() => {
    'id': 'ci-1',
    'level': 4,
    'reward_points': 12.5,
    'reward_experience': 30,
    'tips': [
      {
        'is_positive': true,
        'title': 'Speak up',
        'content': 'Say the thing you have been holding back.',
      },
      {
        'is_positive': false,
        'title': 'Travel light',
        'content': 'Do not carry more than the day needs.',
      },
    ],
    'fortune_report': {
      'version': 3,
      'poem': '云开见月',
      'summary': 'A day of small openings.',
      'summary_detail': 'Plan in the morning, work the plan after noon.',
      'wish': 'wish for a slower evening',
      'love': '',
      'study': '',
      'career': '',
      'health': '',
      'lost_item': '',
      'lucky_color': 'indigo',
      'lucky_direction': 'east',
      'lucky_time': '09:00',
      'lucky_item': 'a fountain pen',
      'lucky_action': 'write first, decide after',
      'avoid_action': 'signing anything in a hurry',
      'ritual': 'Read one page before the first message.',
    },
    'account_id': 'acc-1',
    'account': null,
    'created_at': '2026-09-26T01:05:00.000000Z',
    'updated_at': '2026-09-26T01:05:00.000000Z',
    'deleted_at': null,
  };

  /// The same claim as the model reads it: the report's version and its empty
  /// slots are dropped, and the rewards survive as themselves.
  Map<String, dynamic> claimedExpected() => {
    'checked_in': true,
    'level': 4,
    'claimed_at': '2026-09-26T01:05:00Z',
    'points': 12.5,
    'experience': 30,
    'tips': [
      {
        'positive': true,
        'title': 'Speak up',
        'content': 'Say the thing you have been holding back.',
      },
      {
        'positive': false,
        'title': 'Travel light',
        'content': 'Do not carry more than the day needs.',
      },
    ],
    'fortune': {
      'poem': '云开见月',
      'summary': 'A day of small openings.',
      'detail': 'Plan in the morning, work the plan after noon.',
      'wish': 'wish for a slower evening',
      'lucky_color': 'indigo',
      'lucky_direction': 'east',
      'lucky_time': '09:00',
      'lucky_item': 'a fountain pen',
      'lucky_action': 'write first, decide after',
      'avoid_action': 'signing anything in a hurry',
      'ritual': 'Read one page before the first message.',
    },
  };

  test('daily_fortune draws from the saying list and nowhere else', () async {
    final adapter = SolarStubAdapter({'GET /passport/fortune': sayingsJson()});

    final result = await run(adapter, 'daily_fortune', {});

    // The list is the route: `/fortune/daily` does not exist, and `/fortune/
    // random` would answer a different saying on every call.
    expect(adapter.requests.map((options) => '${options.method} ${options.path}'), [
      'GET /passport/fortune',
    ]);
    expect(adapter.request('GET', '/passport/fortune').queryParameters, isEmpty);
    expect(result['saying'], isIn(sayingContents()));
    expect(result.keys, containsAll(['saying', 'source', 'language']));
  });

  test('daily_fortune answers the same saying all day', () async {
    final adapter = SolarStubAdapter({'GET /passport/fortune': sayingsJson()});

    final first = await run(adapter, 'daily_fortune', {});
    final second = await run(adapter, 'daily_fortune', {});

    expect(second, first);
    expect(adapter.requests, hasLength(2));
  });

  test('daily_fortune reports a session to renew rather than a status', () async {
    final adapter = SolarStubAdapter(
      {
        'GET /passport/fortune': {'message': 'token expired'},
      },
      statuses: {'GET /passport/fortune': 401},
    );

    final result = await run(adapter, 'daily_fortune', {});

    expect(result['error'], contains('not signed in'));
    expect(result['error'], contains('token expired'));
  });

  test('daily_fortune says so when there is nothing to draw from', () async {
    final adapter = SolarStubAdapter({'GET /passport/fortune': <Object?>[]});

    final result = await run(adapter, 'daily_fortune', {});

    expect(result['error'], contains('no sayings'));
  });

  test('today_check_in reads a 404 as an unclaimed day', () async {
    final adapter = SolarStubAdapter(
      {
        'GET /passport/accounts/me/check-in': {'message': 'no check-in today'},
      },
      statuses: {'GET /passport/accounts/me/check-in': 404},
    );

    final result = await run(adapter, 'today_check_in', {});

    expect(
      adapter.request('GET', '/passport/accounts/me/check-in').queryParameters,
      {'version': 2},
    );
    expect(result, {'checked_in': false});
  });

  test('today_check_in does not read a refusal as an unclaimed day', () async {
    // Nothing but a missing day counts as unclaimed: a refusal on the way
    // there is an answer the model has to be able to read as one, or it would
    // offer the user a claim that cannot succeed.
    final adapter = SolarStubAdapter(
      {
        'GET /passport/accounts/me/check-in': {'message': 'capability missing'},
      },
      statuses: {'GET /passport/accounts/me/check-in': 403},
    );

    final result = await run(adapter, 'today_check_in', {});

    expect(result, containsPair('error', contains('not allowed')));
    expect(result['error'], contains('capability missing'));
    expect(result.containsKey('checked_in'), isFalse);
  });

  test('today_check_in reports what the day gave the user', () async {
    final adapter = SolarStubAdapter({
      'GET /passport/accounts/me/check-in': claimedJson(),
    });

    final result = await run(adapter, 'today_check_in', {});

    expect(
      adapter.request('GET', '/passport/accounts/me/check-in').queryParameters,
      {'version': 2},
    );
    expect(result, claimedExpected());
  });

  test('today_check_in names a bodyless answer instead of guessing', () async {
    final adapter = SolarStubAdapter({
      'GET /passport/accounts/me/check-in': null,
    });

    final result = await run(adapter, 'today_check_in', {});

    expect(result['error'], contains('without a check-in result'));
    expect(result.containsKey('checked_in'), isFalse);
  });

  test('check_in claims the day and returns what it gave', () async {
    final adapter = SolarStubAdapter({
      'POST /passport/accounts/me/check-in': claimedJson(),
    });

    final result = await run(adapter, 'check_in', {});

    final claim = adapter.request('POST', '/passport/accounts/me/check-in');
    // A claim is the whole request: no body to send, and the version the
    // endpoint reads the result with.
    expect(claim.data, isNull);
    expect(claim.queryParameters, {'version': 2});
    expect(result, claimedExpected());
  });

  test('check_in relays a day already claimed as a reason', () async {
    final adapter = SolarStubAdapter(
      {
        'POST /passport/accounts/me/check-in': {
          'message': 'Check-in is not available for today.',
        },
      },
      statuses: {'POST /passport/accounts/me/check-in': 400},
    );

    final result = await run(adapter, 'check_in', {});

    expect(result['error'], contains('rejected the request'));
    expect(result['error'], contains('not available for today'));
  });

  test('a check-in the wire barely fills in still answers', () async {
    // The rewards are optional in the model — a backdated claim carries
    // neither — and the report's slots arrive empty or absent. None of that
    // is an exception, or even a key: what the wire did not send is simply
    // not in the answer.
    final adapter = SolarStubAdapter({
      'GET /passport/accounts/me/check-in': {
        'id': 'ci-2',
        'level': null,
        'reward_points': null,
        'reward_experience': null,
        'tips': <Object?>[],
        'fortune_report': {
          'version': 2,
          'poem': '',
          'summary': null,
          'lucky_color': 'green',
        },
        'created_at': null,
      },
    });

    final result = await run(adapter, 'today_check_in', {});

    expect(result, {
      'checked_in': true,
      'fortune': {'lucky_color': 'green'},
    });
  });

  test('the plugin offers its three tools in reading order, without arguments', () {
    final tools = plugin.buildTools(solarContext(solarDio(SolarStubAdapter({}))));

    expect(tools.map((tool) => tool.name), [
      'daily_fortune',
      'today_check_in',
      'check_in',
    ]);
    for (final tool in tools) {
      expect(tool.parameters['properties'], isEmpty);
      expect(tool.parameters.containsKey('required'), isFalse);
    }
  });

  test('the plugin is eager, and the day\'s fortune is not mine to rewrite', () {
    expect(plugin.id, 'ritual');
    expect(plugin.label, 'Daily rituals');
    expect(plugin.summary, 'Daily fortune and the Solar Network check-in');
    expect(plugin.description, contains('check in for them'));
    // Eager: asked for in passing, so its tools are already there.
    expect(plugin.onDemand, isFalse);
    expect(plugin.enabledByDefault, isFalse);

    final prompt = plugin.systemPrompt(
      solarContext(solarDio(SolarStubAdapter({}))),
    );
    expect(prompt, hasLength(2));
    expect(prompt, anyElement(contains('the app picks one')));
    expect(prompt, anyElement(contains('once a day')));
    expect(prompt, anyElement(contains('unprompted')));
  });
}
