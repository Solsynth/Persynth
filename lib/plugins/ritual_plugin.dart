/// The user's Solar Network daily ritual, as tools.
///
/// Three small calls: the saying the day assigned them, whether today's
/// check-in has been claimed, and claiming it. They ride on every run rather
/// than waiting to be activated — three one-line definitions cost almost
/// nothing, and "what is my fortune today?" is asked in passing, not as a
/// request the companion should answer only after going to look for a skill.
///
/// The check-in is the one thing here that changes the account, and it is
/// worth its own tool even though [today_check_in] already reads the same
/// endpoint: a read the model can do freely and a write it should only do on
/// request are different decisions, and the prompt fragment says which is
/// which.
library;

import 'package:solar_network_sdk/solar_network_sdk.dart';

import 'package:persynth/personality/local_tool.dart';
import 'package:persynth/plugins/plugin.dart';
import 'package:persynth/plugins/solar_support.dart';

class RitualPlugin extends SnPlugin {
  const RitualPlugin();

  @override
  String get id => 'ritual';

  @override
  String get label => 'Daily rituals';

  @override
  String get description =>
      'Reads the user\'s daily fortune and Solar Network check-in, and can '
      'check in for them.';

  @override
  String get summary => 'Daily fortune and the Solar Network check-in';

  @override
  List<SnLocalTool> buildTools(SnPluginContext context) {
    final accounts = context.solar.accounts;
    return [
      SnLocalTool(
        name: 'daily_fortune',
        description:
            'The fortune saying Solar Network assigned the user for today, '
            'with where it comes from. The same saying holds for the whole '
            'day, so read it once and answer from it.',
        parameters: {'type': 'object', 'properties': <String, dynamic>{}},
        execute: (arguments) => solarToolResult(() async {
          return _saying(await accounts.getDailyFortune());
        }),
      ),
      SnLocalTool(
        name: 'today_check_in',
        description:
            'Whether the user has claimed today\'s Solar Network check-in, and '
            'what the day gave them when they have. A `checked_in` of false is '
            'an unclaimed day waiting to be claimed, not a failed call.',
        parameters: {'type': 'object', 'properties': <String, dynamic>{}},
        execute: (arguments) => solarToolResult(() async {
          try {
            return _checkIn(await _claimedToday(accounts));
          } on TypeError {
            return _unreadable;
          }
        }),
      ),
      SnLocalTool(
        name: 'check_in',
        description:
            'Claims today\'s Solar Network check-in for the user and returns '
            'what it earned them. A day can be claimed once, so a day already '
            'claimed is refused rather than claimed again.',
        parameters: {'type': 'object', 'properties': <String, dynamic>{}},
        execute: (arguments) => solarToolResult(() async {
          return _checkIn(await accounts.checkIn());
        }),
      ),
    ];
  }

  @override
  List<String> systemPrompt(SnPluginContext context) => const [
    'The fortune here is the saying the day assigned the user, drawn for them '
    'rather than written by you: read it as the day\'s fortune, quote it as '
    'it stands, and do not pass its words off as your own advice.',
    'The check-in can be claimed once a day. Claiming it for the user is a '
    'small favour to do when they ask for it — it is not something to do '
    'unprompted on every run.',
  ];
}

/// Today's check-in, or null when the day is unclaimed.
///
/// The endpoint answers `404` until the day is claimed, which the client turns
/// into the null its signature promises. A `200` with no payload is a
/// different thing: the client asserts its payload is present
/// (`response.data!`), so that case throws rather than answering, and the
/// throw is left to `_unreadable` to name. Guessing "unclaimed" there would be
/// the worse answer of the two — the model would offer the user a check-in
/// they have already claimed, and the call would fail in their face.
Future<SnCheckInResult?> _claimedToday(AccountsApi accounts) =>
    accounts.getCheckInResultToday();

/// The read that could not be answered, stated as what happened.
///
/// A payload the client cannot read is a defect in the client rather than a
/// state of the account, so it is not absorbed into an answer. The suggested
/// next step is [SnPlugin]-side honesty: the claim itself reads the same
/// endpoint and does not need the payload this read did.
const Map<String, dynamic> _unreadable = {
  'error':
      'Solar Network answered the check-in read without a result, so whether '
      'today is claimed is unknown. Calling check_in settles it.',
};

/// The day's saying, as the model should read it.
///
/// The saying carries the language it was drawn in: knowing which one it is
/// keeps the model from quoting it as something said in the conversation's own
/// language. The wire fills an unused field with an empty string, and an empty
/// line is context spent on nothing.
Map<String, dynamic> _saying(SnFortuneSaying fortune) => {
  'saying': fortune.content,
  'source': fortune.source,
  'language': fortune.language,
}..removeWhere((_, value) => value is String && value.trim().isEmpty);

/// One check-in as the model should read it: what the day gave the user, or
/// the fact that today is still unclaimed.
///
/// The read and the claim answer in the same shape, so the model cannot take a
/// stale read for a fresh claim: `claimed_at` is what says when the day was
/// claimed, and the level, the tips and the report are what it came with.
Map<String, dynamic> _checkIn(SnCheckInResult? result) {
  if (result == null) return {'checked_in': false};
  final report = result.fortuneReport;
  return {
    'checked_in': true,
    'level': result.level,
    'claimed_at': solarStamp(result.createdAt),
    'tips': [
      for (final tip in result.tips)
        {
          'positive': tip.isPositive,
          'title': tip.title,
          'content': tip.content,
        },
    ],
    if (report != null) 'fortune': _report(report),
  };
}

/// The report the check-in came with, which is the part the user actually
/// reads: the poem, the reading, and the day's lucky and unlucky things.
///
/// The version is the generator's, not the user's, and a slot the generator
/// left empty carries nothing a reader can use, so neither is passed on.
Map<String, dynamic> _report(SnCheckInFortuneReport report) => {
  'poem': report.poem,
  'summary': report.summary,
  'detail': report.summaryDetail,
  'wish': report.wish,
  'love': report.love,
  'study': report.study,
  'career': report.career,
  'health': report.health,
  'lost_item': report.lostItem,
  'lucky_color': report.luckyColor,
  'lucky_direction': report.luckyDirection,
  'lucky_time': report.luckyTime,
  'lucky_item': report.luckyItem,
  'lucky_action': report.luckyAction,
  'avoid_action': report.avoidAction,
  'ritual': report.ritual,
}..removeWhere((_, value) => value is String && value.trim().isEmpty);
