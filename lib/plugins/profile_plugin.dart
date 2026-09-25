/// The user's Solar Network account and standing, as read-only tools.
///
/// Tells the companion who it is talking to — the username to address them by,
/// their display name, their level, their credits and their achievements — and
/// lets it look up someone else's public profile. Nothing here writes: the
/// grant is the reading of account data, so switching this on cannot change an
/// account, and the prompt says so rather than leaving the model to infer it.
///
/// On demand: four definitions cost context on every request, and an identity
/// fact is needed occasionally rather than in a burst.
library;

import 'package:solar_network_sdk/solar_network_sdk.dart';

import 'package:persynth/personality/local_tool.dart';
import 'package:persynth/plugins/plugin.dart';
import 'package:persynth/plugins/solar_support.dart';

/// How many characters of a bio the model is given.
///
/// A bio is prose a person wrote for other people to read, so the opening is
/// the part that carries meaning; the rest is marked as cut rather than spent
/// on the context window.
const int _bioChars = 300;

/// Where the account's progression lives.
///
/// The typed client's `getAchievementState` reads
/// `/passport/progression/achievements` as a single record, which the service
/// does not serve: the achievements list and its totals sit under
/// `/passport/accounts/me/progression/achievements` (and `/stats`), the same
/// paths the app's own progression page reads. The paths are written out here,
/// and both answers are still parsed into the SDK's own models, so an upstream
/// field rename stays a compile error rather than a silent empty result.
const String _achievementsPath = '/passport/accounts/me/progression/achievements';

class ProfilePlugin extends SnPlugin {
  const ProfilePlugin();

  @override
  String get id => 'profile';

  @override
  String get label => 'Profile & standing';

  @override
  String get description =>
      'Reads the signed-in Solar Network account, other accounts, social '
      'credits and achievements.';

  @override
  String get summary =>
      'Look up the user\'s account, other accounts, credits and achievements';

  @override
  bool get onDemand => true;

  /// The two lookups the server also offers.
  ///
  /// Not claimed: `get_my_leveling`, which is a different thing from the
  /// achievements and credits read here — a level and its history, not what
  /// has been unlocked.
  @override
  Map<String, String> get overrides => const {
    'get_current_user_profile': 'whoami',
    'get_user_profile': 'read_account',
  };

  @override
  List<SnLocalTool> buildTools(SnPluginContext context) {
    final accounts = context.solar.accounts;
    final dio = context.solar.dio;
    return [
      SnLocalTool(
        name: 'whoami',
        description:
            'The signed-in Solar Network account: the username to address the '
            'user by, their display name and the date they joined. Read it '
            'whenever an answer depends on who the user is, rather than '
            'assuming a name.',
        parameters: {'type': 'object', 'properties': <String, dynamic>{}},
        execute: (arguments) => solarToolResult(() async {
          return _identity(await accounts.getCurrentAccount());
        }),
      ),
      SnLocalTool(
        name: 'read_account',
        description:
            'Another Solar Network account by username: the public profile and '
            'the standing it carries — level, credits, active badge, bio. '
            'Takes the username as it appears in a profile URL, without the '
            'leading @.',
        parameters: {
          'type': 'object',
          'properties': {
            'username': {
              'type': 'string',
              'description': 'The account username, e.g. "littleSheep".',
            },
          },
          'required': ['username'],
        },
        execute: (arguments) => solarToolResult(() async {
          final username = solarText(arguments, 'username');
          if (username == null) return _missing('username');
          final account = await accounts.getAccountByUsername(username);
          return {..._identity(account), ..._standing(account.profile)};
        }),
      ),
      SnLocalTool(
        name: 'social_credits',
        description:
            'The user\'s current Solar Network social credit balance: one '
            'number that rises and falls with their activity on the network. '
            'Read it when they ask about their score, rather than estimating '
            'one from anything else.',
        parameters: {'type': 'object', 'properties': <String, dynamic>{}},
        execute: (arguments) => solarToolResult(() async {
          return {'credits': await accounts.getSocialCredits()};
        }),
      ),
      SnLocalTool(
        name: 'achievements',
        description:
            'The user\'s Solar Network achievement progress: what they have '
            'unlocked, what is still in progress, and the totals across every '
            'achievement.',
        parameters: {'type': 'object', 'properties': <String, dynamic>{}},
        execute: (arguments) => solarToolResult(() async {
          // The list goes first and the totals second, rather than both at
          // once: a refused list would otherwise leave a second request in
          // flight whose error nobody reads, which surfaces as a crash the run
          // has to absorb. One extra round trip on a rarely-called read is the
          // cheaper trade.
          final states = (await dio.get<List<dynamic>>(_achievementsPath)).data!
              .map(
                (json) =>
                    SnAchievementState.fromJson(json as Map<String, dynamic>),
              )
              .toList();
          final counts = SnAchievementStats.fromJson(
            (await dio.get<Map<String, dynamic>>('$_achievementsPath/stats'))
                .data!,
          );
          return _progress(states, counts);
        }),
      ),
    ];
  }

  @override
  List<String> systemPrompt(SnPluginContext context) => const [
    'The user\'s Solar Network account tools are loaded: local_whoami, '
    'local_read_account, local_social_credits and local_achievements. They are '
    'read-only facts about the user\'s own account and other people\'s public '
    'profiles, and they change nothing.',
    'A username is not an id: use the username a tool returned, as the server '
    'spells it, rather than inventing one or reading an id as a name.',
  ];
}

/// One account as the model reads it: who this is, and how to name them.
Map<String, dynamic> _identity(SnAccount account) => {
  'id': account.id,
  'username': account.name,
  'display_name': account.nick,
  'bio': solarClip(account.profile.bio, limit: _bioChars),
  'created_at': solarStamp(account.createdAt),
};

/// The standing the account's profile already carries.
///
/// Both account endpoints answer with the profile embedded, so the level, the
/// balance and the active badge arrive with the name in one request — a second
/// profile lookup would fetch fields that are already in hand.
Map<String, dynamic> _standing(SnAccountProfile profile) {
  final badge = profile.activeBadge?.label;
  return {
    'level': profile.level,
    'credits': profile.socialCredits,
    'credits_level': profile.socialCreditsLevel,
    'verified': profile.verification != null,
    if (badge != null && badge.isNotEmpty) 'badge': badge,
  };
}

/// The achievement state as the model reads it.
///
/// Every record carries its reward definition and its whole series of stages;
/// a long-lived account has dozens of them, and none of that detail changes
/// the answer to "what have I unlocked". Only the title, where it stands and
/// when it completed are kept, split by whether it is done.
Map<String, dynamic> _progress(
  List<SnAchievementState> achievements,
  SnAchievementStats counts,
) => {
  'counts': {
    'total': counts.totalCount,
    'completed': counts.completedCount,
    'hidden_total': counts.hiddenTotalCount,
    'hidden_completed': counts.hiddenCompletedCount,
    'completion_percent': counts.completionPercentage,
  },
  'unlocked': [
    for (final achievement in achievements)
      if (achievement.isCompleted) _achievement(achievement),
  ],
  'in_progress': [
    for (final achievement in achievements)
      if (!achievement.isCompleted) _achievement(achievement),
  ],
};

/// One achievement, down to where it stands.
Map<String, dynamic> _achievement(SnAchievementState achievement) => {
  'identifier': achievement.identifier,
  'title': achievement.title,
  'progress': '${achievement.progressCount}/${achievement.targetCount}',
  if (achievement.completedAt != null)
    'completed_at': solarStamp(achievement.completedAt),
  if (achievement.seriesTitle != null) 'series': achievement.seriesTitle,
};

/// A blank or absent required argument, reported so the model can retry.
///
/// Returning this rather than throwing keeps a malformed call a turn the model
/// can fix, instead of a tool that appears broken.
Map<String, dynamic> _missing(String argument) => {
  'error': 'The "$argument" argument is required.',
};
