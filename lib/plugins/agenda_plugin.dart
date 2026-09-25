/// The user's own Solar Network calendar, as tools.
///
/// Reads a month of events and the next notable day, and adds an event.
/// Reading and writing are one grant for the same reason the social plugin
/// keeps them together: switching this on says "this assistant may look at my
/// calendar and act on it", and a second switch for the write would suggest
/// the read is harmless.
///
/// Eager: three short definitions, and "what does my week look like" is a
/// question asked without preamble, so the tools ride on every run.
///
/// The month comes from the per-day calendar endpoint rather than the merged
/// one. The SDK's merged model declares `merged_events[].type` as a string
/// where the service emits the enum's number, so a month that contains
/// anything at all fails to parse before a plugin can project it. The per-day
/// response is the one the app's own calendar screen reads, and it carries the
/// same events.
library;

import 'package:solar_network_sdk/solar_network_sdk.dart';

import 'package:persynth/personality/local_tool.dart';
import 'package:persynth/plugins/plugin.dart';
import 'package:persynth/plugins/solar_support.dart';

/// How many characters of an event description the model is given.
///
/// Long enough for directions or an agenda in full, short enough that a
/// pasted document does not crowd out the rest of the calendar.
const int _descriptionChars = 400;

/// How many characters of an event location the model is given.
const int _locationChars = 200;

class AgendaPlugin extends SnPlugin {
  const AgendaPlugin();

  @override
  String get id => 'agenda';

  @override
  String get label => 'Calendar';

  @override
  String get description =>
      'Reads the user\'s Solar Network calendar and can add events to it.';

  @override
  String get summary => 'Read the calendar and add events';

  @override
  List<SnLocalTool> buildTools(SnPluginContext context) {
    final accounts = context.solar.accounts;
    return [
      SnLocalTool(
        name: 'read_agenda',
        description:
            'The user\'s Solar Network calendar for one month: the events on '
            'it, in date order, with their times, locations and notes. It '
            'includes what friends and accounts they subscribe to have shared '
            'with them, so an event may not be theirs to change. Defaults to '
            'the current month when no year or month is given. Times are UTC.',
        parameters: {
          'type': 'object',
          'properties': {
            'year': {
              'type': 'integer',
              'description': 'The year to read (default: the current year).',
            },
            'month': {
              'type': 'integer',
              'description':
                  'The month to read, 1-12 (default: the current month).',
            },
          },
        },
        execute: (arguments) => solarToolResult(() async {
          final month = _month(arguments);
          if (month == null) {
            return {
              'error': 'The "month" argument must be a number from 1 to 12.',
            };
          }
          final year = _year(arguments);
          if (year == null) {
            return {'error': 'The "year" argument must be a year as a number.'};
          }
          final days = await accounts.getEventCalendar(
            year: year,
            month: month,
          );
          return {
            'year': year,
            'month': month,
            'events': [
              for (final day in days)
                for (final event in day.userEvents) _event(event),
            ],
          };
        }),
      ),
      SnLocalTool(
        name: 'next_notable_day',
        description:
            'The next holiday or notable day on the user\'s Solar Network '
            'calendar: its date and name, in the region their account is set '
            'to. Answers with nothing when there is none, which is not a '
            'failure.',
        parameters: {'type': 'object', 'properties': <String, dynamic>{}},
        execute: (arguments) => solarToolResult(() async {
          // `getNextNotableDay` answers null for every failure, a session that
          // has expired included, so "there is none" and "the call did not
          // land" read the same here. The tool still answers rather than
          // erroring: having no notable day ahead is a normal answer, and the
          // model can read the calendar itself when it needs to be sure.
          final day = await accounts.getNextNotableDay();
          return {'notable_day': day == null ? null : _notableDay(day)};
        }),
      ),
      SnLocalTool(
        name: 'create_event',
        description:
            'Adds an event to the user\'s Solar Network calendar. It lands on '
            'their real calendar, so it appears on every device they are '
            'signed in on and other people they share it with. Timestamps are '
            'ISO-8601, e.g. "2026-09-21T09:00:00+08:00".',
        parameters: {
          'type': 'object',
          'properties': {
            'title': {
              'type': 'string',
              'description': 'The event title.',
            },
            'start': {
              'type': 'string',
              'description': 'When the event starts, as an ISO-8601 timestamp.',
            },
            'end': {
              'type': 'string',
              'description': 'When the event ends, as an ISO-8601 timestamp.',
            },
            'description': {
              'type': 'string',
              'description':
                  'Notes for the event, in the user\'s own words. Omit it '
                  'rather than inventing details.',
            },
          },
          'required': ['title', 'start', 'end'],
        },
        execute: (arguments) => solarToolResult(() async {
          final title = solarText(arguments, 'title');
          if (title == null) return _missing('title');
          final start = solarText(arguments, 'start');
          if (start == null) return _missing('start');
          final startTime = _timestamp(start);
          if (startTime == null) return _badTimestamp('start');
          final end = solarText(arguments, 'end');
          if (end == null) return _missing('end');
          final endTime = _timestamp(end);
          if (endTime == null) return _badTimestamp('end');
          return _event(
            await accounts.createCalendarEvent(
              title: title,
              startTime: startTime,
              endTime: endTime,
              description: solarText(arguments, 'description'),
            ),
          );
        }),
      ),
    ];
  }

  @override
  List<String> systemPrompt(SnPluginContext context) => const [
    'The calendar tools read and write the user\'s real Solar Network '
    'calendar: an event added there is on their calendar, visible on their '
    'other devices, and not something they have to confirm again.',
    'Quote the dates the user gave rather than guessing one. When they name a '
    'day without a year, ask, or use the year they are plainly talking about — '
    'an event filed under the wrong year is one they will miss.',
  ];
}

/// The month to read, or null when the model gave something that is not one.
///
/// A month outside 1-12 would come back as a rejected request the model can do
/// nothing with; catching it here names the argument and the range instead.
int? _month(Map<String, dynamic> arguments) {
  final raw = arguments['month'];
  if (raw == null) return DateTime.now().month;
  final month = raw is int ? raw : int.tryParse('$raw');
  return month == null || month < 1 || month > 12 ? null : month;
}

/// The year to read, defaulting to the current one, or null when the model
/// gave something that is not a year.
int? _year(Map<String, dynamic> arguments) {
  final raw = arguments['year'];
  if (raw == null) return DateTime.now().year;
  final year = raw is int ? raw : int.tryParse('$raw');
  return year == null || year < 1 ? null : year;
}

/// The moment a timestamp the model wrote names, or null when it is not a
/// timestamp at all.
///
/// `DateTime.parse` throws on prose, and a throw here would end the run rather
/// than the call: the model gets one turn to write a real time instead.
DateTime? _timestamp(String text) => DateTime.tryParse(text);

/// One calendar event projected to the fields a reader would see.
///
/// A user event arrives with its account, its icon and background file
/// references, its tags and its recurrence rule. The model needs the event,
/// not the account graph around it.
Map<String, dynamic> _event(SnUserCalendarEvent event) => {
  'id': event.id,
  'title': event.title,
  'start': solarStamp(event.startTime),
  'end': solarStamp(event.endTime),
  'all_day': event.isAllDay,
  'location': solarClip(event.location, limit: _locationChars),
  'description': solarClip(event.description, limit: _descriptionChars),
}
  // Optional fields arrive as nulls and empty strings; `all_day: false` is the
  // default rather than a fact worth spending context on.
  ..removeWhere(_saysNothing);

/// A notable day without its holiday-type codes: they are the server's enum
/// numbers, which name nothing to a reader.
Map<String, dynamic> _notableDay(SnNotableDay day) => {
  'date': solarStamp(day.date),
  'name': day.localName,
  'global_name': day.globalName,
  'country_code': day.countryCode,
}..removeWhere(_saysNothing);

/// Whether a projected field carries nothing: absent, empty, or off.
bool _saysNothing(String key, Object? value) =>
    value == null ||
    (value is bool && !value) ||
    (value is num && value == 0) ||
    (value is String && value.isEmpty) ||
    (value is Iterable && value.isEmpty) ||
    (value is Map && value.isEmpty);

/// A blank or absent required argument, reported so the model can retry.
Map<String, dynamic> _missing(String argument) => {
  'error': 'The "$argument" argument is required.',
};

/// A time the model wrote as prose, or made up, reported with the shape to use.
Map<String, dynamic> _badTimestamp(String argument) => {
  'error':
      'The "$argument" argument must be an ISO-8601 timestamp, such as '
      '"2026-09-21T09:00:00+08:00".',
};
