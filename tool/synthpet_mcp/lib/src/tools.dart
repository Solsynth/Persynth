/// The filesystem and shell tool bodies the daemon exposes over MCP.
///
/// These were ported verbatim from the app's in-process device tools
/// (`lib/personality/local_device_tools.dart`), which the app dropped when
/// the sandbox came back: the same semantics, now running in a process that
/// is allowed to touch the user's files. Relative paths resolve against
/// [base], the directory the daemon was started with (the user's home by
/// default); absolute paths are taken as written.
///
/// Every body returns a string — including the `Error: ...` lines, which are
/// answers about the request for the model to read, not defects of the tool.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// The user's home directory: the base every relative path resolves against.
String homeDirectory() {
  final environment = Platform.environment;
  final home = environment['HOME'] ?? environment['USERPROFILE'];
  return home == null || home.trim().isEmpty
      ? Directory.current.path
      : home.trim();
}

/// [root] as an absolute [Directory], with any trailing separator removed so
/// joining a relative path onto it cannot produce a doubled slash.
Directory directoryOf(String root) {
  final path = Directory(root).absolute.path;
  final trimmed = path.replaceFirst(RegExp(r'[/\\]+$'), '');
  // A bare root ("/") would trim to nothing; keep it as written.
  return Directory(trimmed.isEmpty ? path : trimmed);
}

/// Joins [path] onto [base] unless it is already absolute.
String resolve(Directory base, String path) {
  if (path.startsWith('~')) {
    final home = homeDirectory();
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
int boundedInt(Object? value, int fallback, int min, int max) {
  final requested = value is num && value.isFinite ? value.truncate() : fallback;
  if (requested < min) return min;
  if (requested > max) return max;
  return requested;
}

/// The [name] argument as a non-empty trimmed string, or null.
String? stringArgument(Map<String, dynamic> arguments, String name) {
  final value = arguments[name];
  if (value is! String) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

/// Human-readable byte count, e.g. `1.2 MB`.
String formatBytes(int bytes) {
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
String formatTime(DateTime time) {
  String pad(int value) => value.toString().padLeft(2, '0');
  final local = time.toLocal();
  return '${local.year}-${pad(local.month)}-${pad(local.day)} '
      '${pad(local.hour)}:${pad(local.minute)}';
}

const defaultMaxChars = 20000;
const minMaxChars = 500;
const maxMaxChars = 200000;

/// Bytes searched for a NUL before a file counts as binary, and the most that
/// is ever read from one.
const binaryProbeBytes = 8000;
const maxReadBytes = 1 * 1024 * 1024;

/// The most directory entries listed in one call.
const maxEntries = 200;

const defaultTimeoutSeconds = 30;
const maxTimeoutSeconds = 120;

/// Clips [text] to [max] characters, reporting how much was dropped.
({String text, bool truncated}) truncate(String text, int max) {
  if (text.length <= max) return (text: text, truncated: false);
  return (text: text.substring(0, max), truncated: true);
}

/// Lines in [text], counting a final line with no trailing newline.
int lineCount(String text) =>
    text.isEmpty ? 0 : '\n'.allMatches(text).length + 1;

/// `Error: ...` lines are answers about the request, not defects: a missing
/// file or a failing command is reported as text for the model to read.
String error(String message) => 'Error: $message';

/// `EACCES`/`EPERM`: on macOS the usual cause is not a file mode but the
/// privacy layer, and its fix is a settings pane rather than a retry — so say
/// which pane. Elaborating beats handing the model an errno it will work
/// around by trying the same path again.
String permissionHint(String path, FileSystemException error) {
  final code = error.osError?.errorCode;
  if (code != 13 && code != 1) return '';
  if (!Platform.isMacOS) return 'Permission denied for $path.';
  return 'macOS is protecting $path. Grant the Persynth MCP server '
      '(synthpet_mcp) Full Disk Access in System Settings → Privacy & '
      'Security (or ask the user for a folder it may read).';
}

/// What went wrong with [path], in the terms the reader of the error needs.
String ioMessage(String verb, String path, FileSystemException error) {
  final hint = permissionHint(path, error);
  if (hint.isNotEmpty) return hint;
  return 'could not $verb $path — ${error.osError?.message ?? error.message}';
}

/// `read_file`: read a text file from the user's machine.
Future<String> readFile(Directory base, Map<String, dynamic> arguments) async {
  final requested = stringArgument(arguments, 'path');
  if (requested == null) return error('`path` is required.');

  final path = resolve(base, requested);
  final type = FileSystemEntity.typeSync(path, followLinks: true);
  if (type == FileSystemEntityType.notFound) {
    return error('no such file: $path');
  }
  if (type == FileSystemEntityType.directory) {
    return error('$path is a directory; use list_dir.');
  }

  final file = File(path);
  final maxChars = boundedInt(
    arguments['max_chars'],
    defaultMaxChars,
    minMaxChars,
    maxMaxChars,
  );

  final int length;
  try {
    length = await file.length();
  } on FileSystemException catch (caught) {
    return error(ioMessage('read', path, caught));
  }

  final Uint8List head;
  try {
    head = await readHead(file);
  } on FileSystemException catch (caught) {
    return error(ioMessage('read', path, caught));
  }

  final probe = head.length > binaryProbeBytes
      ? head.sublist(0, binaryProbeBytes)
      : head;
  if (probe.contains(0)) {
    return 'Path: $path\n'
        'Size: ${formatBytes(length)}\n\n'
        'Binary file ($length bytes); not shown.';
  }

  final truncatedBytes = length > head.length;
  // Valid UTF-8 is the common case; a partly invalid file still yields its
  // readable text instead of failing outright.
  final decoded = utf8.decode(head, allowMalformed: true);
  final clipped = truncate(decoded, maxChars);

  final header = [
    'Path: $path',
    'Size: ${formatBytes(length)}, ${lineCount(clipped.text)} line(s)',
    if (clipped.truncated) 'Truncated to $maxChars characters.',
    if (truncatedBytes)
      'Only the first ${formatBytes(head.length)} of the file was read.',
  ];

  return '${header.join('\n')}\n\n${clipped.text}'.trimRight();
}

/// Reads at most [maxReadBytes] from [file], streamed so a huge file is never
/// held whole in memory.
Future<Uint8List> readHead(File file) async {
  final builder = BytesBuilder(copy: false);
  await for (final chunk in file.openRead()) {
    if (builder.length + chunk.length >= maxReadBytes) {
      builder.add(chunk.sublist(0, maxReadBytes - builder.length));
      break;
    }
    builder.add(chunk);
  }
  return builder.takeBytes();
}

/// `list_dir`: list a directory on the user's machine.
Future<String> listDir(Directory base, Map<String, dynamic> arguments) async {
  final requested = stringArgument(arguments, 'path') ?? base.path;
  final path = resolve(base, requested);
  final type = FileSystemEntity.typeSync(path, followLinks: true);
  if (type == FileSystemEntityType.notFound) {
    return error('no such directory: $path');
  }
  if (type != FileSystemEntityType.directory) {
    return error('$path is not a directory.');
  }

  final List<FileSystemEntity> children;
  try {
    children = await Directory(path).list(followLinks: false).toList();
  } on FileSystemException catch (caught) {
    return error(ioMessage('list', path, caught));
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

  final shown = rows.take(maxEntries).toList();
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
        if (row.size != null) formatBytes(row.size!),
        if (row.modified != null) formatTime(row.modified!),
      ].join(' ').trimRight(),
  ];

  if (body.isEmpty) return '${header.join('\n')}\n\n(empty)';
  return '${header.join('\n')}\n\n${body.join('\n')}';
}

/// `run_command`: run a shell command on the user's machine.
Future<String> runCommand(
  Directory base,
  Map<String, dynamic> arguments,
) async {
  final command = stringArgument(arguments, 'command');
  if (command == null) return error('`command` is required.');

  final cwd = resolve(base, stringArgument(arguments, 'cwd') ?? '.');
  if (FileSystemEntity.typeSync(cwd, followLinks: true) !=
      FileSystemEntityType.directory) {
    return error('working directory does not exist: $cwd');
  }

  final timeout = Duration(
    seconds: boundedInt(
      arguments['timeout_seconds'],
      defaultTimeoutSeconds,
      1,
      maxTimeoutSeconds,
    ),
  );
  final maxChars = boundedInt(
    arguments['max_chars'],
    defaultMaxChars,
    minMaxChars,
    maxMaxChars,
  );

  final Process process;
  try {
    process = await Process.start(
      shell,
      shellArguments(command),
      workingDirectory: cwd,
      runInShell: false,
    );
  } on ProcessException catch (caught) {
    return error('could not start a shell — ${caught.message}');
  }

  final stdout = decoded(process.stdout);
  final stderr = decoded(process.stderr);

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
  final clipped = truncate(body.toString(), maxChars);

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

  final text = clipped.text.isEmpty
      ? header.join('\n')
      : '${header.join('\n')}\n\n${clipped.text}';
  return text.trimRight();
}

/// The platform shell, and the argument that hands it a whole command line.
String get shell => Platform.isWindows ? 'cmd.exe' : '/bin/sh';

List<String> shellArguments(String command) =>
    Platform.isWindows ? ['/c', command] : ['-c', command];

/// Collects a stream as text, never failing on bytes that are not UTF-8.
Future<String> decoded(Stream<List<int>> stream) async {
  final builder = BytesBuilder(copy: false);
  await for (final chunk in stream) {
    builder.add(chunk);
    // Off the rails output is still an answer; cap it well above the display
    // cap so clipping happens on the assembled text.
    if (builder.length > 8 * 1024 * 1024) break;
  }
  return utf8.decode(builder.takeBytes(), allowMalformed: true);
}
