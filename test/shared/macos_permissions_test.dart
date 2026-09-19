import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:synth_pet/shared/macos_permissions.dart';

void main() {
  late Directory directory;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('sn_macos_permissions');
  });

  tearDown(() async {
    if (directory.existsSync()) await directory.delete(recursive: true);
  });

  test('tells a readable probe from a denied one', () async {
    final readable = File('${directory.path}/readable')
      ..writeAsStringSync('content');
    final locked = File('${directory.path}/locked')
      ..writeAsStringSync('content');
    // Mode 000 denies every reader, whatever macOS has decided about this
    // app, so the denial half of this test holds on any platform.
    await Process.run('chmod', ['000', locked.path]);

    if (Platform.isMacOS) {
      expect(
        await checkProtectedAccess(probes: [readable.path]),
        ProtectedAccess.granted,
      );
    }
    expect(
      await checkProtectedAccess(probes: [locked.path]),
      ProtectedAccess.denied,
    );
    // Nothing to ask: a probe that is not there is not an answer.
    expect(
      await checkProtectedAccess(probes: ['${directory.path}/missing']),
      ProtectedAccess.unknown,
    );
  });

  test('the pane it opens is the Full Disk Access list', () {
    expect(kFullDiskAccessSettingsUrl, contains('Privacy_AllFiles'));
  });
}
