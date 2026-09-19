/// macOS protects parts of the disk behind its privacy layer, independently of
/// file modes: the user's Desktop, Documents, Downloads and iCloud Drive, other
/// apps' data, and anything under `~/Library` that belongs to another app.
///
/// The first time this app reads one of those, macOS asks the user — and the
/// answer is remembered per app. Full Disk Access is the standing version of
/// that answer, and there is no API to request it: it can only be granted by
/// hand in System Settings. What the app can do is say so at the moment it
/// matters, and open the right pane.
library;

import 'dart:io';

import 'package:hooks_riverpod/hooks_riverpod.dart';

/// Deep link straight to the Full Disk Access list in System Settings. It is
/// the same `x-apple.systempreferences:` scheme every recent macOS answers to;
/// an unrecognized pane opens the Privacy & Security pane instead of failing.
const kFullDiskAccessSettingsUrl =
    'x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles';

/// What this app can read of the paths macOS protects.
enum ProtectedAccess {
  /// A protected path opened: the app has Full Disk Access.
  granted,

  /// Protected paths are there and none of them opened.
  denied,

  /// Nothing to ask: no known protected path exists on this machine, or this
  /// is not macOS. Reported rather than guessed, because a wrong "denied"
  /// sends the user to a settings pane for no reason.
  unknown,
}

/// The user's home directory — the real one, since a sandboxed app would see
/// its container here instead.
String _homeDirectory() {
  final environment = Platform.environment;
  final home = environment['HOME'] ?? environment['USERPROFILE'];
  return home == null || home.trim().isEmpty
      ? Directory.current.path
      : home.trim();
}

/// Files that belong to the system or to another app, and so open only with
/// Full Disk Access.
///
/// A list rather than one path: the user-level privacy database that older
/// releases kept at `~/Library/Application Support/com.apple.TCC/TCC.db` is
/// simply absent on newer ones, and a probe that does not exist can never
/// answer the question. [checkProtectedAccess] falls back from one to the
/// next.
List<String> _protectedProbes() => [
  '/Library/Application Support/com.apple.TCC/TCC.db',
  '${_homeDirectory()}/Library/Application Support/com.apple.TCC/TCC.db',
  '${_homeDirectory()}/Library/Messages/chat.db',
  '${_homeDirectory()}/Library/Safari/History.db',
];

/// Whether this app can read the paths macOS protects, established by opening
/// one of them: there is no query for the answer, and the state of the list in
/// System Settings says nothing about whether it covers this app.
///
/// [probes] is for tests and defaults to [_protectedProbes]. Files that do not
/// exist are skipped; when none exists the answer is [ProtectedAccess.unknown]
/// rather than a guess.
Future<ProtectedAccess> checkProtectedAccess({List<String>? probes}) async {
  if (!Platform.isMacOS) return ProtectedAccess.unknown;

  var asked = false;
  for (final path in probes ?? _protectedProbes()) {
    final file = File(path);
    if (!file.existsSync()) continue;
    asked = true;
    try {
      final handle = await file.open();
      await handle.close();
      return ProtectedAccess.granted;
    } on FileSystemException {
      continue;
    }
  }
  return asked ? ProtectedAccess.denied : ProtectedAccess.unknown;
}

/// Opens System Settings on the Full Disk Access list, detached so the app is
/// not held open by the helper process.
Future<void> openFullDiskAccessSettings() async {
  if (!Platform.isMacOS) return;
  await Process.start(
    'open',
    [kFullDiskAccessSettingsUrl],
    mode: ProcessStartMode.detached,
  );
}

/// The status behind the settings row; invalidate to re-probe after the user
/// has been to System Settings.
final fullDiskAccessProvider = FutureProvider<ProtectedAccess>(
  (ref) => checkProtectedAccess(),
);
