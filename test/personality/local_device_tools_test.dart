import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:synth_pet/personality/local_device_tools.dart';
import 'package:synth_pet/personality/local_tool.dart';

SnLocalTool _tool(List<SnLocalTool> tools, String name) =>
    tools.firstWhere((tool) => tool.name == name);

/// The name column of one listing row, past the kind column and any padding.
String _nameOf(String line) =>
    line.substring(5).trim().split(RegExp(r'\s{2,}')).first;

void main() {
  late Directory root;
  late List<SnLocalTool> tools;

  setUp(() async {
    final created = await Directory.systemTemp.createTemp('sn_device_tools');
    root = Directory(await created.resolveSymbolicLinks());
    tools = buildLocalDeviceTools(root: root.path);
  });

  tearDown(() async {
    if (root.existsSync()) await root.delete(recursive: true);
  });

  group('the set', () {
    test('offers the three device tools', () {
      expect(tools.map((tool) => tool.name).toList(), [
        'read_file_local',
        'list_dir_local',
        'run_command_local',
      ]);
    });

    test('resolves relative paths against the given root', () async {
      final file = File('${root.path}/notes.txt');
      await file.writeAsString('hello');

      final text = await _tool(tools, 'read_file_local').execute({
        'path': 'notes.txt',
      });

      expect(text, startsWith('Path: ${root.path}/notes.txt\n'));
      expect(text, endsWith('hello'));
    });
  });

  group('read_file_local', () {
    test('reports the size, the line count, and the text', () async {
      await File('${root.path}/notes.txt').writeAsString('one\ntwo\nthree');

      final text = await _tool(tools, 'read_file_local').execute({
        'path': 'notes.txt',
      });

      expect(text, 'Path: ${root.path}/notes.txt\n'
          'Size: 13 B, 3 line(s)\n'
          '\n'
          'one\ntwo\nthree');
    });

    test('takes an absolute path as written', () async {
      final file = await File(
        '${root.path}/absolute.txt',
      ).writeAsString('absolute');

      final text = await _tool(tools, 'read_file_local').execute({
        'path': file.path,
      });

      expect(text, contains('Path: ${file.path}\n'));
      expect(text, endsWith('absolute'));
    });

    test('truncates to max_chars, clamped to 500', () async {
      await File('${root.path}/long.txt').writeAsString('a' * 2000);

      final text = await _tool(tools, 'read_file_local').execute({
        'path': 'long.txt',
        'max_chars': 10,
      });

      expect(text, contains('Truncated to 500 characters.'));
      expect(text.split('\n\n').last, 'a' * 500);
    });

    test('reports a missing file instead of throwing', () async {
      final text = await _tool(tools, 'read_file_local').execute({
        'path': 'nope.txt',
      });

      expect(text, 'Error: no such file: ${root.path}/nope.txt');
    });

    test('points a directory at the listing tool', () async {
      await Directory('${root.path}/folder').create();

      final text = await _tool(tools, 'read_file_local').execute({
        'path': 'folder',
      });

      expect(text, 'Error: ${root.path}/folder is a directory; '
          'use list_dir_local.');
    });

    test('names a binary file rather than dumping it', () async {
      await File(
        '${root.path}/image.bin',
      ).writeAsBytes([0, 1, 2, 3, 0, 255]);

      final text = await _tool(tools, 'read_file_local').execute({
        'path': 'image.bin',
      });

      expect(text, 'Path: ${root.path}/image.bin\n'
          'Size: 6 B\n'
          '\n'
          'Binary file (6 bytes); not shown.');
    });

    test('reads a huge file only as far as the cap and says so', () async {
      await File('${root.path}/huge.txt').writeAsString('a' * (1200 * 1024));

      final text = await _tool(tools, 'read_file_local').execute({
        'path': 'huge.txt',
      });

      expect(text, contains('Size: 1.2 MB, '));
      expect(text, contains('Truncated to 20000 characters.'));
      expect(text, contains('Only the first 1.0 MB of the file was read.'));
    });

    test('explains a permission denial instead of quoting an errno', () async {
      final locked = File('${root.path}/locked.txt')
        ..writeAsStringSync('secret');
      await Process.run('chmod', ['000', locked.path]);

      final text = await _tool(tools, 'read_file_local').execute({
        'path': 'locked.txt',
      });

      expect(text, startsWith('Error: '));
      expect(
        text,
        contains(Platform.isMacOS ? 'Full Disk Access' : 'Permission denied'),
      );
    });

    test('requires a path', () async {
      expect(
        await _tool(tools, 'read_file_local').execute({}),
        'Error: `path` is required.',
      );
      expect(
        await _tool(tools, 'read_file_local').execute({'path': '   '}),
        'Error: `path` is required.',
      );
    });
  });

  group('list_dir_local', () {
    test('lists directories first, then files, alphabetically', () async {
      await Directory('${root.path}/zebra').create();
      await Directory('${root.path}/apple').create();
      await File('${root.path}/Beta.txt').writeAsString('bb');
      await File('${root.path}/alpha.txt').writeAsString('a');

      final text = await _tool(tools, 'list_dir_local').execute({
        'path': root.path,
      });

      final lines = text.split('\n\n').last.split('\n');
      expect(text, startsWith('Path: ${root.path}\n4 entries\n\n'));
      expect(lines.map(_nameOf).toList(), [
        'apple/',
        'zebra/',
        'alpha.txt',
        'Beta.txt',
      ]);
      expect(lines[0], startsWith('dir  apple/'));
      expect(lines[2], contains('1 B'));
    });

    test('defaults to the root and reports an empty directory', () async {
      final text = await _tool(tools, 'list_dir_local').execute({});

      expect(text, 'Path: ${root.path}\n0 entries\n\n(empty)');
    });

    test('marks a symlink as one', () async {
      await File('${root.path}/target.txt').writeAsString('x');
      await Link('${root.path}/alias.txt').create('${root.path}/target.txt');

      final text = await _tool(tools, 'list_dir_local').execute({});

      expect(text, contains('link alias.txt'));
      expect(text, contains('file target.txt'));
    });

    test('reports a path that is not a directory', () async {
      await File('${root.path}/file.txt').writeAsString('x');

      expect(
        await _tool(tools, 'list_dir_local').execute({'path': 'file.txt'}),
        'Error: ${root.path}/file.txt is not a directory.',
      );
      expect(
        await _tool(tools, 'list_dir_local').execute({'path': 'gone'}),
        'Error: no such directory: ${root.path}/gone',
      );
    });
  });

  group('run_command_local', () {
    test('runs in the root and reports the exit code with the output', () async {
      await File('${root.path}/marker.txt').writeAsString('in the root');

      final text = await _tool(tools, 'run_command_local').execute({
        'command': 'pwd && cat marker.txt',
      });

      expect(
        text,
        '\$ pwd && cat marker.txt\n'
        'Exit: 0\n'
        '\n'
        '${root.path}\nin the root',
      );
    });

    test('honours cwd relative to the root', () async {
      await Directory('${root.path}/sub').create();
      await File('${root.path}/sub/here.txt').writeAsString('yes');

      final text = await _tool(tools, 'run_command_local').execute({
        'command': 'cat here.txt',
        'cwd': 'sub',
      });

      expect(text, endsWith('yes'));
    });

    test('reports a non-zero exit and separates stderr', () async {
      final text = await _tool(tools, 'run_command_local').execute({
        'command': 'echo oops >&2; exit 3',
      });

      expect(text, '\$ echo oops >&2; exit 3\n'
          'Exit: 3\n'
          '\n'
          'stderr:\noops');
    });

    test('kills a command that outlives its timeout', () async {
      final started = DateTime.now();

      final text = await _tool(tools, 'run_command_local').execute({
        'command': 'sleep 30',
        'timeout_seconds': 1,
      });

      expect(text, startsWith('\$ sleep 30\nTimed out after 1s and was killed.'));
      expect(
        DateTime.now().difference(started),
        lessThan(const Duration(seconds: 10)),
      );
    });

    test('caps the output', () async {
      final text = await _tool(tools, 'run_command_local').execute({
        'command': 'yes x | head -n 500',
        'max_chars': 500,
      });

      expect(text, contains('Truncated to 500 characters.'));
      expect(
        text.split('\n\n').last.length,
        inInclusiveRange(400, 500),
      );
    });

    test('rejects a missing command and a missing working directory', () async {
      expect(
        await _tool(tools, 'run_command_local').execute({}),
        'Error: `command` is required.',
      );
      expect(
        await _tool(tools, 'run_command_local').execute({
          'command': 'pwd',
          'cwd': 'not-here',
        }),
        'Error: working directory does not exist: ${root.path}/not-here',
      );
    });
  });
}
