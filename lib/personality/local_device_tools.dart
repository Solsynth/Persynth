import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:synth_pet/personality/local_tool.dart';

// ---------------------------------------------------------------------------
// Local device tools
// ---------------------------------------------------------------------------

/// The filesystem and shell tools, in the order the model sees them.
///
/// These are the sharp edge of the app: they read this machine's files and run
/// commands on it. They are therefore off unless the user turns them on, and
/// [root] — the directory relative paths resolve against — is the user's home
/// by default. A GUI app launched from Finder or a bundle has no meaningful
/// working directory, so a model asking for `notes.txt` must land somewhere it
/// can reason about; absolute paths are taken as written.
List<SnLocalTool> buildLocalDeviceTools({String? root}) {
  final base = _directoryOf(root ?? _homeDirectory());

  return [
    SnLocalTool(
      name: 'read_file_local',
      description:
          "Read a text file from the user's machine. Relative paths resolve "
          'against their home directory; absolute paths are used as given.\n\n'
          'Returns the file size and line count, then its text. Binary files '
          'are reported rather than dumped. Large files are truncated to '
          '`max_chars`.',
      parameters: const <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'path': <String, dynamic>{
            'type': 'string',
            'description':
                'File to read: absolute, or relative to the home directory.',
          },
          'max_chars': <String, dynamic>{
            'type': 'integer',
            'minimum': 500,
            'maximum': 200000,
            'description': 'Output character cap (500-200000, default 20000).',
          },
        },
        'required': <String>['path'],
      },
      execute: (arguments) => _readFile(base, arguments),
    ),
    SnLocalTool(
      name: 'list_dir_local',
      description:
          "List a directory on the user's machine: one entry per line, "
          'directories marked with a trailing slash, with size and last '
          'modified time. Relative paths resolve against their home directory.',
      parameters: const <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'path': <String, dynamic>{
            'type': 'string',
            'description':
                'Directory to list; defaults to the home directory. Absolute, '
                'or relative to the home directory.',
          },
        },
      },
      execute: (arguments) => _listDir(base, arguments),
    ),
    SnLocalTool(
      name: 'run_command_local',
      description:
          "Run a shell command on the user's machine and return its output.\n\n"
          'The command runs through the platform shell ("/bin/sh -c", '
          '"cmd /c" on Windows) with the home directory as its working '
          'directory unless `cwd` says otherwise. stdout and stderr are both '
          'captured, along with the exit code; a command that outruns '
          '`timeout_seconds` is killed. Destructive commands run with all the '
          "user's own authority — check with them before anything that "
          'deletes, overwrites, or installs.',
      parameters: const <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'command': <String, dynamic>{
            'type': 'string',
            'description': 'Command line to run, exactly as a shell would see it.',
          },
          'cwd': <String, dynamic>{
            'type': 'string',
            'description':
                'Working directory; defaults to the home directory. Absolute, '
                'or relative to the home directory.',
          },
          'timeout_seconds': <String, dynamic>{
            'type': 'integer',
            'minimum': 1,
            'maximum': 120,
            'description': 'Kill the command after this long (1-120, default 30).',
          },
          'max_chars': <String, dynamic>{
            'type': 'integer',
            'minimum': 500,
            'maximum': 200000,
            'description': 'Output character cap (500-200000, default 20000).',
          },
        },
        'required': <String>['command'],
      },
      execute: (arguments) => _runCommand(base, arguments),
    ),
  ];
}

/// The user's home directory: the base every relative path resolves against.
String _homeDirectory() {
  final environment = Platform.environment;
  final home = environment['HOME'] ?? environment['USERPROFILE'];
  return home == null || home.trim().isEmpty
      ? Directory.current.path
      : home.trim();
}

/// [root] as an absolute [Directory], with any trailing separator removed so
/// joining a relative path onto it cannot produce a doubled slash.
Directory _directoryOf(String root) {
  final path = Directory(root).absolute.path;
  final trimmed = path.replaceFirst(RegExp(r'[/\\]+$'), '');
  // A bare root ("/") would trim to nothing; keep it as written.
  return Directory(trimmed.isEmpty ? path : trimmed);
}

/// Joins [path] onto [base] unless it is already absolute.
String _resolve(Directory base, String path) {
  if (path.startsWith('~')) {
    final home = _homeDirectory();
    final rest = path.substring(1).replaceFirst(RegExp(r'^[/\\]+'), '');
    return rest.isEmpty ? home : '$home${Platform.pathSeparator}$rest';
  }
  final asFile = File(path);
  if (asFile.isAbsolute) return path;
  final separator = Platform.pathSeparator;
  return '${base.path}$separator${path.replaceFirst(RegExp(r'^[/\\]+'), '')}';
}

/// Reads an integer argument clamped into `[min, max]`, falling back to
/// [fallback] when absent or unusable.
int _boundedInt(Object? value, int fallback, int min, int max) {
  final requested = value is num && value.isFinite ? value.truncate() : fallback;
  if (requested < min) return min;
  if (requested > max) return max;
  return requested;
}

String? _stringArgument(Map<String, dynamic> arguments, String name) {
  final value = arguments[name];
  if (value is! String) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

/// Human-readable byte count, e.g. `1.2 MB`.
String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const units = ['KB', 'MB', 'GB', 'TB'];
  var value = bytes / 1024;
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return '${value.toStringAsFixed(value < 10 ? 1 : 0)} ${units[unit]}';
}

/// `2026-09-19 14:03` in local time.
String _formatTime(DateTime time) {
  String pad(int value) => value.toString().padLeft(2, '0');
  final local = time.toLocal();
  return '${local.year}-${pad(local.month)}-${pad(local.day)} '
      '${pad(local.hour)}:${pad(local.minute)}';
}

const _defaultMaxChars = 20000;
const _minMaxChars = 500;
const _maxMaxChars = 200000;

/// Bytes searched for a NUL before a file counts as binary, and the most that
/// is ever read from one.
const _binaryProbeBytes = 8000;
const _maxReadBytes = 1 * 1024 * 1024;

/// The most directory entries listed in one call.
const _maxEntries = 200;

const _defaultTimeoutSeconds = 30;
const _maxTimeoutSeconds = 120;

/// Clips [text] to [max] characters, reporting how much was dropped.
({String text, bool truncated}) _truncate(String text, int max) {
  if (text.length <= max) return (text: text, truncated: false);
  return (text: text.substring(0, max), truncated: true);
}

/// Lines in [text], counting a final line with no trailing newline.
int _lineCount(String text) =>
    text.isEmpty ? 0 : '\n'.allMatches(text).length + 1;

/// `Error: ...` lines are answers about the request, not defects: a missing
/// file or a failing command is reported as text for the model to read.
String _error(String message) => 'Error: $message';

/// `EACCES`/`EPERM`: on macOS the usual cause is not a file mode but the
/// privacy layer, and its fix is a settings pane rather than a retry — so say
/// which pane. Elaborating beats handing the model an errno it will work
/// around by trying the same path again.
String _permissionHint(String path, FileSystemException error) {
  final code = error.osError?.errorCode;
  if (code != 13 && code != 1) return '';
  if (!Platform.isMacOS) return 'Permission denied for $path.';
  return 'macOS is protecting $path. Grant SynthPet Full Disk Access in '
      'System Settings → Privacy & Security (or ask the user for a folder it '
      'may read).';
}

/// What went wrong with [path], in the terms the reader of the error needs.
String _ioMessage(String verb, String path, FileSystemException error) {
  final hint = _permissionHint(path, error);
  if (hint.isNotEmpty) return hint;
  return 'could not $verb $path — ${error.osError?.message ?? error.message}';
}

Future<String> _readFile(
  Directory base,
  Map<String, dynamic> arguments,
) async {
  final requested = _stringArgument(arguments, 'path');
  if (requested == null) return _error('`path` is required.');

  final path = _resolve(base, requested);
  final type = FileSystemEntity.typeSync(path, followLinks: true);
  if (type == FileSystemEntityType.notFound) {
    return _error('no such file: $path');
  }
  if (type == FileSystemEntityType.directory) {
    return _error('$path is a directory; use list_dir_local.');
  }

  final file = File(path);
  final maxChars = _boundedInt(
    arguments['max_chars'],
    _defaultMaxChars,
    _minMaxChars,
    _maxMaxChars,
  );

  final int length;
  try {
    length = await file.length();
  } on FileSystemException catch (error) {
    return _error(_ioMessage('read', path, error));
  }

  final Uint8List head;
  try {
    head = await _readHead(file);
  } on FileSystemException catch (error) {
    return _error(_ioMessage('read', path, error));
  }

  final probe = head.length > _binaryProbeBytes
      ? head.sublist(0, _binaryProbeBytes)
      : head;
  if (probe.contains(0)) {
    return 'Path: $path\n'
        'Size: ${_formatBytes(length)}\n\n'
        'Binary file ($length bytes); not shown.';
  }

  final truncatedBytes = length > head.length;
  // Valid UTF-8 is the common case; a partly invalid file still yields its
  // readable text instead of failing outright.
  final decoded = utf8.decode(head, allowMalformed: true);
  final clipped = _truncate(decoded, maxChars);

  final header = [
    'Path: $path',
    'Size: ${_formatBytes(length)}, ${_lineCount(clipped.text)} line(s)',
    if (clipped.truncated) 'Truncated to $maxChars characters.',
    if (truncatedBytes)
      'Only the first ${_formatBytes(head.length)} of the file was read.',
  ];

  return '${header.join('\n')}\n\n${clipped.text}'.trimRight();
}

/// Reads at most [_maxReadBytes] from [file], streamed so a huge file is never
/// held whole in memory.
Future<Uint8List> _readHead(File file) async {
  final builder = BytesBuilder(copy: false);
  await for (final chunk in file.openRead()) {
    if (builder.length + chunk.length >= _maxReadBytes) {
      builder.add(chunk.sublist(0, _maxReadBytes - builder.length));
      break;
    }
    builder.add(chunk);
  }
  return builder.takeBytes();
}

Future<String> _listDir(
  Directory base,
  Map<String, dynamic> arguments,
) async {
  final requested = _stringArgument(arguments, 'path') ?? base.path;
  final path = _resolve(base, requested);
  final type = FileSystemEntity.typeSync(path, followLinks: true);
  if (type == FileSystemEntityType.notFound) {
    return _error('no such directory: $path');
  }
  if (type != FileSystemEntityType.directory) {
    return _error('$path is not a directory.');
  }

  final List<FileSystemEntity> children;
  try {
    children = await Directory(path).list(followLinks: false).toList();
  } on FileSystemException catch (error) {
    return _error(_ioMessage('list', path, error));
  }

  final rows = <({String name, String kind, int? size, DateTime? modified})>[];
  for (final child in children) {
    final name = child.path.split(Platform.pathSeparator).last;
    // A link is reported as one even when it resolves: the listing is about
    // what is in the directory, not about where the links lead.
    final kind = switch (FileSystemEntity.typeSync(
      child.path,
      followLinks: false,
    )) {
      FileSystemEntityType.directory => 'dir',
      FileSystemEntityType.link => 'link',
      _ => 'file',
    };
    if (kind == 'link') {
      rows.add((name: name, kind: kind, size: null, modified: null));
      continue;
    }
    final FileStat stat;
    try {
      stat = await child.stat();
    } on FileSystemException {
      rows.add((name: name, kind: kind, size: null, modified: null));
      continue;
    }
    rows.add((
      name: name,
      kind: kind,
      size: kind == 'file' ? stat.size : null,
      modified: stat.modified,
    ));
  }

  // Directories first, then files, each alphabetically and case-insensitively:
  // a listing is meant to be scanned, not puzzled over.
  rows.sort((a, b) {
    final byKind = (a.kind == 'dir' ? 0 : 1).compareTo(b.kind == 'dir' ? 0 : 1);
    if (byKind != 0) return byKind;
    return a.name.toLowerCase().compareTo(b.name.toLowerCase());
  });

  final shown = rows.take(_maxEntries).toList();
  final width = shown.fold(
    0,
    (max, row) => row.name.length > max ? row.name.length : max,
  );

  final header = [
    'Path: $path',
    '${rows.length} entr${rows.length == 1 ? 'y' : 'ies'}'
        '${rows.length > shown.length ? ', first ${shown.length} shown' : ''}',
  ];
  final body = [
    for (final row in shown)
      [
        row.kind.padRight(4),
        (row.kind == 'dir' ? '${row.name}/' : row.name).padRight(width + 2),
        if (row.size != null) _formatBytes(row.size!),
        if (row.modified != null) _formatTime(row.modified!),
      ].join(' ').trimRight(),
  ];

  if (body.isEmpty) return '${header.join('\n')}\n\n(empty)';
  return '${header.join('\n')}\n\n${body.join('\n')}';
}

Future<String> _runCommand(
  Directory base,
  Map<String, dynamic> arguments,
) async {
  final command = _stringArgument(arguments, 'command');
  if (command == null) return _error('`command` is required.');

  final cwd = _resolve(base, _stringArgument(arguments, 'cwd') ?? '.');
  if (FileSystemEntity.typeSync(cwd, followLinks: true) !=
      FileSystemEntityType.directory) {
    return _error('working directory does not exist: $cwd');
  }

  final timeout = Duration(
    seconds: _boundedInt(
      arguments['timeout_seconds'],
      _defaultTimeoutSeconds,
      1,
      _maxTimeoutSeconds,
    ),
  );
  final maxChars = _boundedInt(
    arguments['max_chars'],
    _defaultMaxChars,
    _minMaxChars,
    _maxMaxChars,
  );

  final Process process;
  try {
    process = await Process.start(
      _shell,
      _shellArguments(command),
      workingDirectory: cwd,
      runInShell: false,
    );
  } on ProcessException catch (error) {
    return _error('could not start a shell — ${error.message}');
  }

  final stdout = _decoded(process.stdout);
  final stderr = _decoded(process.stderr);

  var timedOut = false;
  var exitCode = -1;
  try {
    exitCode = await process.exitCode.timeout(timeout);
  } on TimeoutException {
    // The command outlived its deadline: kill it and report what it managed to
    // print instead of leaving it running behind the conversation.
    timedOut = true;
    process.kill(ProcessSignal.sigkill);
    exitCode = await process.exitCode.timeout(
      const Duration(seconds: 5),
      onTimeout: () => -1,
    );
  }

  final out = await stdout;
  final err = await stderr;

  final body = StringBuffer();
  if (out.isNotEmpty) body.write(out.trimRight());
  if (err.isNotEmpty) {
    if (body.isNotEmpty) body.write('\n\n');
    body.write('stderr:\n${err.trimRight()}');
  }
  final clipped = _truncate(body.toString(), maxChars);

  final header = [
    '\$ $command',
    timedOut
        ? 'Timed out after ${timeout.inSeconds}s and was killed.'
        : 'Exit: $exitCode',
    if (clipped.truncated) 'Truncated to $maxChars characters.',
    if (err.contains('Operation not permitted') && Platform.isMacOS)
      'Something here was blocked by macOS rather than by the command: either '
          'the working directory is protected, or the command touched a '
          'protected path. Full Disk Access in System Settings → Privacy & '
          'Security lifts that.',
  ];

  final text = clipped.text.isEmpty ? header.join('\n') : '${header.join('\n')}\n\n${clipped.text}';
  return text.trimRight();
}

/// The platform shell, and the argument that hands it a whole command line.
String get _shell => Platform.isWindows ? 'cmd.exe' : '/bin/sh';

List<String> _shellArguments(String command) =>
    Platform.isWindows ? ['/c', command] : ['-c', command];

/// Collects a stream as text, never failing on bytes that are not UTF-8.
Future<String> _decoded(Stream<List<int>> stream) async {
  final builder = BytesBuilder(copy: false);
  await for (final chunk in stream) {
    builder.add(chunk);
    // Off the rails output is still an answer; cap it well above the display
    // cap so clipping happens on the assembled text.
    if (builder.length > 8 * 1024 * 1024) break;
  }
  return utf8.decode(builder.takeBytes(), allowMalformed: true);
}
