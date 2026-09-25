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

  /// One claimed check-in as the API returns it, with most of the report's
  /// slots empty the way the generator leaves the ones it did not use.
  Map<String, Object?> claimedJson() => {
    'id': 'ci-1',
    'level': 4,
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
  /// slots are dropped, and nothing else is.
  Map<String, dynamic> claimedExpected() => {
    'checked_in': true,
    'level': 4,
    'claimed_at': '2026-09-26T01:05:00Z',
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

  test('daily_fortune reads the day\'s saying and where it came from', () async {
    final adapter = SolarStubAdapter({
      'GET /passport/fortune/daily': {
        'content': 'A closed door is a wall you have not leaned on.',
        'source': 'Sun Tzu, apocryphal',
        'language': 'en',
      },
    });

    final result = await run(adapter, 'daily_fortune', {});

    expect(
      adapter.request('GET', '/passport/fortune/daily').queryParameters,
      isEmpty,
    );
    expect(result, {
      'saying': 'A closed door is a wall you have not leaned on.',
      'source': 'Sun Tzu, apocryphal',
      'language': 'en',
    });
  });

  test('daily_fortune reports a session to renew rather than a status', () async {
    final adapter = SolarStubAdapter(
      {
        'GET /passport/fortune/daily': {'message': 'token expired'},
      },
      statuses: {'GET /passport/fortune/daily': 401},
    );

    final result = await run(adapter, 'daily_fortune', {});

    expect(result['error'], contains('not signed in'));
    expect(result['error'], contains('token expired'));
  });

  test('today_check_in reads a 404 as an unclaimed day', () async {
    // A 200 carrying no payload is not a state of the account — the client
    // asserts a payload is present — so it is named rather than guessed at,
    // and the model is told the read could not be answered.
    final bodyless = SolarStubAdapter({
      'GET /passport/accounts/me/check-in': null,
    });
    final unreadable = await run(bodyless, 'today_check_in', {});
    expect(unreadable['error'], contains('without a result'));
    expect(unreadable.containsKey('checked_in'), isFalse);
    expect(
      bodyless.request('GET', '/passport/accounts/me/check-in').queryParameters,
      {'version': 2},
    );

    final unclaimed = SolarStubAdapter(
      {
        'GET /passport/accounts/me/check-in': {'message': 'no check-in today'},
      },
      statuses: {'GET /passport/accounts/me/check-in': 404},
    );
    expect(await run(unclaimed, 'today_check_in', {}), {'checked_in': false});
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

  test('today_check_in still reports a refusal as a failure', () async {
    // Nothing but a missing payload counts as an unclaimed day: a refusal on
    // the way there is an answer the model has to be able to read as one.
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

  test('check_in claims the day and returns what it earned', () async {
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
          'message': 'already checked in today',
        },
      },
      statuses: {'POST /passport/accounts/me/check-in': 403},
    );

    final result = await run(adapter, 'check_in', {});

    expect(result['error'], contains('not allowed'));
    expect(result['error'], contains('already checked in today'));
  });

  test('the plugin offers its three tools in reading order', () {
    final tools = plugin.buildTools(solarContext(solarDio(SolarStubAdapter({}))));

    expect(tools.map((tool) => tool.name), [
      'daily_fortune',
      'today_check_in',
      'check_in',
    ]);
  });

  test('the plugin is eager, and the day\'s fortune is not mine to rewrite', () {
    expect(plugin.id, 'ritual');
    expect(plugin.label, 'Daily rituals');
    expect(plugin.summary, 'Daily fortune and the Solar Network check-in');
    expect(plugin.description, contains('check in for them'));
    // Eager: asked for in passing, so its tools are already there.
    expect(plugin.onDemand, isFalse);
    expect(plugin.enabledByDefault, isFalse);

    final prompt = plugin.systemPrompt(solarContext(solarDio(SolarStubAdapter({}))));
    expect(prompt, hasLength(2));
    expect(prompt, anyElement(contains('the day assigned')));
    expect(prompt, anyElement(contains('once a day')));
    expect(prompt, anyElement(contains('unprompted')));
  });
}
