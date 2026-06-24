import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Android already-connected foreground connect replays native state', () {
    final managerSource =
        File('android/src/main/kotlin/com/fzfstudio/ezw_ble/ble/BleManager.kt')
            .readAsStringSync();

    expect(managerSource, contains('replayAlreadyConnectedForegroundState'));
    expect(
      managerSource,
      contains('device is already connected, replay state'),
    );
    expect(
      managerSource,
      contains('stale connected gatt not found in system connected list'),
    );
    expect(
      managerSource,
      contains(
          'handleConnectState(plan.request.uuid, replayName, replayState)'),
    );
  });
}
