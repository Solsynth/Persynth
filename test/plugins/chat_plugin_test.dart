import 'package:flutter_test/flutter_test.dart';
import 'package:persynth/plugins/chat_plugin.dart';

import 'solar_test_support.dart';

/// One account as the stargate returns it, for the sender and member stubs to
/// embed. Only the fields the SDK's model requires are filled; the rest are
/// what the wire actually sends for them.
Map<String, dynamic> accountJson({
  required String id,
  String name = 'ada',
  String nick = 'Ada',
}) => {
  'id': id,
  'name': name,
  'nick': nick,
  'language': 'en',
  'is_superuser': false,
  'profile': {
    'id': 'profile-$id',
    'experience': 0,
    'level': 0,
    'leveling_progress': 0.0,
    'created_at': '2026-01-01T00:00:00.000Z',
    'updated_at': '2026-01-01T00:00:00.000Z',
  },
  'created_at': '2026-01-01T00:00:00.000Z',
  'updated_at': '2026-01-01T00:00:00.000Z',
};

/// One room member as the API returns it.
Map<String, dynamic> memberJson({
  required String id,
  required String accountId,
  String? nick,
  String accountName = 'ada',
  String accountNick = 'Ada',
  String roomId = 'r1',
}) => {
  'id': id,
  'chat_room_id': roomId,
  'account_id': accountId,
  'account': accountJson(id: accountId, name: accountName, nick: accountNick),
  'nick': nick,
  'notify': 0,
  'created_at': '2026-01-01T00:00:00.000Z',
  'updated_at': '2026-01-01T00:00:00.000Z',
};

/// One conversation as the API returns it.
Map<String, dynamic> roomJson({
  required String id,
  String? name,
  int type = 0,
  List<Map<String, dynamic>>? members,
  String updatedAt = '2026-09-20T10:00:00.000Z',
}) => {
  'id': id,
  'name': name,
  'type': type,
  'members': members,
  'created_at': '2026-01-01T00:00:00.000Z',
  'updated_at': updatedAt,
};

/// One message as the API returns it.
Map<String, dynamic> messageJson({
  required String id,
  String? content = 'hello',
  String senderId = 'acc-ada',
  String senderNick = 'Ada',
  String? repliedTo,
  String roomId = 'r1',
}) => {
  'id': id,
  'content': content,
  'created_at': '2026-09-20T10:00:00.000Z',
  'updated_at': '2026-09-20T10:00:00.000Z',
  'sender_id': senderId,
  'sender': memberJson(
    id: 'm-$senderId',
    accountId: senderId,
    accountNick: senderNick,
    roomId: roomId,
  ),
  'chat_room_id': roomId,
  'replied_message_id': repliedTo,
};

/// The plugin builds its tools once per context, so each test builds the set
/// over its own adapter and reaches for the tool it is about.
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

  test('read_conversations projects each room, its people and the total', () async {
    final adapter = SolarStubAdapter(
      {
        'GET /messager/chat/rooms': [
          roomJson(
            id: 'r1',
            type: 1,
            members: [memberJson(id: 'm1', accountId: 'acc-ada')],
          ),
          roomJson(
            id: 'r2',
            name: 'Team',
            members: [
              memberJson(id: 'm1', accountId: 'acc-ada', roomId: 'r2'),
              memberJson(
                id: 'm2',
                accountId: 'acc-sheep',
                accountName: 'littleSheep',
                accountNick: 'Little Sheep',
                nick: 'sheep',
                roomId: 'r2',
              ),
            ],
          ),
        ],
      },
      totals: {'GET /messager/chat/rooms': 5},
    );

    final result = await run(adapter, 'read_conversations', {'take': 2});

    expect(adapter.request('GET', '/messager/chat/rooms').queryParameters, {
      'offset': 0,
      'take': 2,
    });
    expect(result['total'], 5);
    final rooms = result['rooms'] as List;
    expect(rooms.map((room) => room['id']), ['r1', 'r2']);
    // A direct room has no name of its own, so its people are the only thing
    // that identifies it — and the type reaches the model as a word.
    expect(rooms.first, {
      'id': 'r1',
      'type': 'direct',
      'members': ['Ada'],
      'member_count': 1,
      'last_active_at': '2026-09-20T10:00:00Z',
    });
    expect(rooms.last, {
      'id': 'r2',
      'name': 'Team',
      'type': 'group',
      'members': ['Ada', 'sheep'],
      'member_count': 2,
      'last_active_at': '2026-09-20T10:00:00Z',
    });
  });

  test('read_conversation projects each message and the page total', () async {
    final adapter = SolarStubAdapter(
      {
        'GET /messager/chat/rooms/r1/messages': [
          messageJson(id: 'msg-2', content: 'on my way', repliedTo: 'msg-1'),
          messageJson(
            id: 'msg-1',
            content: 'are you there?',
            senderId: 'acc-sheep',
            senderNick: 'Little Sheep',
          ),
        ],
      },
      totals: {'GET /messager/chat/rooms/r1/messages': 41},
    );

    final result = await run(adapter, 'read_conversation', {
      'room_id': 'r1',
      'take': 5,
    });

    expect(
      adapter.request('GET', '/messager/chat/rooms/r1/messages').queryParameters,
      {'offset': 0, 'take': 5},
    );
    expect(result['total'], 41);
    final messages = result['messages'] as List;
    expect(messages.first, {
      'id': 'msg-2',
      'sent_at': '2026-09-20T10:00:00Z',
      'sender': 'Ada',
      'sender_id': 'acc-ada',
      'content': 'on my way',
      'replied_to': 'msg-1',
    });
    // A message that is not a reply carries no `replied_to` at all.
    expect(messages.last, {
      'id': 'msg-1',
      'sent_at': '2026-09-20T10:00:00Z',
      'sender': 'Little Sheep',
      'sender_id': 'acc-sheep',
      'content': 'are you there?',
    });
  });

  test('send_message posts the content and returns the created message', () async {
    final adapter = SolarStubAdapter({
      'POST /messager/chat/rooms/r1/messages': messageJson(
        id: 'msg-3',
        content: 'on my way',
      ),
    });

    final result = await run(adapter, 'send_message', {
      'room_id': 'r1',
      'content': 'on my way',
    });

    expect(adapter.request('POST', '/messager/chat/rooms/r1/messages').data, {
      'content': 'on my way',
      'is_thread_root': false,
    });
    expect(result, {
      'id': 'msg-3',
      'sent_at': '2026-09-20T10:00:00Z',
      'sender': 'Ada',
      'sender_id': 'acc-ada',
      'content': 'on my way',
    });
  });

  test('message_someone resolves the person, opens the direct room, then sends', () async {
    final adapter = SolarStubAdapter({
      'GET /stargate/accounts/ada': accountJson(id: 'acc-ada'),
      'GET /messager/chat/direct/acc-ada': roomJson(id: 'dm-1', type: 1),
      'POST /messager/chat/rooms/dm-1/messages': messageJson(
        id: 'msg-9',
        content: 'running late',
        roomId: 'dm-1',
      ),
    });

    final result = await run(adapter, 'message_someone', {
      'username': 'ada',
      'content': 'running late',
    });

    // The username has to become an account before there is an id to open a
    // direct room with, so the three calls can only happen in this order.
    expect(
      adapter.requests.map((options) => '${options.method} ${options.path}').toList(),
      [
        'GET /stargate/accounts/ada',
        'GET /messager/chat/direct/acc-ada',
        'POST /messager/chat/rooms/dm-1/messages',
      ],
    );
    expect(adapter.request('POST', '/messager/chat/rooms/dm-1/messages').data, {
      'content': 'running late',
      'is_thread_root': false,
    });
    expect(result['ok'], isTrue);
    expect(result['room_id'], 'dm-1');
    expect(result['message']['id'], 'msg-9');
    expect(result['message']['content'], 'running late');
  });

  test('unread_messages reports the count and the last message', () async {
    final adapter = SolarStubAdapter({
      'GET /messager/chat/summary': {
        'unread_count': 3,
        'has_unread': true,
        'last_message': messageJson(id: 'msg-7', content: 'see you'),
      },
    });

    final result = await run(adapter, 'unread_messages', {});

    expect(adapter.request('GET', '/messager/chat/summary').queryParameters, isEmpty);
    expect(result['unread_count'], 3);
    expect(result['has_unread'], isTrue);
    expect(result['last_message']['id'], 'msg-7');
    expect(result['last_message']['sender'], 'Ada');
  });

  test('unread_messages with nothing waiting carries no last message', () async {
    final adapter = SolarStubAdapter({
      'GET /messager/chat/summary': {
        'unread_count': 0,
        'has_unread': false,
        'last_message': null,
      },
    });

    final result = await run(adapter, 'unread_messages', {});

    expect(result, {'unread_count': 0, 'has_unread': false});
  });

  test('a missing room or content is reported, not called', () async {
    final adapter = SolarStubAdapter({});

    final noRoom = await run(adapter, 'read_conversation', {});
    expect(noRoom['error'], contains('"room_id"'));

    final blankContent = await run(adapter, 'send_message', {
      'room_id': 'r1',
      'content': '   ',
    });
    expect(blankContent['error'], contains('"content"'));

    final noUsername = await run(adapter, 'message_someone', {'content': 'hi'});
    expect(noUsername['error'], contains('"username"'));

    expect(adapter.requests, isEmpty);
  });

  test('a 401 reads as a session to renew, not as a status code', () async {
    final adapter = SolarStubAdapter(
      {'GET /messager/chat/rooms': {'message': 'token expired'}},
      statuses: {'GET /messager/chat/rooms': 401},
    );

    final result = await run(adapter, 'read_conversations', {});

    expect(result['error'], contains('not signed in'));
    expect(result['error'], contains('token expired'));
  });

  test('a long message is clipped and marked', () async {
    final adapter = SolarStubAdapter({
      'GET /messager/chat/rooms/r1/messages': [
        messageJson(id: 'msg-1', content: 'x' * 900),
      ],
    });

    final result = await run(adapter, 'read_conversation', {'room_id': 'r1'});
    final content = (result['messages'] as List).single['content'] as String;

    expect(content, endsWith('… [truncated]'));
    expect(content.length, lessThan(700));
  });

  test('the plugin is on demand, and says what it may do on the user\'s behalf', () {
    expect(plugin.onDemand, isTrue);
    expect(plugin.enabledByDefault, isFalse);
    expect(plugin.description, contains('as them'));
    expect(plugin.label, 'Messages');
    expect(
      plugin.systemPrompt(solarContext(solarDio(SolarStubAdapter({})))),
      anyElement(contains('cannot be recalled')),
    );
  });
}
