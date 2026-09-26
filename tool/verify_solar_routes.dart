/// Checks that every Solar Network path the plugins call still exists.
///
/// The tools name their paths rather than going through `solar_network_sdk`,
/// whose routes had drifted far enough that most of them answered 404 — the
/// bug this file exists to catch the next time. It is a plain HTTP check, so
/// it needs no credentials: an endpoint that exists answers `401` without a
/// token and the real status when it is public, while a path that has moved
/// answers `404`.
///
/// Run it after touching a tool's request, or when the service is upgraded:
///
/// ```sh
/// dart run tool/verify_solar_routes.dart
/// ```
///
/// A non-zero exit means at least one path is gone.
library;

import 'dart:convert';
import 'dart:io';

const _base = 'https://api.solian.app';

/// One path a tool calls, and the method it calls it with.
class _Route {
  const _Route(this.method, this.path, this.what, {this.note});

  final String method;
  final String path;

  /// The tool that calls it, so a failure names the thing to fix.
  final String what;

  /// Why a 404 would not mean the route is gone, when that is the case.
  ///
  /// A route that looks its resource up before it looks at the token answers
  /// 404 for an id that does not exist, so this check cannot tell a missing
  /// resource from a missing route on its own. It is named here rather than
  /// hidden, and the path is proven by a sibling call where one exists.
  final String? note;
}

/// The sample publisher and post the checks use; both are public.
const _samplePublisher = 'littleSheep';

Future<void> main(List<String> arguments) async {
  final client = HttpClient();
  final samplePostId = await _samplePost(client);
  if (samplePostId == null) {
    stderr.writeln('Could not read a sample post; is the gateway up?');
    exitCode = 2;
    client.close();
    return;
  }
  const noRoom = '00000000-0000-0000-0000-000000000000';

  final routes = <_Route>[
    const _Route('GET', '/sphere/timeline?offset=0&take=1', 'social.read_timeline'),
    const _Route('GET', '/sphere/posts?offset=0&take=1', 'social.search_posts'),
    const _Route('GET', '/sphere/posts?query=hello&offset=0&take=1', 'social.search_posts'),
    _Route('GET', '/sphere/posts?pub=$_samplePublisher&offset=0&take=1', 'social.read_profile'),
    _Route('GET', '/sphere/publishers/$_samplePublisher', 'social.read_profile'),
    _Route('GET', '/sphere/posts/$samplePostId', 'social.read_post'),
    _Route('GET', '/sphere/posts/$samplePostId/replies?offset=0&take=1', 'social.read_post'),
    _Route('POST', '/sphere/posts', 'social.create_post'),
    _Route('POST', '/sphere/posts/$samplePostId/reactions', 'social.react_to_post'),
    const _Route('GET', '/messager/chat', 'chat.read_conversations'),
    const _Route('GET', '/messager/chat/summary', 'chat.unread_messages'),
    const _Route('GET', '/messager/chat/unread', 'chat.unread_messages'),
    _Route(
      'GET',
      '/messager/chat/$noRoom/messages?offset=0&take=1',
      'chat.read_conversation',
      note: 'reads the room before the token, so 404 is the absent room; the '
          'POST below proves this same path',
    ),
    _Route('POST', '/messager/chat/$noRoom/messages', 'chat.send_message'),
    const _Route('POST', '/messager/chat/direct', 'chat.message_someone'),
    const _Route('GET', '/stargate/accounts/me', 'profile.whoami'),
    _Route('GET', '/stargate/accounts/$_samplePublisher', 'profile.read_account'),
    const _Route('GET', '/passport/accounts/me/progression/achievements', 'profile.achievements'),
    const _Route('GET', '/passport/accounts/me/progression/achievements/stats', 'profile.achievements'),
    const _Route('GET', '/passport/accounts/me/calendar/merged?year=2026&month=9', 'agenda.read_agenda'),
    const _Route('POST', '/passport/accounts/me/calendar/events', 'agenda.create_event'),
    const _Route('GET', '/passport/notable-days?region=CN&take=5', 'agenda.next_notable_day'),
    const _Route('GET', '/passport/fortune', 'ritual.daily_fortune'),
    const _Route('GET', '/passport/accounts/me/check-in?version=2', 'ritual.today_check_in'),
    const _Route('POST', '/passport/accounts/me/check-in?version=2', 'ritual.check_in'),
    const _Route('GET', '/metoer/notifications?offset=0&take=1&unmark=true', 'notifications.read_notifications'),
    const _Route('GET', '/metoer/notifications/count', 'notifications.unread_notifications'),
    const _Route('POST', '/metoer/notifications/all/read', 'notifications.mark_all_notifications_read'),
    const _Route('GET', '/wallet/wallets', 'wallet.read_wallet'),
    const _Route('GET', '/wallet/wallets/stats?period=30&currencies=points', 'wallet.wallet_stats'),
    const _Route('GET', '/postal/mailboxes', 'mail.read_mailbox'),
    const _Route('GET', '/postal/emails?offset=0&take=1', 'mail.read_mail'),
    const _Route('GET', '/postal/emails?mailbox_id=$noRoom&folder=inbox&is_read=false&take=1', 'mail.unread_mail'),
    _Route('GET', '/postal/emails/$noRoom', 'mail.read_email'),
    const _Route('POST', '/postal/emails', 'mail.send_email'),
    _Route('POST', '/postal/emails/$noRoom/read', 'mail.mark_mail'),
    _Route('POST', '/postal/emails/$noRoom/unread', 'mail.mark_mail'),
    _Route('POST', '/postal/emails/$noRoom/star', 'mail.mark_mail'),
    _Route('POST', '/postal/emails/$noRoom/unstar', 'mail.mark_mail'),
    _Route('POST', '/postal/emails/$noRoom/move', 'mail.move_mail'),
    const _Route('GET', '/ideask/broads', 'boards.list_boards'),
    _Route('GET', '/ideask/broads/$noRoom/tasks', 'boards.list_tasks'),
    _Route('GET', '/ideask/tasks/$noRoom', 'boards.read_task'),
    _Route('POST', '/ideask/broads/$noRoom/tasks', 'boards.create_task'),
    _Route('PATCH', '/ideask/tasks/$noRoom', 'boards.update_task'),
    _Route('GET', '/ideask/tasks/$noRoom/comments', 'boards.list_task_comments'),
    _Route('POST', '/ideask/tasks/$noRoom/comments', 'boards.add_task_comment'),
  ];

  var missing = 0;
  for (final route in routes) {
    final status = await _status(client, route);
    // 401 is what an endpoint that exists answers to a request with no token;
    // the writes answer the same way before they look at their body.
    final gone = (status == 404 && route.note == null) || status == 405;
    if (gone) missing++;
    final verdict = gone
        ? 'GONE'
        : (route.note != null ? 'note' : 'ok  ');
    stdout.writeln(
      '$verdict  $status  ${route.method.padRight(4)} ${route.path}  '
      '(${route.what})',
    );
    if (route.note != null && status == 404) stdout.writeln('      ${route.note}');
  }

  client.close();
  stdout.writeln(
    missing == 0
        ? '\nAll ${routes.length} paths answered.'
        : '\n$missing of ${routes.length} paths are gone.',
  );
  if (missing > 0) exitCode = 1;
}

/// A post id the checks can address, read from the public listing.
Future<String?> _samplePost(HttpClient client) async {
  final request = await client.getUrl(Uri.parse('$_base/sphere/posts?take=1'));
  final response = await request.close();
  if (response.statusCode != 200) return null;
  final body = jsonDecode(await response.transform(utf8.decoder).join());
  if (body is! List || body.isEmpty) return null;
  final first = body.first;
  return first is Map ? first['id'] as String? : null;
}

Future<int> _status(HttpClient client, _Route route) async {
  try {
    final uri = Uri.parse('$_base${route.path}');
    final request = await client.openUrl(route.method, uri);
    if (route.method != 'GET') {
      request.headers.contentType = ContentType.json;
      request.write('{}');
    }
    final response = await request.close();
    await response.drain<void>();
    return response.statusCode;
  } on SocketException {
    return -1;
  }
}
