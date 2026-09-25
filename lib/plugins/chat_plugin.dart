/// The user's Solar Network messages, as tools.
///
/// Reads the conversation list, one conversation's messages and the unread
/// summary; writes by sending a message to a room or to a person by username.
/// It is a second plugin rather than more tools on the social one because the
/// grant is different: posting is public and the user can edit it afterwards,
/// while a message is delivered privately and immediately to people who are
/// waiting for it.
///
/// On demand: five definitions cost context on every request, and the
/// companion only needs them when the user asks about their messages. The
/// prompt fragment below is only sent once the model has loaded the set.
library;

import 'package:solar_network_sdk/solar_network_sdk.dart';

import 'package:persynth/personality/local_tool.dart';
import 'package:persynth/plugins/plugin.dart';
import 'package:persynth/plugins/solar_support.dart';

/// How many characters of a message body the model is given.
///
/// Enough for a chat message in full — the common case — and a clipped opening
/// plus a marker for a pasted wall of text.
const int _messageChars = 600;

class ChatPlugin extends SnPlugin {
  const ChatPlugin();

  @override
  String get id => 'chat';

  @override
  String get label => 'Messages';

  @override
  String get description =>
      'Reads the user\'s Solar Network conversations and direct messages, and '
      'can send messages as them.';

  @override
  String get summary =>
      'Read conversations and send messages as the user';

  @override
  bool get onDemand => true;

  /// Sending is the server's `send_chat_message` under a local tool.
  ///
  /// Not claimed: `get_chat_message`, which reads one message by id where
  /// these tools read a room's recent messages, and `send_chat_message_batch`,
  /// which sends several in one call. Neither is answered here, so overriding
  /// them would remove the capability instead of moving it.
  @override
  Map<String, String> get overrides => const {
    'send_chat_message': 'send_message',
  };

  @override
  List<SnLocalTool> buildTools(SnPluginContext context) {
    final chat = context.solar.chat;
    final accounts = context.solar.accounts;
    return [
      SnLocalTool(
        name: 'read_conversations',
        description:
            'The user\'s Solar Network conversations, most recently active '
            'first: each room with its people and when it last saw a message. '
            'Use it to find the room a conversation is in before reading or '
            'sending to it.',
        parameters: {
          'type': 'object',
          'properties': {
            'take': {
              'type': 'integer',
              'description': 'How many rooms to return (1-30, default 10).',
            },
          },
        },
        execute: (arguments) => solarToolResult(() async {
          final page = await chat.getRooms(take: solarTake(arguments));
          return {
            'rooms': page.items.map(_room).toList(),
            'total': page.totalCount,
          };
        }),
      ),
      SnLocalTool(
        name: 'read_conversation',
        description:
            'The messages in one Solar Network conversation, newest first, '
            'with the sender of each. Takes a room id as returned by '
            'read_conversations.',
        parameters: {
          'type': 'object',
          'properties': {
            'room_id': {
              'type': 'string',
              'description': 'The id of the conversation to read.',
            },
            'take': {
              'type': 'integer',
              'description': 'How many messages to return (1-30, default 10).',
            },
          },
          'required': ['room_id'],
        },
        execute: (arguments) => solarToolResult(() async {
          final roomId = solarText(arguments, 'room_id');
          if (roomId == null) return _missing('room_id');
          final page = await chat.getMessages(
            roomId: roomId,
            take: solarTake(arguments),
          );
          return {
            'messages': page.items.map(_message).toList(),
            'total': page.totalCount,
          };
        }),
      ),
      SnLocalTool(
        name: 'send_message',
        description:
            'Sends a message into an existing Solar Network conversation as '
            'the user. It arrives immediately and cannot be unsent, so send '
            'only wording the user gave you. Returns the message that was '
            'sent.',
        parameters: {
          'type': 'object',
          'properties': {
            'room_id': {
              'type': 'string',
              'description': 'The id of the conversation to send into.',
            },
            'content': {
              'type': 'string',
              'description':
                  'The message body, in the user\'s own words. Markdown is '
                  'supported.',
            },
          },
          'required': ['room_id', 'content'],
        },
        execute: (arguments) => solarToolResult(() async {
          final roomId = solarText(arguments, 'room_id');
          final content = solarText(arguments, 'content');
          if (roomId == null) return _missing('room_id');
          if (content == null) return _missing('content');
          return _message(
            await chat.sendMessage(roomId: roomId, content: content),
          );
        }),
      ),
      SnLocalTool(
        name: 'message_someone',
        description:
            'Sends a direct message to a person by username, opening the '
            'direct conversation with them if there is not one already. This '
            'is the tool to use when the user says to tell a named person '
            'something, rather than looking the conversation up first. It '
            'arrives immediately and cannot be unsent.',
        parameters: {
          'type': 'object',
          'properties': {
            'username': {
              'type': 'string',
              'description':
                  'The account username, e.g. "littleSheep", without the '
                  'leading @.',
            },
            'content': {
              'type': 'string',
              'description':
                  'The message body, in the user\'s own words. Markdown is '
                  'supported.',
            },
          },
          'required': ['username', 'content'],
        },
        execute: (arguments) => solarToolResult(() async {
          final username = solarText(arguments, 'username');
          final content = solarText(arguments, 'content');
          if (username == null) return _missing('username');
          if (content == null) return _missing('content');
          final account = await accounts.getAccountByUsername(username);
          final room = await chat.getOrCreateDirectChat(account.id);
          final message = await chat.sendMessage(
            roomId: room.id,
            content: content,
          );
          return {
            'ok': true,
            'room_id': room.id,
            'message': _message(message),
          };
        }),
      ),
      SnLocalTool(
        name: 'unread_messages',
        description:
            'How many Solar Network messages the user has not read, and the '
            'most recent one. Use it to answer whether anything is waiting for '
            'them.',
        parameters: {'type': 'object', 'properties': <String, dynamic>{}},
        execute: (arguments) => solarToolResult(() async {
          final summary = await chat.getChatSummary();
          return {
            'unread_count': summary.unreadCount,
            'has_unread': summary.hasUnread,
            if (summary.lastMessage != null)
              'last_message': _message(summary.lastMessage!),
          };
        }),
      ),
    ];
  }

  @override
  List<String> systemPrompt(SnPluginContext context) => const [
    'The user\'s Solar Network messaging tools are loaded: '
    'local_read_conversations, local_read_conversation, local_send_message, '
    'local_message_someone and local_unread_messages. They run as the '
    'signed-in user on their own connection.',
    'A message that is sent reaches real people immediately and cannot be '
    'recalled or unsent. Send only the wording the user gave you — never a '
    'message you composed yourself, and never a paraphrase of one — and when '
    'the user names a person to tell something, use local_message_someone '
    'rather than searching for a conversation first.',
  ];
}

/// One conversation as the model reads it.
///
/// A room carries its realm, its cloud files, its encryption mode and its
/// settings; none of that answers what the user asked, so only what identifies
/// the room and its people is kept.
Map<String, dynamic> _room(SnChatRoom room) => {
  'id': room.id,
  'name': room.name,
  'type': _roomKind(room.type),
  'members': room.members?.map(_memberName).toList(),
  'member_count': room.members?.length,
  'last_active_at': solarStamp(room.updatedAt),
}
  // The wire fills the optional halves with nulls and empty lists; every one
  // the model does not need is context spent on nothing.
  ..removeWhere(
    (_, value) =>
        value == null ||
        (value is String && value.isEmpty) ||
        (value is Iterable && value.isEmpty),
  );

/// A room's `type` as the model reads it.
///
/// The wire sends an int, where the app treats `1` as a direct conversation
/// and everything else as a named room. A number would tell the model nothing
/// it could act on, so it gets the word.
String _roomKind(int type) => type == 1 ? 'direct' : 'group';

/// One message projected to the fields that carry meaning.
///
/// A message embeds its sender, that sender's whole account, its attachments,
/// its reactions and its thread; serializing one whole would spend the context
/// window on a single line of chat.
Map<String, dynamic> _message(SnChatMessage message) => {
  'id': message.id,
  'sent_at': solarStamp(message.createdAt),
  'sender': _memberName(message.sender),
  'sender_id': message.senderId,
  'content': solarClip(message.content, limit: _messageChars),
  'replied_to': message.repliedMessageId,
}..removeWhere(
  (_, value) => value == null || (value is String && value.isEmpty),
);

/// A member's name as the other members see it: the nickname they set for this
/// room first, then the account nickname, then the account name.
String _memberName(SnChatMember member) {
  final roomNick = member.nick;
  if (roomNick != null && roomNick.isNotEmpty) return roomNick;
  final accountNick = member.account.nick;
  return accountNick.isNotEmpty ? accountNick : member.account.name;
}

/// A blank or absent required argument, reported so the model can retry.
///
/// Returning this rather than throwing keeps a malformed call a turn the model
/// can fix, instead of a tool that appears broken.
Map<String, dynamic> _missing(String argument) => {
  'error': 'The "$argument" argument is required.',
};
