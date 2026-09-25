/// The user's Solar Network notifications, as tools.
///
/// Reads what arrived, reports the unread count, and marks notifications read.
/// This is the set the companion is asked for constantly — "anything new?" is
/// the most common thing a user asks a companion that can see their account —
/// so unlike the social set it rides on every run rather than waiting to be
/// activated.
///
/// The base path is `/metoer`, the spelling the gateway uses. It is not fixed
/// here because the SDK's `notifications` domain already carries it.
///
/// Reads and the write live in one plugin because they are one grant: the same
/// switch that lets the companion see the inbox is what lets it mark items
/// read, and a second switch would only invite the user to believe the first
/// one cannot touch anything.
library;

import 'package:solar_network_sdk/solar_network_sdk.dart';

import 'package:persynth/personality/local_tool.dart';
import 'package:persynth/plugins/plugin.dart';
import 'package:persynth/plugins/solar_support.dart';

class NotificationsPlugin extends SnPlugin {
  const NotificationsPlugin();

  @override
  String get id => 'notifications';

  @override
  String get label => 'Notifications';

  @override
  String get description =>
      'Reads the user\'s Solar Network notifications and can mark them read.';

  @override
  String get summary => 'Check unread notifications and mark them read';

  /// All three of the server's notification tools, plus the single read the
  /// server does not have.
  @override
  Map<String, String> get overrides => const {
    'list_notifications': 'read_notifications',
    'get_unread_notification_count': 'unread_notifications',
    'mark_all_notifications_read': 'mark_all_notifications_read',
  };

  @override
  List<SnLocalTool> buildTools(SnPluginContext context) {
    final notifications = context.solar.notifications;
    return [
      SnLocalTool(
        name: 'read_notifications',
        description:
            'The user\'s Solar Network notifications, newest first: replies, '
            'mentions, reactions, wallet and subscription events. Each one '
            'says whether it has been read, so an already-read item is one the '
            'user has seen rather than one they need to be told about.',
        parameters: {
          'type': 'object',
          'properties': {
            'take': {
              'type': 'integer',
              'description':
                  'How many notifications to return (1-30, default 10).',
            },
          },
        },
        execute: (arguments) => solarToolResult(() async {
          final page = await notifications.getNotifications(
            take: solarTake(arguments),
          );
          return {'notifications': page.items.map(_notification).toList()};
        }),
      ),
      SnLocalTool(
        name: 'unread_notifications',
        description:
            'How many Solar Network notifications the user has not read yet. '
            'The cheapest answer to "anything new?" — the count alone, without '
            'the notifications themselves, so prefer it when the user has not '
            'asked for the details.',
        parameters: {'type': 'object', 'properties': <String, dynamic>{}},
        execute: (arguments) => solarToolResult(() async {
          return {'unread': await notifications.getUnreadCount()};
        }),
      ),
      SnLocalTool(
        name: 'mark_notification_read',
        description:
            'Marks one Solar Network notification read, so it stops counting '
            'as unread. This changes the user\'s inbox: do it when the user '
            'asks about that notification, not as a tidy-up after reading it '
            'out.',
        parameters: {
          'type': 'object',
          'properties': {
            'notification_id': {
              'type': 'string',
              'description': 'The id of the notification, as returned by '
                  'local_read_notifications.',
            },
          },
          'required': ['notification_id'],
        },
        execute: (arguments) => solarToolResult(() async {
          final notificationId = solarText(arguments, 'notification_id');
          if (notificationId == null) return _missing('notification_id');
          await notifications.markAsRead(notificationId);
          return {'ok': true, 'notification_id': notificationId};
        }),
      ),
      SnLocalTool(
        name: 'mark_all_notifications_read',
        description:
            'Marks every Solar Network notification read, clearing the unread '
            'count. There is no undo, so call it only when the user asks for '
            'the count to be cleared.',
        parameters: {'type': 'object', 'properties': <String, dynamic>{}},
        execute: (arguments) => solarToolResult(() async {
          await notifications.markAllAsRead();
          return {'ok': true};
        }),
      ),
    ];
  }

  @override
  List<String> systemPrompt(SnPluginContext context) => const [
    'The user\'s Solar Network notification tools are loaded: '
    'local_read_notifications, local_unread_notifications, '
    'local_mark_notification_read and local_mark_all_notifications_read. They '
    'run as the signed-in user on their own connection, and the notifications '
    'they return are the user\'s real ones.',
    'When the user asks whether anything is new, the unread count is the '
    'answer — report it rather than paraphrasing the list. Marking read is a '
    'change to their inbox, so do it when they ask for it, not as a tidy-up '
    'after reading a notification out.',
  ];
}

/// One notification projected to the fields that carry meaning.
///
/// A notification carries its topic, its metadata blob and the account it
/// belongs to; the metadata is an application-specific payload the model
/// cannot act on and the account is the one the tools already run as. What a
/// reader needs is what arrived, when, and whether it has been seen.
Map<String, dynamic> _notification(SnNotification notification) => {
  'id': notification.id,
  'topic': notification.topic,
  'title': notification.title,
  'body': solarClip(notification.body),
  'created_at': solarStamp(notification.createdAt),
  'read': notification.viewedAt != null,
}
  // The wire fills a notification's optional text with empty strings; an
  // empty title or body says nothing, and the model spending context on
  // `"title": ""` is context spent on nothing.
  ..removeWhere((_, value) => value is String && value.isEmpty);

/// A blank or absent required argument, reported so the model can retry.
///
/// Returning this rather than throwing keeps a malformed call a turn the model
/// can fix, instead of a tool that appears broken.
Map<String, dynamic> _missing(String argument) => {
  'error': 'The "$argument" argument is required.',
};
