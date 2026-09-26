import 'package:flutter_test/flutter_test.dart';
import 'package:persynth/plugins/chat_plugin.dart';

import 'solar_test_support.dart';

/// One conversation as the service returns it.
Map<String, dynamic> roomJson({
  required String id,
  String? name = 'Room',
  int type = 0,
  List<Map<String, dynamic>> members = const [],
}) => {
  'id': id,
  'name': name,
  'type': type,
  'members': members,
  'updated_at': '2026-09-24T09:00:00.000Z',
};

/// One member as the service returns it.
Map<String, dynamic> memberJson(String nick, String username) => {
  'id': 'member-$username',
  'account_id': 'acc-$username',
  'username': username,
  'nick': nick,
};

/// One message as the service returns it.
Map<String, dynamic> messageJson({
  required String id,
  String? content = 'hello',
  String senderNick = 'Ada',
  String senderName = 'ada',
  int? type,
}) => {
  'id': id,
  'content': content,
  'created_at': '2026-09-24T09:00:00.000Z',
  'sender_id': 'acc-$senderName',
  'sender': memberJson(senderNick, senderName),
  'is_thread_root': false,
};

void main() {
  const plugin = ChatPlugin();

  Future<Map<String, dynamic>> run(
    SolarStubAdapter adapter,
    String tool,
    Map<String, dynamic> arguments,
  ) async {
    final built = solarTool(plugin.buildTools(solarContext(solarDio(adapter))), tool);
    return solarResult(await built.execute(arguments));
  }

  test('read_conversations reads the caller\'s own chat route', () async {
    final adapter = SolarStubAdapter({
      // `/messager/chat/rooms` — what the client used to call — is a 404.
      'GET /messager/chat': {
        'rooms': [
          roomJson(id: 'r1', name: null, type: 1, members: [memberJson('Ada', 'ada')]),
          roomJson(id: 'r2', name: 'Builders', members: [memberJson('Bo', 'bo')]),
        ],
        'groups': <Object>[],
      },
    });

    final result = await run(adapter, 'read_conversations', {});

    expect(adapter.request('GET', '/messager/chat').queryParameters, isEmpty);
    final rooms = result['conversations'] as List;
    expect(rooms.first, {
      'room_id': 'r1',
      'kind': 'direct',
      'members': ['Ada'],
      'member_count': 1,
      'updated_at': '2026-09-24T09:00:00Z',
    });
    expect(rooms.last['name'], 'Builders');
    expect(rooms.last['kind'], 'group');
  });

  test('read_conversation addresses the room directly and always pages', () async {
    final adapter = SolarStubAdapter({
      'GET /messager/chat/r1/messages': [messageJson(id: 'm1')],
    });

    final result = await run(adapter, 'read_conversation', {
      'room_id': 'r1',
      'take': 5,
    });

    // `offset` has no server default: leaving it out is a 400, so it is sent
    // even though the tool never pages.
    expect(
      adapter.request('GET', '/messager/chat/r1/messages').queryParameters,
      {'offset': 0, 'take': 5},
    );
    expect((result['messages'] as List).single, {
      'id': 'm1',
      'sent_at': '2026-09-24T09:00:00Z',
      'sender': 'Ada',
      'sender_id': 'acc-ada',
      'content': 'hello',
    });
  });

  test('send_message posts into the room and returns the sent message', () async {
    final adapter = SolarStubAdapter({
      'POST /messager/chat/r1/messages': messageJson(id: 'm2', content: 'on my way'),
    });

    final result = await run(adapter, 'send_message', {
      'room_id': 'r1',
      'content': 'on my way',
    });

    expect(adapter.request('POST', '/messager/chat/r1/messages').data, {
      'content': 'on my way',
      'isThreadRoot': false,
    });
    expect(result['content'], 'on my way');
  });

  test('message_someone resolves the person, opens the room, then sends', () async {
    final adapter = SolarStubAdapter({
      'GET /stargate/accounts/ada': {'id': 'acc-ada', 'name': 'ada', 'nick': 'Ada'},
      'POST /messager/chat/direct': roomJson(id: 'dm-1', type: 1),
      'POST /messager/chat/dm-1/messages': messageJson(id: 'm3', content: 'hi Ada'),
    });

    final result = await run(adapter, 'message_someone', {
      'username': 'ada',
      'content': 'hi Ada',
    });

    // The three calls in order, with the id the first one produced carrying
    // into the second and third.
    expect(
      adapter.requests.map((request) => '${request.method} ${request.path}'),
      [
        'GET /stargate/accounts/ada',
        'POST /messager/chat/direct',
        'POST /messager/chat/dm-1/messages',
      ],
    );
    expect(adapter.request('POST', '/messager/chat/direct').data, {
      'relatedUserId': 'acc-ada',
    });
    expect(result['ok'], isTrue);
    expect(result['room_id'], 'dm-1');
    expect((result['message'] as Map)['content'], 'hi Ada');
  });

  test('message_someone names an unknown account and stops there', () async {
    final adapter = SolarStubAdapter({'GET /stargate/accounts/nobody': null});

    final result = await run(adapter, 'message_someone', {
      'username': 'nobody',
      'content': 'hello',
    });

    expect(result['error'], contains('no account "nobody"'));
    expect(adapter.requests, hasLength(1), reason: 'nothing else was called');
  });

  test('unread_messages reads the tally and the per-room summary', () async {
    final adapter = SolarStubAdapter({
      'GET /messager/chat/unread': 7,
      'GET /messager/chat/summary': {
        'r1': {
          'unread_count': 3,
          'has_unread': true,
          'last_message': messageJson(id: 'm9', content: 'ping'),
        },
        'r2': {'unread_count': 0, 'has_unread': false, 'last_message': null},
      },
    });

    final result = await run(adapter, 'unread_messages', {});

    expect(result['unread'], 7);
    final rooms = result['conversations'] as List;
    // A room with nothing unread is not news.
    expect(rooms, hasLength(1));
    expect((rooms.single)['room_id'], 'r1');
    expect((rooms.single)['unread'], 3);
    expect(((rooms.single)['last_message'] as Map)['content'], 'ping');
  });

  test('a barely-filled room and message still answer', () async {
    final adapter = SolarStubAdapter({
      'GET /messager/chat':
          {
            'rooms': [
              {
                'id': 'r1',
                'name': null,
                'type': null,
                'members': null,
                'updated_at': null,
              },
            ],
          },
      'GET /messager/chat/r1/messages': [
        {
          'id': 'm1',
          'content': null,
          'sender': null,
          'sender_id': null,
          'created_at': null,
          'updated_at': null,
        },
      ],
    });

    final rooms = await run(adapter, 'read_conversations', {});
    expect((rooms['conversations'] as List).single, {'room_id': 'r1'});

    final messages = await run(adapter, 'read_conversation', {'room_id': 'r1'});
    expect((messages['messages'] as List).single, {'id': 'm1'});
  });

  test('a blank required argument is reported, not called', () async {
    final adapter = SolarStubAdapter({});

    final result = await run(adapter, 'send_message', {'room_id': 'r1', 'content': '  '});

    expect(result['error'], contains('"content"'));
    expect(adapter.requests, isEmpty);
  });

  test('a 401 reads as a session to renew', () async {
    final adapter = SolarStubAdapter(
      {'GET /messager/chat': {'message': 'token expired'}},
      statuses: {'GET /messager/chat': 401},
    );

    final result = await run(adapter, 'read_conversations', {});

    expect(result['error'], contains('not signed in'));
    expect(result['error'], contains('token expired'));
  });

  test('the plugin is on demand and overrides only what it does', () {
    expect(plugin.onDemand, isTrue);
    expect(plugin.enabledByDefault, isFalse);
    expect(plugin.overrides, {'send_chat_message': 'send_message'});
    final built = plugin
        .buildTools(solarContext(solarDio(SolarStubAdapter({}))))
        .map((tool) => tool.name)
        .toList();
    expect(built, [
      'read_conversations',
      'read_conversation',
      'send_message',
      'message_someone',
      'unread_messages',
    ]);
  });
}
