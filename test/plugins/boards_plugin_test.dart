import 'package:flutter_test/flutter_test.dart';
import 'package:persynth/plugins/boards_plugin.dart';

import 'solar_test_support.dart';

/// One board as the service returns it.
Map<String, dynamic> broadJson({
  required String id,
  String? name = 'Launch',
  String? title,
  String? taskPrefix = 'LW',
  String? workspaceId = 'ws-1',
  String? description = 'The launch board',
}) => {
  'id': id,
  'name': name,
  'title': title,
  'task_prefix': taskPrefix,
  'workspace_id': workspaceId,
  'description': description,
  'visibility': 'private',
  'background_image': null,
  'icon_image': null,
};

/// One assignee as the service returns it.
Map<String, dynamic> assigneeJson({
  String? accountNick = 'Ada',
  String? accountName = 'ada',
  String? nick,
  String? name,
}) => {
  'id': 'assignee-1',
  'account_id': 'acc-ada',
  'account_nick': accountNick,
  'account_name': accountName,
  'account': {
    'id': 'acc-ada',
    'nick': nick,
    'name': name,
  },
};

/// One task as the service returns it.
Map<String, dynamic> taskJson({
  required String id,
  String? name = 'Ship v2',
  String? taskKey = 'LW-12',
  String? status = 'open',
  int? priority = 2,
  String? deadlineAt = '2026-10-01T09:00:00.000Z',
  String? completedAt,
  String? description = 'Everything for v2',
  String? content = 'Ship it.',
  String? broadId = 'b1',
  String? groupId,
  String? parentTaskId,
  List<Map<String, dynamic>> assignees = const [],
  List<String> tags = const [],
}) => {
  'id': id,
  'name': name,
  'task_key': taskKey,
  'status': status,
  'priority': priority,
  'deadline_at': deadlineAt,
  'completed_at': completedAt,
  'description': description,
  'content': content,
  'broad_id': broadId,
  'group_id': groupId,
  'parent_task_id': parentTaskId,
  'assignees': assignees,
  'tags': tags,
  'serial_number': 12,
  'complete_reason': null,
  'attachments': const [],
};

/// One comment as the service returns it.
Map<String, dynamic> commentJson({
  required String id,
  String? content = 'Looking good',
  String? body,
  String? authorName,
  Map<String, dynamic>? account,
  String? nick,
  String? name,
}) => {
  'id': id,
  'content': content,
  'body': body,
  'created_at': '2026-09-24T09:00:00.000Z',
  'author_name': authorName,
  'account': account,
  'nick': nick,
  'name': name,
};

void main() {
  const plugin = BoardsPlugin();

  Future<Map<String, dynamic>> run(
    SolarStubAdapter adapter,
    String tool,
    Map<String, dynamic> arguments,
  ) async {
    final built = solarTool(plugin.buildTools(solarContext(solarDio(adapter))), tool);
    return solarResult(await built.execute(arguments));
  }

  test('list_boards reads the broads and projects name or title', () async {
    final adapter = SolarStubAdapter({
      'GET /ideask/broads': [
        broadJson(id: 'b1', name: null, title: 'Roadmap'),
        broadJson(id: 'b2'),
      ],
    });

    final result = await run(adapter, 'list_boards', {});

    expect(adapter.request('GET', '/ideask/broads').queryParameters, isEmpty);
    final boards = result['boards'] as List;
    // name falls back to title, and the list is present either way.
    expect(boards.first, {
      'id': 'b1',
      'name': 'Roadmap',
      'workspace_id': 'ws-1',
      'task_prefix': 'LW',
      'description': 'The launch board',
    });
    expect(boards.last['id'], 'b2');
    expect(boards.last['name'], 'Launch');
  });

  test('list_tasks pages a broad with only the filters given', () async {
    final adapter = SolarStubAdapter({
      'GET /ideask/broads/b1/tasks': [
        taskJson(
          id: 't1',
          assignees: [
            // account_nick wins over account_name and the embedded account.
            assigneeJson(),
            assigneeJson(accountNick: null, accountName: 'bo'),
            assigneeJson(accountNick: null, accountName: null),
          ],
          tags: ['launch'],
        ),
      ],
    });

    final result = await run(adapter, 'list_tasks', {
      'broad_id': 'b1',
      'status': 'open',
      'search': 'launch',
    });

    expect(
      adapter.request('GET', '/ideask/broads/b1/tasks').queryParameters,
      {'status': 'open', 'search': 'launch'},
    );
    final tasks = result['tasks'] as List;
    expect(tasks.single, {
      'id': 't1',
      'name': 'Ship v2',
      'task_key': 'LW-12',
      'status': 'open',
      'priority': 2,
      'deadline_at': '2026-10-01T09:00:00Z',
      'assignees': ['Ada', 'bo'],
      'tags': ['launch'],
    });

    // The `{'tasks': [...]}` response shape is handled the same way.
    final envelope = SolarStubAdapter({
      'GET /ideask/broads/b1/tasks': {
        'tasks': [taskJson(id: 't2', name: 'Fix bug', status: 'completed')],
        'total': 1,
      },
    });
    final enveloped = await run(envelope, 'list_tasks', {
      'broad_id': 'b1',
      'group_id': 'g1',
    });
    expect(
      envelope.request('GET', '/ideask/broads/b1/tasks').queryParameters,
      {'group_id': 'g1'},
    );
    expect((enveloped['tasks'] as List).single['id'], 't2');
  });

  test('read_task reads one task and clips long content', () async {
    final longContent = 'x' * 5000;
    final adapter = SolarStubAdapter({
      'GET /ideask/tasks/t1': taskJson(
        id: 't1',
        content: longContent,
        assignees: [assigneeJson()],
        tags: ['launch'],
      ),
    });

    final result = await run(adapter, 'read_task', {'task_id': 't1'});

    expect(adapter.request('GET', '/ideask/tasks/t1').queryParameters, isEmpty);
    expect(result, {
      'id': 't1',
      'name': 'Ship v2',
      'task_key': 'LW-12',
      'description': 'Everything for v2',
      'content': '${longContent.substring(0, 4000)}… [truncated]',
      'status': 'open',
      'priority': 2,
      'deadline_at': '2026-10-01T09:00:00Z',
      'broad_id': 'b1',
      'assignees': ['Ada'],
      'tags': ['launch'],
    });
  });

  test('create_task posts the draft and returns the created task', () async {
    final adapter = SolarStubAdapter({
      'POST /ideask/broads/b1/tasks': taskJson(id: 't9', taskKey: 'LW-14'),
    });

    final result = await run(adapter, 'create_task', {
      'broad_id': 'b1',
      'name': 'Ship v2',
      'priority': 3,
      'deadline_at': '2026-10-01T09:00:00Z',
      'assignee_account_ids': ['acc-1', 'acc-2'],
      'tags': ['launch'],
    });

    // Only the fields the caller named go out: no description or content.
    expect(adapter.request('POST', '/ideask/broads/b1/tasks').data, {
      'name': 'Ship v2',
      'priority': 3,
      'deadline_at': '2026-10-01T09:00:00Z',
      'assignee_account_ids': ['acc-1', 'acc-2'],
      'tags': ['launch'],
    });
    expect(result['id'], 't9');
    expect(result['name'], 'Ship v2');
    expect(result['content'], 'Ship it.');
  });

  test('create_task refuses a blank name before the wire', () async {
    final adapter = SolarStubAdapter({});

    final result = await run(adapter, 'create_task', {
      'broad_id': 'b1',
      'name': '   ',
    });

    expect(result['error'], contains('"name"'));
    expect(adapter.requests, isEmpty);
  });

  test('update_task patches only the fields given', () async {
    final adapter = SolarStubAdapter({
      'PATCH /ideask/tasks/t1': taskJson(id: 't1', status: 'completed'),
    });

    final result = await run(adapter, 'update_task', {
      'task_id': 't1',
      'status': 'completed',
      'priority': 2,
    });

    expect(adapter.request('PATCH', '/ideask/tasks/t1').data, {
      'status': 'completed',
      'priority': 2,
    });
    expect(result['status'], 'completed');

    // A call that names one field sends exactly that field.
    final nameOnly = SolarStubAdapter({
      'PATCH /ideask/tasks/t1': taskJson(id: 't1', name: 'Renamed'),
    });
    await run(nameOnly, 'update_task', {'task_id': 't1', 'name': 'Renamed'});
    expect(nameOnly.request('PATCH', '/ideask/tasks/t1').data, {'name': 'Renamed'});

    // A status the service does not know is refused before the wire.
    final refused = SolarStubAdapter({});
    final error = await run(refused, 'update_task', {
      'task_id': 't1',
      'status': 'done',
    });
    expect(error['error'], contains('open, completed, skipped or duplicated'));
    expect(refused.requests, isEmpty);
  });

  test('list_task_comments reads the comments and projects defensively', () async {
    final adapter = SolarStubAdapter({
      'GET /ideask/tasks/t1/comments': [
        commentJson(id: 'c1', authorName: 'Ada'),
        commentJson(
          id: 'c2',
          content: null,
          body: 'via body',
          account: {'nick': 'Bo', 'name': 'bo'},
        ),
        commentJson(id: 'c3', content: null, body: null, nick: 'Cy'),
        {'id': 'c4'},
      ],
    });

    final result = await run(adapter, 'list_task_comments', {'task_id': 't1'});

    expect(
      adapter.request('GET', '/ideask/tasks/t1/comments').queryParameters,
      isEmpty,
    );
    final comments = result['comments'] as List;
    expect(comments[0], {
      'id': 'c1',
      'content': 'Looking good',
      'created_at': '2026-09-24T09:00:00Z',
      'author': 'Ada',
    });
    // content falls back to body, and the author to the embedded account.
    expect(comments[1]['content'], 'via body');
    expect(comments[1]['author'], 'Bo');
    expect(comments[2]['author'], 'Cy');
    expect(comments[3], {'id': 'c4'});

    // The envelope shape is handled the same way.
    final envelope = SolarStubAdapter({
      'GET /ideask/tasks/t1/comments': {
        'comments': [commentJson(id: 'c9', authorName: 'Ada')],
      },
    });
    final enveloped = await run(envelope, 'list_task_comments', {'task_id': 't1'});
    expect((enveloped['comments'] as List).single['id'], 'c9');
  });

  test('add_task_comment posts content and refuses blank content', () async {
    final adapter = SolarStubAdapter({
      'POST /ideask/tasks/t1/comments': commentJson(id: 'c5', content: 'LGTM'),
    });

    final result = await run(adapter, 'add_task_comment', {
      'task_id': 't1',
      'content': 'LGTM',
    });

    expect(adapter.request('POST', '/ideask/tasks/t1/comments').data, {
      'content': 'LGTM',
    });
    expect(result['id'], 'c5');
    expect(result['content'], 'LGTM');

    final refused = SolarStubAdapter({});
    final error = await run(refused, 'add_task_comment', {
      'task_id': 't1',
      'content': '   ',
    });
    expect(error['error'], contains('"content"'));
    expect(refused.requests, isEmpty);
  });

  test('a board the wire barely fills in still answers', () async {
    final adapter = SolarStubAdapter({
      'GET /ideask/broads': [
        {
          'id': null,
          'name': null,
          'title': null,
          'workspace_id': null,
          'task_prefix': null,
          'description': null,
        },
      ],
      'GET /ideask/tasks/t1': {
        'id': null,
        'name': null,
        'task_key': null,
        'description': null,
        'content': null,
        'status': null,
        'priority': null,
        'deadline_at': null,
        'completed_at': null,
        'broad_id': null,
        'group_id': null,
        'parent_task_id': null,
        'assignees': null,
        'tags': null,
      },
    });

    final boards = await run(adapter, 'list_boards', {});
    expect((boards['boards'] as List).single, isEmpty);

    final task = await run(adapter, 'read_task', {'task_id': 't1'});
    expect(task, isEmpty);
  });

  test('a 401 reads as a session to renew', () async {
    final adapter = SolarStubAdapter(
      {'GET /ideask/broads': {'message': 'token expired'}},
      statuses: {'GET /ideask/broads': 401},
    );

    final result = await run(adapter, 'list_boards', {});

    expect(result['error'], contains('not signed in'));
    expect(result['error'], contains('token expired'));
  });

  test('the plugin is on demand, overrides nothing, and keeps the tool order', () {
    expect(plugin.onDemand, isTrue);
    expect(plugin.enabledByDefault, isFalse);
    expect(plugin.overrides, isEmpty);
    final built = plugin
        .buildTools(solarContext(solarDio(SolarStubAdapter({}))))
        .map((tool) => tool.name)
        .toList();
    expect(built, [
      'list_boards',
      'list_tasks',
      'read_task',
      'create_task',
      'update_task',
      'list_task_comments',
      'add_task_comment',
    ]);
  });
}
