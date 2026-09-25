import 'package:flutter_test/flutter_test.dart';
import 'package:persynth/plugins/profile_plugin.dart';

import 'solar_test_support.dart';

/// The plugin builds its tools once per context, so each test builds the set
/// over its own adapter and reaches for the tool it is about.
void main() {
  const plugin = ProfilePlugin();

  Future<Map<String, dynamic>> run(
    SolarStubAdapter adapter,
    String tool, [
    Map<String, dynamic> arguments = const {},
  ]) async {
    final built = solarTool(
      plugin.buildTools(solarContext(solarDio(adapter))),
      tool,
    );
    return solarResult(await built.execute(arguments));
  }

  test('whoami reads the signed-in account and answers with its identity', () async {
    final adapter = SolarStubAdapter({
      'GET /stargate/accounts/me': accountJson(),
    });

    final result = await run(adapter, 'whoami');

    final request = adapter.requests.single;
    expect(request.method, 'GET');
    expect(request.path, '/stargate/accounts/me');
    expect(result, {
      'id': 'acc-1',
      'username': 'littleSheep',
      'display_name': 'Little Sheep',
      'bio': 'builds things',
      'created_at': '2024-03-01T08:00:00Z',
    });
  });

  test('read_account fetches the account once and keeps the standing it carries', () async {
    final adapter = SolarStubAdapter({
      'GET /stargate/accounts/littleSheep': accountJson(
        badge: 'Early Bird',
        verified: true,
        credits: 180.5,
      ),
    });

    final result = await run(adapter, 'read_account', {
      'username': 'littleSheep',
    });

    // The profile rides on the account object, so a second profile lookup
    // would re-fetch fields already in hand.
    final request = adapter.requests.single;
    expect(request.method, 'GET');
    expect(request.path, '/stargate/accounts/littleSheep');
    expect(result, {
      'id': 'acc-1',
      'username': 'littleSheep',
      'display_name': 'Little Sheep',
      'bio': 'builds things',
      'created_at': '2024-03-01T08:00:00Z',
      'level': 12,
      'credits': 180.5,
      'credits_level': 2,
      'verified': true,
      'badge': 'Early Bird',
    });
  });

  test('an account with no active badge carries no badge key', () async {
    final adapter = SolarStubAdapter({
      'GET /stargate/accounts/ada': accountJson(name: 'ada', nick: 'Ada'),
    });

    final result = await run(adapter, 'read_account', {'username': 'ada'});

    expect(result.containsKey('badge'), isFalse);
    expect(result['verified'], isFalse);
    expect(result['username'], 'ada');
  });

  test('an unknown username reads as nothing there, not as a thrown failure', () async {
    final adapter = SolarStubAdapter(
      {'GET /stargate/accounts/nobody': {'message': 'no account "nobody"'}},
      statuses: {'GET /stargate/accounts/nobody': 404},
    );

    final result = await run(adapter, 'read_account', {'username': 'nobody'});

    expect(result['error'], contains('there is no such item'));
    expect(result['error'], contains('HTTP 404'));
    expect(result['error'], contains('no account "nobody"'));
  });

  test('a blank username is reported, not called', () async {
    final adapter = SolarStubAdapter({});

    final result = await run(adapter, 'read_account', {'username': '   '});

    expect(result['error'], contains('"username"'));
    expect(adapter.requests, isEmpty);
  });

  test('a long bio is clipped and marked', () async {
    final adapter = SolarStubAdapter({
      'GET /stargate/accounts/me': accountJson(bio: 'x' * 500),
    });

    final result = await run(adapter, 'whoami');

    expect(result['bio'], endsWith('… [truncated]'));
    expect((result['bio'] as String).length, lessThan(400));
  });

  test('social_credits reads the balance from the account endpoint', () async {
    final adapter = SolarStubAdapter({
      'GET /passport/accounts/me/credits': 180.5,
    });

    final result = await run(adapter, 'social_credits');

    final request = adapter.requests.single;
    expect(request.method, 'GET');
    expect(request.path, '/passport/accounts/me/credits');
    expect(result, {'credits': 180.5});
  });

  test('achievements splits unlocked from in progress and reports the totals', () async {
    final adapter = SolarStubAdapter({
      'GET /passport/accounts/me/progression/achievements': [
        achievementJson(
          identifier: 'first_post',
          title: 'First Post',
          target: 1,
          progress: 1,
          completed: true,
          completedAt: '2024-04-01T09:30:00.000Z',
          seriesTitle: 'Welcome',
        ),
        achievementJson(
          identifier: 'ten_posts',
          title: 'Ten Posts',
          target: 10,
          progress: 3,
        ),
        // A long-lived account has dozens more records, each with a reward and
        // its series stages; the projection must not grow with them.
        for (var i = 0; i < 40; i++)
          achievementJson(identifier: 'filler_$i', title: 'Filler $i', progress: i),
      ],
      'GET /passport/accounts/me/progression/achievements/stats': {
        'total_count': 42,
        'completed_count': 1,
        'hidden_total_count': 4,
        'hidden_completed_count': 1,
        'completion_percentage': 2.38,
      },
    });

    final result = await run(adapter, 'achievements');

    expect(adapter.requests.map((request) => '${request.method} ${request.path}'), [
      'GET /passport/accounts/me/progression/achievements',
      'GET /passport/accounts/me/progression/achievements/stats',
    ]);

    expect(result['counts'], {
      'total': 42,
      'completed': 1,
      'hidden_total': 4,
      'hidden_completed': 1,
      'completion_percent': 2.38,
    });

    final unlocked = result['unlocked'] as List;
    final inProgress = result['in_progress'] as List;
    expect(unlocked, hasLength(1));
    expect(inProgress, hasLength(41));
    expect(unlocked.single, {
      'identifier': 'first_post',
      'title': 'First Post',
      'progress': '1/1',
      'completed_at': '2024-04-01T09:30:00Z',
      'series': 'Welcome',
    });
    expect(inProgress.first, {
      'identifier': 'ten_posts',
      'title': 'Ten Posts',
      'progress': '3/10',
    });
    // The keys are the contract: no reward definition, no series stages, and
    // no growth with the number of records.
    expect(
      (inProgress.last as Map).keys.toSet(),
      {'identifier', 'title', 'progress'},
    );
  });

  test('a refused progression read is reported, and stops after one request', () async {
    final adapter = SolarStubAdapter(
      {
        'GET /passport/accounts/me/progression/achievements': {
          'message': 'scope accounts.read is missing',
        },
      },
      statuses: {'GET /passport/accounts/me/progression/achievements': 403},
    );

    final result = await run(adapter, 'achievements');

    expect(result['error'], contains('not allowed'));
    expect(result['error'], contains('scope accounts.read is missing'));
    expect(adapter.requests, hasLength(1));
  });

  test('the plugin is on demand and read-only end to end', () {
    final context = solarContext(solarDio(SolarStubAdapter({})));

    expect(plugin.id, 'profile');
    expect(plugin.label, 'Profile & standing');
    expect(plugin.onDemand, isTrue);
    expect(plugin.enabledByDefault, isFalse);
    expect(
      plugin.description,
      'Reads the signed-in Solar Network account, other accounts, social '
      'credits and achievements.',
    );
    expect(
      plugin.buildTools(context).map((tool) => tool.name),
      ['whoami', 'read_account', 'social_credits', 'achievements'],
    );

    final prompt = plugin.systemPrompt(context);
    expect(prompt, hasLength(2));
    expect(prompt.first, contains('read-only'));
    expect(prompt.first, contains('change nothing'));
    expect(prompt.last, contains('username'));
    expect(prompt.last, contains('not an id'));
  });
}

/// One account as Stargate answers it: the identity plus the profile row it
/// embeds, which is where the level, the balance and the badge live.
Map<String, dynamic> accountJson({
  String id = 'acc-1',
  String name = 'littleSheep',
  String nick = 'Little Sheep',
  String bio = 'builds things',
  int level = 12,
  double credits = 180.5,
  int creditsLevel = 2,
  String? badge,
  bool verified = false,
}) {
  return {
    'id': id,
    'name': name,
    'nick': nick,
    'language': 'en-US',
    'is_superuser': false,
    'automated_id': null,
    'profile': {
      'id': 'profile-$id',
      'bio': bio,
      'experience': 2400,
      'level': level,
      'social_credits': credits,
      'social_credits_level': creditsLevel,
      'leveling_progress': 0.42,
      if (badge != null) 'active_badge': badgeJson(label: badge, accountId: id),
      if (verified)
        'verification': {
          'type': 1,
          'title': 'Verified',
          'description': null,
          'verified_by': null,
        },
      'created_at': '2024-03-01T08:00:00.000Z',
      'updated_at': '2024-03-01T08:00:00.000Z',
    },
    'badges': <Object>[],
    'activated_at': '2024-03-01T08:00:00.000Z',
    'created_at': '2024-03-01T08:00:00.000Z',
    'updated_at': '2024-03-01T08:00:00.000Z',
  };
}

Map<String, dynamic> badgeJson({
  required String label,
  required String accountId,
}) => {
  'id': 'badge-1',
  'type': 'early_bird',
  'label': label,
  'caption': 'joined early',
  'meta': <String, dynamic>{},
  'expired_at': null,
  'account_id': accountId,
  'activated_at': '2024-03-02T08:00:00.000Z',
  'created_at': '2024-03-02T08:00:00.000Z',
  'updated_at': '2024-03-02T08:00:00.000Z',
  'deleted_at': null,
};

/// One achievement as the progression service answers it, reward and series
/// stages included, because the point of the projection is to drop them.
Map<String, dynamic> achievementJson({
  required String identifier,
  required String title,
  int target = 10,
  int progress = 0,
  bool completed = false,
  String? completedAt,
  String? seriesTitle,
}) => {
  'identifier': identifier,
  'title': title,
  'summary': 'A sentence the model does not need in full.',
  'icon': 'trophy',
  'sort_order': 1,
  'hidden': false,
  'is_enabled': true,
  'target_count': target,
  'progress_count': progress,
  'is_completed': completed,
  'completed_at': completedAt,
  'reward': {
    'experience': 50,
    'source_points': 10,
    'source_points_currency': 'points',
    'badge': {'type': 'early_bird', 'label': 'Early Bird'},
  },
  'series_identifier': seriesTitle == null ? null : 'series-welcome',
  'series_title': seriesTitle,
  'series_order': 1,
  'series_total_steps': 3,
  'series_completed_steps': 1,
  'series_stages': [
    for (var i = 0; i < 4; i++)
      {'identifier': 'stage-$i', 'title': 'Stage $i', 'series_order': i},
  ],
};
