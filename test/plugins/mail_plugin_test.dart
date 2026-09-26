import 'package:flutter_test/flutter_test.dart';
import 'package:persynth/plugins/mail_plugin.dart';

import 'solar_test_support.dart';

/// One mailbox as the service returns it.
Map<String, dynamic> mailboxJson({
  required String id,
  String? address = 'ada@example.com',
  String? name,
  bool isDefault = false,
  bool isVerified = true,
  String? workspaceId,
}) => {
  'id': id,
  'account_id': 'acc-ada',
  'workspace_id': workspaceId,
  'address': address,
  'name': name,
  'is_default': isDefault,
  'is_verified': isVerified,
};

/// One email as the service returns it, in SolWatt's shapes.
Map<String, dynamic> emailJson({
  required String id,
  String? mailboxId = 'mb-1',
  String? subject = 'Hello',
  String? body = 'A short body.',
  String? contentType = 'text/plain',
  Map<String, dynamic>? from = const {
    'address': 'ada@example.com',
    'name': 'Ada',
    'kind': 'from',
  },
  String? fromAddress,
  String? fromName,
  List<Map<String, dynamic>> recipients = const [
    {'address': 'bo@example.com', 'name': 'Bo', 'kind': 'to'},
  ],
  List<Map<String, dynamic>> attachments = const [],
  bool isRead = false,
  bool isStarred = false,
  String? folder = 'inbox',
  String? createdAt = '2026-09-24T09:00:00.000Z',
  String? deliveryStatus = 'sent',
  String? deliveryError,
}) => {
  'id': id,
  'mailbox_id': mailboxId,
  'subject': subject,
  'body': body,
  'is_draft': false,
  'content_type': contentType,
  'from': from,
  'from_address': fromAddress,
  'from_name': fromName,
  'recipients': recipients,
  'attachments': attachments,
  'is_read': isRead,
  'is_starred': isStarred,
  'folder': folder,
  'created_at': createdAt,
  'delivery_status': deliveryStatus,
  'delivery_attempts': 1,
  'last_delivery_attempt_at': createdAt,
  'delivery_error': deliveryError,
  'provider_message_id': 'provider-$id',
  'mailbox': {'id': mailboxId},
};

void main() {
  const plugin = MailPlugin();

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

  test('read_mailbox lists the caller\'s mailboxes', () async {
    final adapter = SolarStubAdapter({
      'GET /postal/mailboxes': [
        mailboxJson(id: 'mb-1', name: 'Personal', isDefault: true),
        mailboxJson(
          id: 'mb-2',
          address: 'bo@example.com',
          isVerified: false,
          workspaceId: 'ws-9',
        ),
      ],
    });

    final result = await run(adapter, 'read_mailbox', {});

    expect(adapter.request('GET', '/postal/mailboxes').queryParameters, isEmpty);
    final mailboxes = result['mailboxes'] as List;
    expect(mailboxes, hasLength(2));
    // The default and verified mailbox says so; the others need not.
    expect(mailboxes.first, {
      'id': 'mb-1',
      'address': 'ada@example.com',
      'name': 'Personal',
      'is_default': true,
      'is_verified': true,
    });
    expect(mailboxes.last, {
      'id': 'mb-2',
      'address': 'bo@example.com',
      'workspace_id': 'ws-9',
    });
  });

  test('read_mail pages the mailbox with only the filters the caller gave', () async {
    final adapter = SolarStubAdapter({
      'GET /postal/emails': [
        emailJson(id: 'e1', subject: 'Hello there', body: 'A' * 400),
        emailJson(id: 'e2', subject: 'Lunch?'),
      ],
    }, totals: {'GET /postal/emails': 2});

    final result = await run(adapter, 'read_mail', {
      'mailbox_id': 'mb-1',
      'folder': 'inbox',
      'q': 'lunch',
      'is_read': false,
      'take': 5,
    });

    expect(adapter.request('GET', '/postal/emails').queryParameters, {
      'offset': 0,
      'take': 5,
      'mailbox_id': 'mb-1',
      'folder': 'inbox',
      'q': 'lunch',
      'is_read': false,
    });
    // The page total comes from the X-Total header, not the payload.
    expect(result['total'], 2);
    final emails = result['emails'] as List;
    expect(emails.first, {
      'id': 'e1',
      'mailbox_id': 'mb-1',
      'subject': 'Hello there',
      'from_address': 'ada@example.com',
      'from_name': 'Ada',
      'preview': '${'A' * 300}… [truncated]',
      'folder': 'inbox',
      'created_at': '2026-09-24T09:00:00Z',
    });
    expect(emails.last['subject'], 'Lunch?');
    expect(emails.last['preview'], 'A short body.');

    // No filters: the page is the whole mailbox, offset and the default take.
    final plain = SolarStubAdapter({
      'GET /postal/emails': [emailJson(id: 'e3')],
    });
    final unfiltered = await run(plain, 'read_mail', {});
    expect(plain.request('GET', '/postal/emails').queryParameters, {
      'offset': 0,
      'take': 10,
    });
    // No header on this stub, so the total falls back to the page length.
    expect(unfiltered['total'], 1);
    expect(unfiltered['emails'] as List, hasLength(1));
  });

  test('read_email reads one message and splits recipients by kind', () async {
    final adapter = SolarStubAdapter({
      'GET /postal/emails/e1': emailJson(
        id: 'e1',
        subject: 'The plan',
        body: 'B' * 9000,
        from: {'address': 'bo@example.com', 'name': 'Bo', 'kind': 'from'},
        recipients: [
          {'address': 'ada@example.com', 'name': 'Ada', 'kind': 'to'},
          {'address': 'ada@work.com', 'kind': 'cc'},
          {'address': 'bcc@example.com', 'name': 'Secret', 'kind': 'bcc'},
        ],
        attachments: [
          {
            'file': {
              'id': 'f1',
              'name': 'notes.pdf',
              'mime_type': 'application/pdf',
              'size': 2048,
            },
            'content_id': 'c1',
          },
          {'id': 'f2', 'filename': 'old.txt', 'mime_type': 'text/plain', 'size': 12},
        ],
        isRead: true,
        deliveryError: 'bounced',
      ),
    });

    final result = await run(adapter, 'read_email', {'email_id': 'e1'});

    expect(adapter.request('GET', '/postal/emails/e1').queryParameters, isEmpty);
    expect(result, {
      'id': 'e1',
      'mailbox_id': 'mb-1',
      'subject': 'The plan',
      'body': '${'B' * 8000}… [truncated]',
      'content_type': 'text/plain',
      // The nested from object is the sender; bcc stays out of the answer.
      'from_address': 'bo@example.com',
      'from_name': 'Bo',
      'to': [
        {'address': 'ada@example.com', 'name': 'Ada'},
      ],
      'cc': [
        {'address': 'ada@work.com'},
      ],
      'is_read': true,
      'folder': 'inbox',
      'created_at': '2026-09-24T09:00:00Z',
      'attachments': [
        {
          'id': 'f1',
          'name': 'notes.pdf',
          'mime_type': 'application/pdf',
          'size': 2048,
        },
        {'id': 'f2', 'name': 'old.txt', 'mime_type': 'text/plain', 'size': 12},
      ],
      'delivery_status': 'sent',
      'delivery_error': 'bounced',
    });
  });

  test('read_email falls back to flat sender fields when there is no from object', () async {
    final adapter = SolarStubAdapter({
      'GET /postal/emails/e2': {
        'id': 'e2',
        'mailbox_id': 'mb-1',
        'subject': 'Plain',
        'body': 'Hi.',
        'from_address': 'noreply@example.com',
        'from_name': 'No Reply',
        'is_read': true,
        'folder': 'inbox',
        'created_at': '2026-09-24T09:00:00.000Z',
      },
    });

    final result = await run(adapter, 'read_email', {'email_id': 'e2'});

    expect(result, {
      'id': 'e2',
      'mailbox_id': 'mb-1',
      'subject': 'Plain',
      'body': 'Hi.',
      'from_address': 'noreply@example.com',
      'from_name': 'No Reply',
      'is_read': true,
      'folder': 'inbox',
      'created_at': '2026-09-24T09:00:00Z',
      // No recipients and no attachments were sent: the lists answer "none".
      'to': <Object>[],
      'cc': <Object>[],
      'attachments': <Object>[],
    });
  });

  test('unread_mail tallies each mailbox\'s inbox via X-Total', () async {
    final adapter = SolarStubAdapter(
      {
        'GET /postal/mailboxes': [
          mailboxJson(id: 'mb-1', address: 'ada@example.com'),
          mailboxJson(id: 'mb-2', address: 'bo@example.com'),
        ],
        'GET /postal/emails?mailbox_id=mb-1&folder=inbox&is_read=false&take=1': <Object>[],
        'GET /postal/emails?mailbox_id=mb-2&folder=inbox&is_read=false&take=1': <Object>[],
      },
      totals: {
        'GET /postal/emails?mailbox_id=mb-1&folder=inbox&is_read=false&take=1': 3,
        'GET /postal/emails?mailbox_id=mb-2&folder=inbox&is_read=false&take=1': 0,
      },
    );

    final result = await run(adapter, 'unread_mail', {});

    // One request per mailbox, each counting exactly that mailbox's inbox.
    expect(
      adapter.requests.map((request) => '${request.method} ${request.path}'),
      [
        'GET /postal/mailboxes',
        'GET /postal/emails?mailbox_id=mb-1&folder=inbox&is_read=false&take=1',
        'GET /postal/emails?mailbox_id=mb-2&folder=inbox&is_read=false&take=1',
      ],
    );
    final mailboxes = result['mailboxes'] as List;
    expect(mailboxes, hasLength(2));
    expect(mailboxes.first, {
      'mailbox_id': 'mb-1',
      'address': 'ada@example.com',
      'unread': 3,
    });
    // A quiet inbox is a zero, kept as an answer rather than dropped.
    expect(mailboxes.last, {
      'mailbox_id': 'mb-2',
      'address': 'bo@example.com',
      'unread': 0,
    });
  });

  test('send_email posts the message and returns what was sent', () async {
    final adapter = SolarStubAdapter({
      'POST /postal/emails': {
        'id': 'e9',
        'subject': 'Re: plans',
        'delivery_status': 'queued',
        'folder': 'sent',
      },
    });

    final result = await run(adapter, 'send_email', {
      'mailbox_id': 'mb-1',
      'to': ['bo@example.com', 'carol@example.com'],
      'cc': ['ada@work.com'],
      'subject': 'Re: plans',
      'body': 'On it.',
      'content_type': 'text/html',
      'reply_to_id': 'e5',
    });

    expect(adapter.request('POST', '/postal/emails').data, {
      'mailbox_id': 'mb-1',
      'to': [
        {'address': 'bo@example.com', 'kind': 'to'},
        {'address': 'carol@example.com', 'kind': 'to'},
      ],
      'cc': [
        {'address': 'ada@work.com', 'kind': 'cc'},
      ],
      'bcc': <Object>[],
      'subject': 'Re: plans',
      'body': 'On it.',
      'content_type': 'text/html',
      'reply_to_id': 'e5',
    });
    expect(result['sent'], {
      'id': 'e9',
      'subject': 'Re: plans',
      'delivery_status': 'queued',
      'folder': 'sent',
    });

    // With nothing but the essentials: subject defaults to empty, the content
    // type to text/plain, and reply_to_id is left out entirely.
    final plain = SolarStubAdapter({
      'POST /postal/emails': {'id': 'e10', 'delivery_status': 'queued'},
    });
    final minimal = await run(plain, 'send_email', {
      'mailbox_id': 'mb-1',
      'to': ['bo@example.com'],
      'body': 'Quick note.',
    });
    expect(plain.request('POST', '/postal/emails').data, {
      'mailbox_id': 'mb-1',
      'to': [
        {'address': 'bo@example.com', 'kind': 'to'},
      ],
      'cc': <Object>[],
      'bcc': <Object>[],
      'subject': '',
      'body': 'Quick note.',
      'content_type': 'text/plain',
    });
    expect(minimal['sent'], {'id': 'e10', 'delivery_status': 'queued'});
  });

  test('send_email refuses blank arguments and bad addresses before the wire', () async {
    final adapter = SolarStubAdapter({});

    final noMailbox = await run(adapter, 'send_email', {
      'to': ['bo@example.com'],
      'body': 'Hi',
    });
    expect(noMailbox['error'], contains('"mailbox_id"'));

    final blankBody = await run(adapter, 'send_email', {
      'mailbox_id': 'mb-1',
      'to': ['bo@example.com'],
      'body': '   ',
    });
    expect(blankBody['error'], contains('"body"'));

    final noRecipients = await run(adapter, 'send_email', {
      'mailbox_id': 'mb-1',
      'to': <Object>[],
      'body': 'Hi',
    });
    expect(noRecipients['error'], contains('"to"'));

    final badAddress = await run(adapter, 'send_email', {
      'mailbox_id': 'mb-1',
      'to': ['not-an-address'],
      'body': 'Hi',
    });
    expect(badAddress['error'], contains('not an email'));

    // None of the refusals reached the wire.
    expect(adapter.requests, isEmpty);
  });

  test('mark_mail posts the chosen action and refuses an unknown one', () async {
    final adapter = SolarStubAdapter({
      'POST /postal/emails/e1/read': {'ok': true},
      'POST /postal/emails/e1/unstar': {'ok': true},
    });

    final read = await run(adapter, 'mark_mail', {'email_id': 'e1', 'action': 'read'});
    expect(
      adapter.request('POST', '/postal/emails/e1/read').data,
      isNull,
      reason: 'the mark endpoints take no body',
    );
    expect(read, {'ok': true, 'email_id': 'e1', 'action': 'read'});

    final unstar = await run(adapter, 'mark_mail', {'email_id': 'e1', 'action': 'unstar'});
    expect(unstar, {'ok': true, 'email_id': 'e1', 'action': 'unstar'});

    final fresh = SolarStubAdapter({});
    final bad = await run(fresh, 'mark_mail', {'email_id': 'e1', 'action': 'delete'});
    expect(bad['error'], contains('"action"'));
    expect(fresh.requests, isEmpty, reason: 'the refusal happens before the wire');
  });

  test('move_mail posts the folder and refuses an unknown one', () async {
    final adapter = SolarStubAdapter({
      'POST /postal/emails/e1/move': {'ok': true},
    });

    final result = await run(adapter, 'move_mail', {'email_id': 'e1', 'folder': 'trash'});
    expect(adapter.request('POST', '/postal/emails/e1/move').data, {'folder': 'trash'});
    expect(result, {'ok': true, 'email_id': 'e1', 'folder': 'trash'});

    final fresh = SolarStubAdapter({});
    final bad = await run(fresh, 'move_mail', {'email_id': 'e1', 'folder': 'junk'});
    expect(bad['error'], contains('"folder"'));
    expect(fresh.requests, isEmpty, reason: 'the refusal happens before the wire');
  });

  test('a mailbox and email the wire barely fills in still answer', () async {
    final adapter = SolarStubAdapter({
      'GET /postal/mailboxes': [
        {
          'id': 'mb-1',
          'address': null,
          'name': null,
          'is_default': null,
          'is_verified': null,
          'workspace_id': null,
        },
      ],
      'GET /postal/emails': [
        {
          'id': 'e1',
          'mailbox_id': null,
          'subject': null,
          'body': null,
          'from': null,
          'recipients': null,
          'attachments': null,
          'is_read': null,
          'folder': null,
          'created_at': null,
        },
      ],
      'GET /postal/emails/e1': {
        'id': 'e1',
        'mailbox_id': null,
        'subject': null,
        'body': null,
        'content_type': null,
        'from': null,
        'from_address': null,
        'from_name': null,
        'recipients': null,
        'attachments': null,
        'is_read': null,
        'is_starred': null,
        'folder': null,
        'created_at': null,
        'delivery_status': null,
        'delivery_error': null,
      },
      'GET /postal/emails?mailbox_id=mb-1&folder=inbox&is_read=false&take=1': <Object>[],
    });

    final mailboxes = await run(adapter, 'read_mailbox', {});
    expect((mailboxes['mailboxes'] as List).single, {'id': 'mb-1'});

    final page = await run(adapter, 'read_mail', {});
    expect((page['emails'] as List).single, {'id': 'e1'});
    expect(page['total'], 1, reason: 'no header, so the page length');

    final email = await run(adapter, 'read_email', {'email_id': 'e1'});
    expect(email, {
      'id': 'e1',
      'to': <Object>[],
      'cc': <Object>[],
      'attachments': <Object>[],
    });

    // A barely-filled mailbox is still counted: the missing address is
    // dropped and the quiet inbox reads as a zero, not an error.
    final tally = await run(adapter, 'unread_mail', {});
    expect(tally['mailboxes'], [
      {'mailbox_id': 'mb-1', 'unread': 0},
    ]);
  });

  test('a 401 reads as a session to renew', () async {
    final adapter = SolarStubAdapter(
      {'GET /postal/mailboxes': {'message': 'token expired'}},
      statuses: {'GET /postal/mailboxes': 401},
    );

    final result = await run(adapter, 'read_mailbox', {});

    expect(result['error'], contains('not signed in'));
    expect(result['error'], contains('token expired'));
  });

  test('the plugin is on demand, overrides nothing, and keeps the exact tool order', () {
    expect(plugin.id, 'mail');
    expect(plugin.label, 'Mail');
    expect(plugin.onDemand, isTrue);
    expect(plugin.enabledByDefault, isFalse);
    expect(plugin.overrides, isEmpty);
    final built = plugin
        .buildTools(solarContext(solarDio(SolarStubAdapter({}))))
        .map((tool) => tool.name)
        .toList();
    expect(built, [
      'read_mailbox',
      'read_mail',
      'read_email',
      'unread_mail',
      'send_email',
      'mark_mail',
      'move_mail',
    ]);
  });
}
