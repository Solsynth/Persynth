import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Future<String> _try(String key) async {
  try {
    return 'ok:${(await rootBundle.loadString(key)).length}';
  } catch (e) {
    return 'err:$e';
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (var round = 1; round <= 3; round++) {
    testWidgets('round $round sequential', (tester) async {
      debugPrint('R$round en=${await _try('assets/i18n/en-US.json')}');
      debugPrint('R$round zh=${await _try('assets/i18n/zh-CN.json')}');
      debugPrint(
        'R$round pending=${TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.pendingMessageCount}',
      );
    });
  }
}
