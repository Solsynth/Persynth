import 'package:flutter_test/flutter_test.dart';
import 'package:persynth/plugins/agenda_plugin.dart';

import 'solar_test_support.dart';

/// One merged event as the service returns it.
Map<String, dynamic> eventJson({
  required String id,
  String? title = 'Standup',
  int type = 0,
  String start = '2026-09-24T09:00:00.000Z',
  String end = '2026-09-24T09:30:00.000Z',
  bool allDay = false,
  String? location,
  String? description,
}) => {
  'id': id,
  'type': type,
  'title': title,
  'start_time': start,
  'end_time': end,
  'is_all_day': allDay,
  'location': location,
  'description': description,
};

/// One notable day as the service returns it.
Map<String, dynamic> notableJson({
  required String name,
  required String localName,
  required String start,
  bool recurring = false,
}) => {
  'id': 'day-$name',
  'name': name,
  'local_name': localName,
  'description': '$name description',
  'start_date': start,
  'end_date': start,
  'is_all_day': true,
  'region': 'CN',
  'is_recurring': recurring,
};

void main() {
  const plugin = AgendaPlugin();

  Future<Map<String, dynamic>> run(
    SolarStubAdapter adapter,
    String tool,
    Map<String, dynamic> arguments,
  ) async {
    final built = solarTool(plugin.buildTools(solarContext(solarDio(adapter))), tool);
    return solarResult(await built.execute(arguments));
  }

  test('read_agenda asks the merged month and projects the events', () async {
    final adapter = SolarStubAdapter({
      'GET /passport/accounts/me/calendar/merged': {
        'date': '2026-09-01T00:00:00.000Z',
        'merged_events': [
          eventJson(id: 'e1'),
          eventJson(
            id: 'e2',
            title: 'Spring Festival',
            type: 3,
            allDay: true,
            location: 'Everywhere',
          ),
        ],
        'user_events': [eventJson(id: 'ignored', title: 'narrower list')],
      },
    });

    final result = await run(adapter, 'read_agenda', {'year': 2026, 'month': 9});

    expect(
      adapter.request('GET', '/passport/accounts/me/calendar/merged').queryParameters,
      {'year': 2026, 'month': 9},
    );
    final events = result['events'] as List;
    expect(events, hasLength(2));
    expect(events.first, {
      'id': 'e1',
      'kind': 'user_event',
      'title': 'Standup',
      'start': '2026-09-24T09:00:00Z',
      'end': '2026-09-24T09:30:00Z',
    });
    // The `type` switch is a number on the wire; the reader gets the word.
    expect(events.last['kind'], 'notable_day');
    expect(events.last['all_day'], isTrue);
    expect(events.last['location'], 'Everywhere');
  });

  test('read_agenda defaults to the current month', () async {
    final adapter = SolarStubAdapter({
      'GET /passport/accounts/me/calendar/merged': {'merged_events': <Object>[]},
    });

    final result = await run(adapter, 'read_agenda', {});

    final now = DateTime.now();
    expect(
      adapter.request('GET', '/passport/accounts/me/calendar/merged').queryParameters,
      {'year': now.year, 'month': now.month},
    );
    expect(result['month'], now.month);
    expect(result['events'], isEmpty);
  });

  test('a month or year that is not one is refused before the wire', () async {
    final adapter = SolarStubAdapter({});

    expect((await run(adapter, 'read_agenda', {'month': 13}))['error'], contains('1-12'));
    expect((await run(adapter, 'read_agenda', {'year': 0}))['error'], contains('year'));
    expect(adapter.requests, isEmpty);
  });

  test('next_notable_day reads the global list and picks the soonest', () async {
    final adapter = SolarStubAdapter({
      'GET /passport/notable-days': [
        notableJson(
          name: 'Later',
          localName: '以后',
          start: '2099-09-25T00:00:00.000Z',
        ),
        notableJson(
          name: 'Sooner',
          localName: '更早',
          start: '2099-01-05T00:00:00.000Z',
        ),
      ],
    });

    final result = await run(adapter, 'next_notable_day', {});

    // The region is named rather than left to the server's default.
    final query = adapter.request('GET', '/passport/notable-days').queryParameters;
    expect(query['region'], 'CN');
    expect(query['take'], 50);

    final day = result['notable_day'] as Map<String, dynamic>;
    expect(day['date'], '2099-01-05T00:00:00Z');
    expect(day['name'], '更早');
    expect(day['english_name'], 'Sooner');
    expect(day['days_away'], isA<int>());
    expect(day['days_away'], greaterThan(0));
  });

  test('a recurring day lands on this year, not the year it was seeded in', () async {
    final adapter = SolarStubAdapter({
      'GET /passport/notable-days': [
        notableJson(
          name: 'Far Future',
          localName: '未来',
          start: '2099-12-31T00:00:00.000Z',
        ),
        notableJson(
          name: 'National Day',
          localName: '国庆节',
          start: '2024-10-01T00:00:00.000Z',
          recurring: true,
        ),
      ],
    });

    final day = (await run(adapter, 'next_notable_day', {}))['notable_day']
        as Map<String, dynamic>;

    // 2024-10-01 recurring means the next 10-01, never the missing 2099 one.
    final date = DateTime.parse(day['date'] as String);
    expect(date.month, 10);
    expect(date.day, 1);
    expect(date.isAfter(DateTime.now().toUtc()), isTrue);
  });

  test('next_notable_day answers with nothing rather than an error', () async {
    final adapter = SolarStubAdapter({'GET /passport/notable-days': <Object>[]});

    final result = await run(adapter, 'next_notable_day', {});

    expect(result, {'notable_day': null});
  });

  test('create_event sends ISO times and returns what was created', () async {
    final adapter = SolarStubAdapter({
      'POST /passport/accounts/me/calendar/events': eventJson(
        id: 'new',
        title: 'Dentist',
      ),
    });

    final result = await run(adapter, 'create_event', {
      'title': 'Dentist',
      'start': '2026-10-01T09:00:00Z',
      'end': '2026-10-01T10:00:00Z',
      'description': 'bring the card',
    });

    expect(adapter.request('POST', '/passport/accounts/me/calendar/events').data, {
      'title': 'Dentist',
      'startTime': '2026-10-01T09:00:00.000Z',
      'endTime': '2026-10-01T10:00:00.000Z',
      'isAllDay': false,
      'description': 'bring the card',
    });
    expect(result['id'], 'new');
    expect(result['title'], 'Dentist');
  });

  test('a time the model wrote as prose is refused before the wire', () async {
    final adapter = SolarStubAdapter({});

    final result = await run(adapter, 'create_event', {
      'title': 'Dentist',
      'start': 'next Tuesday morning',
      'end': '2026-10-01T10:00:00Z',
    });

    expect(result['error'], contains('ISO-8601'));
    expect(adapter.requests, isEmpty);
  });

  test('an event that ends before it starts is refused before the wire', () async {
    final adapter = SolarStubAdapter({});

    final result = await run(adapter, 'create_event', {
      'title': 'Backwards',
      'start': '2026-10-01T10:00:00Z',
      'end': '2026-10-01T09:00:00Z',
    });

    expect(result['error'], contains('before it starts'));
    expect(adapter.requests, isEmpty);
  });

  test('a blank required argument is reported, not called', () async {
    final adapter = SolarStubAdapter({});

    final result = await run(adapter, 'create_event', {
      'title': '  ',
      'start': '2026-10-01T09:00:00Z',
      'end': '2026-10-01T10:00:00Z',
    });

    expect(result['error'], contains('"title"'));
    expect(adapter.requests, isEmpty);
  });

  test('a calendar the wire barely fills in still answers', () async {
    final adapter = SolarStubAdapter({
      'GET /passport/accounts/me/calendar/merged': {
        'date': null,
        'merged_events': [
          {
            'id': 'e1',
            'type': null,
            'title': null,
            'start_time': null,
            'end_time': null,
            'is_all_day': null,
            'location': null,
            'description': null,
          },
        ],
        'user_events': null,
      },
      'GET /passport/notable-days': [
        {'id': 'd1', 'name': null, 'local_name': null, 'start_date': null},
      ],
    });

    final agenda = await run(adapter, 'read_agenda', {'year': 2026, 'month': 1});
    expect((agenda['events'] as List).single, {'id': 'e1'});

    // A day with no date cannot be placed, so it is left out rather than
    // reported as the next one.
    expect(
      await run(adapter, 'next_notable_day', {}),
      {'notable_day': null},
    );
  });

  test('a 401 reads as a session to renew', () async {
    final adapter = SolarStubAdapter(
      {'GET /passport/accounts/me/calendar/merged': {'message': 'token expired'}},
      statuses: {'GET /passport/accounts/me/calendar/merged': 401},
    );

    final result = await run(adapter, 'read_agenda', {});

    expect(result['error'], contains('not signed in'));
    expect(result['error'], contains('token expired'));
  });

  test('the plugin is eager, adds nothing to override, and keeps tool order', () {
    expect(plugin.onDemand, isFalse);
    expect(plugin.enabledByDefault, isFalse);
    expect(plugin.overrides, isEmpty);
    final built = plugin
        .buildTools(solarContext(solarDio(SolarStubAdapter({}))))
        .map((tool) => tool.name)
        .toList();
    expect(built, ['read_agenda', 'next_notable_day', 'create_event']);
  });
}
