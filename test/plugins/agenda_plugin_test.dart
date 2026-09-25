import 'package:flutter_test/flutter_test.dart';
import 'package:persynth/plugins/agenda_plugin.dart';

import 'solar_test_support.dart';

/// The plugin builds its tools once per context, so each test builds the set
/// over its own adapter and reaches for the tool it is about.
void main() {
  const plugin = AgendaPlugin();

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

  test('read_agenda asks for the month and projects its events', () async {
    final adapter = SolarStubAdapter({
      'GET /passport/accounts/me/calendar': [
        _dayJson(
          events: [
            _eventJson(
              id: 'e1',
              title: 'Standup',
              start: '2026-09-02T10:00:00Z',
              end: '2026-09-02T10:15:00Z',
            ),
          ],
        ),
        _dayJson(
          date: '2026-09-21T00:00:00Z',
          events: [
            _eventJson(
              id: 'e2',
              title: 'Dentist',
              description: 'bring the x-ray',
              location: 'Riverside Clinic',
              // The user thinks in their own offset; the wire is UTC.
              start: '2026-09-21T09:00:00+08:00',
              end: '2026-09-21T10:00:00+08:00',
            ),
          ],
        ),
      ],
    });

    final result = await run(adapter, 'read_agenda', {'year': 2026, 'month': 9});

    expect(
      adapter.request('GET', '/passport/accounts/me/calendar').queryParameters,
      {'year': 2026, 'month': 9, 'includeNotableDays': false},
    );
    expect(result['year'], 2026);
    expect(result['month'], 9);
    // Whole maps, so a field the projection was supposed to drop fails here.
    expect(result['events'], [
      {
        'id': 'e1',
        'title': 'Standup',
        'start': '2026-09-02T10:00:00Z',
        'end': '2026-09-02T10:15:00Z',
      },
      {
        'id': 'e2',
        'title': 'Dentist',
        'start': '2026-09-21T01:00:00Z',
        'end': '2026-09-21T02:00:00Z',
        'location': 'Riverside Clinic',
        'description': 'bring the x-ray',
      },
    ]);
  });

  test('read_agenda defaults to the current month', () async {
    final adapter = SolarStubAdapter({
      'GET /passport/accounts/me/calendar': <Object>[],
    });
    final now = DateTime.now();

    await run(adapter, 'read_agenda', {});

    expect(
      adapter.request('GET', '/passport/accounts/me/calendar').queryParameters,
      {'year': now.year, 'month': now.month, 'includeNotableDays': false},
    );

    adapter.requests.clear();
    // A model that passes the month as text still gets its month read.
    await run(adapter, 'read_agenda', {'year': 2026, 'month': '9'});
    expect(
      adapter.request('GET', '/passport/accounts/me/calendar').queryParameters,
      {'year': 2026, 'month': 9, 'includeNotableDays': false},
    );
  });

  test('a month with nothing on it answers with an empty list', () async {
    // The service answers with every day of the month, mostly empty, rather
    // than with a short list of days that have something on them.
    final adapter = SolarStubAdapter({
      'GET /passport/accounts/me/calendar': [
        _dayJson(date: '2026-09-01T00:00:00Z'),
        _dayJson(date: '2026-09-02T00:00:00Z'),
      ],
    });

    final result = await run(adapter, 'read_agenda', {'year': 2026, 'month': 9});

    expect(result['events'], isEmpty);
    expect(result.containsKey('error'), isFalse);
  });

  test('a month or year that is not one is refused before the wire', () async {
    final adapter = SolarStubAdapter({});

    final month = await run(adapter, 'read_agenda', {
      'year': 2026,
      'month': 13,
    });
    expect(month['error'], contains('"month"'));

    final year = await run(adapter, 'read_agenda', {'year': 'sometime'});
    expect(year['error'], contains('"year"'));

    expect(adapter.requests, isEmpty);
  });

  test('a long event note is clipped and marked', () async {
    final adapter = SolarStubAdapter({
      'GET /passport/accounts/me/calendar': [
        _dayJson(
          events: [_eventJson(id: 'e1', description: 'x' * 900)],
        ),
      ],
    });

    final result = await run(adapter, 'read_agenda', {'year': 2026, 'month': 9});
    final description = (result['events'] as List).single['description'] as String;

    expect(description, endsWith('… [truncated]'));
    expect(description.length, lessThan(500));
  });

  test('next_notable_day returns the day and its names', () async {
    final adapter = SolarStubAdapter({
      'GET /passport/notable/me/next': {
        'date': '2026-10-01T00:00:00.000Z',
        'local_name': '国庆节',
        'global_name': 'National Day',
        'country_code': 'CN',
        'localizable_key': 'holiday.national_day',
        // Holiday-type codes are the server's enum numbers; they name nothing.
        'holidays': [0],
      },
    });

    final result = await run(adapter, 'next_notable_day', {});

    expect(adapter.request('GET', '/passport/notable/me/next').method, 'GET');
    expect(result['notable_day'], {
      'date': '2026-10-01T00:00:00Z',
      'name': '国庆节',
      'global_name': 'National Day',
      'country_code': 'CN',
    });
  });

  test('next_notable_day answers with nothing rather than an error', () async {
    final adapter = SolarStubAdapter({'GET /passport/notable/me/next': null});

    final result = await run(adapter, 'next_notable_day', {});

    expect(result, {'notable_day': null});
    expect(adapter.request('GET', '/passport/notable/me/next').method, 'GET');
  });

  test('create_event sends the event and returns what was created', () async {
    final adapter = SolarStubAdapter({
      'POST /passport/accounts/me/calendar/events': _eventJson(
        id: 'new',
        title: 'Dentist',
        description: 'bring the x-ray',
        start: '2026-09-21T01:00:00Z',
        end: '2026-09-21T02:00:00Z',
      ),
    });

    final result = await run(adapter, 'create_event', {
      'title': 'Dentist',
      'start': '2026-09-21T09:00:00+08:00',
      'end': '2026-09-21T10:00:00+08:00',
      'description': 'bring the x-ray',
    });

    expect(
      adapter.request('POST', '/passport/accounts/me/calendar/events').data,
      {
        'title': 'Dentist',
        'start_time': '2026-09-21T01:00:00.000Z',
        'end_time': '2026-09-21T02:00:00.000Z',
        'description': 'bring the x-ray',
        'is_all_day': false,
        'visibility': 0,
        'tags': null,
      },
    );
    expect(result, {
      'id': 'new',
      'title': 'Dentist',
      'start': '2026-09-21T01:00:00Z',
      'end': '2026-09-21T02:00:00Z',
      'description': 'bring the x-ray',
    });
  });

  test('a time the model wrote as prose is refused before the wire', () async {
    final adapter = SolarStubAdapter({});

    final result = await run(adapter, 'create_event', {
      'title': 'Dentist',
      'start': 'next Tuesday',
      'end': '2026-09-21T10:00:00+08:00',
    });

    expect(result['error'], contains('"start"'));
    expect(result['error'], contains('ISO-8601'));
    expect(adapter.requests, isEmpty);
  });

  test('a blank required argument is reported, not called', () async {
    final adapter = SolarStubAdapter({});

    final result = await run(adapter, 'create_event', {
      'title': '   ',
      'start': '2026-09-21T09:00:00+08:00',
      'end': '2026-09-21T10:00:00+08:00',
    });

    expect(result['error'], contains('"title"'));
    expect(adapter.requests, isEmpty);

    // A time the model left out reads as the argument it did not give, not as
    // a time it wrote badly.
    final untimed = await run(adapter, 'create_event', {'title': 'Dentist'});

    expect(untimed['error'], contains('"start"'));
    expect(untimed['error'], contains('required'));
    expect(adapter.requests, isEmpty);
  });

  test('a 401 reads as a session to renew, not as a status code', () async {
    final adapter = SolarStubAdapter(
      {
        'GET /passport/accounts/me/calendar': {'message': 'token expired'},
      },
      statuses: {'GET /passport/accounts/me/calendar': 401},
    );

    final result = await run(adapter, 'read_agenda', {});

    expect(result['error'], contains('not signed in'));
    expect(result['error'], contains('token expired'));
  });

  test('the plugin is eager and offers its three tools in order', () {
    expect(plugin.id, 'agenda');
    expect(plugin.label, 'Calendar');
    expect(plugin.onDemand, isFalse);
    expect(plugin.enabledByDefault, isFalse);
    expect(plugin.description, contains('calendar'));
    expect(
      plugin
          .buildTools(solarContext(solarDio(SolarStubAdapter({}))))
          .map((tool) => tool.name),
      ['read_agenda', 'next_notable_day', 'create_event'],
    );
    expect(
      plugin.systemPrompt(solarContext(solarDio(SolarStubAdapter({})))),
      anyElement(contains('real Solar Network calendar')),
    );
  });
}

/// One calendar event as the API returns it: an event carries its account, its
/// visibility and its file references, and the wire fills in the ones this
/// plugin never looks at.
Map<String, dynamic> _eventJson({
  required String id,
  String title = 'Standup',
  String? description,
  String? location,
  String start = '2026-09-02T10:00:00Z',
  String end = '2026-09-02T10:15:00Z',
  bool allDay = false,
}) => {
  'id': id,
  'title': title,
  'description': description,
  'location': location,
  'start_time': start,
  'end_time': end,
  'is_all_day': allDay,
  'visibility': 0,
  'tags': <String>[],
  'account_id': 'acc-1',
  'created_at': '2026-09-01T00:00:00Z',
  'updated_at': '2026-09-01T00:00:00Z',
};

/// One day of the per-day calendar the month endpoint answers with.
Map<String, dynamic> _dayJson({
  String date = '2026-09-01T00:00:00Z',
  List<Map<String, dynamic>> events = const [],
}) => {
  'date': date,
  'check_in_result': null,
  'statuses': <Object>[],
  'user_events': events,
  'notable_days': <Object>[],
};
