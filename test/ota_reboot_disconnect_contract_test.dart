import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('OTA reboot teardown has a dedicated method-channel contract', () {
    final platform =
        File('lib/flutter_ezw_ble_platform_interface.dart').readAsStringSync();
    final method =
        File('lib/flutter_ezw_ble_method_channel.dart').readAsStringSync();
    final android = File(
      'android/src/main/kotlin/com/fzfstudio/ezw_ble/ble/BleMethodChannel.kt',
    ).readAsStringSync();
    final ios =
        File('ios/Classes/ble/BleMethodChannel.swift').readAsStringSync();

    expect(platform, contains('disconnectForOtaReboot'));
    expect(method, contains('"disconnectForOtaReboot"'));
    expect(method, contains('"expectedSessionGeneration"'));
    expect(method, contains('"expectedAttemptGeneration"'));
    expect(android, contains('DISCONNECT_FOR_OTA_REBOOT'));
    expect(android, contains('expectedSessionGeneration'));
    expect(android, contains('expectedAttemptGeneration'));
    expect(ios, contains('case disconnectForOtaReboot'));
    expect(ios, contains('expectedSessionGeneration'));
    expect(ios, contains('expectedAttemptGeneration'));
  });

  test('OTA reboot does not reuse the user-cancel path or schedule immediately',
      () {
    final android = File(
      'android/src/main/kotlin/com/fzfstudio/ezw_ble/ble/BleManager.kt',
    ).readAsStringSync();
    final ios = File('ios/Classes/ble/BleManager.swift').readAsStringSync();
    final iosStore =
        File('ios/Classes/ble/BleReconnectStore.swift').readAsStringSync();

    final androidStart = android.indexOf('fun disconnectForOtaReboot');
    final androidEnd = android.indexOf('\n    /**', androidStart + 1);
    final androidMethod = android.substring(androidStart, androidEnd);
    expect(androidMethod, contains('BleConnectState.DISCONNECT_FROM_SYS'));
    expect(androidMethod, contains('scheduleAutoReconnect = false'));
    expect(androidMethod, contains('markOtaRebootDisconnectSuppression'));
    expect(androidMethod,
        contains('autoReconnectSupervisor.detachPhysicalGattForOtaReboot'));
    expect(androidMethod, contains('lastEpochAcceptedAdmissions[key]'));
    expect(androidMethod, contains('cancelConnectionAdmission'));
    expect(androidMethod, contains('synthesizeOtaRebootTerminalAdmission'));
    expect(androidMethod, contains('OTA reboot disconnect rejected'));
    expect(android, contains('BleConnectSource.AUTO_RECONNECT'));
    expect(android, contains('MutableMap<String, Pair<Long, Long>>'));
    expect(androidMethod, isNot(contains('missing epoch-accepted admission')));
    expect(androidMethod, isNot(contains('autoReconnectSupervisor.cancel')));
    expect(androidMethod, isNot(contains('removePersistedReconnectTarget')));

    final iosStart = ios.indexOf('func disconnectForOtaReboot');
    final iosEnd = ios.indexOf('\n    /// 标记/消费 OTA', iosStart);
    final iosMethod = ios.substring(iosStart, iosEnd);
    expect(iosMethod, contains('state: .disconnectFromSys'));
    expect(iosMethod, contains('source: metadata?.source'));
    expect(iosMethod, contains('generation: metadata?.sessionGeneration'));
    expect(
        iosMethod, contains('attemptGeneration: metadata?.attemptGeneration'));
    expect(iosMethod, contains('suppressReconnectSchedule: true'));
    expect(iosMethod, contains('ota reboot disconnect rejected'));
    expect(iosMethod, isNot(contains('cancelReconnectTask')));
    expect(iosMethod, isNot(contains('removePersistedReconnectTarget')));
    expect(ios, contains('consumeOtaRebootDisconnectSuppression'));
    expect(ios, contains('peripheralObjectId'));
    expect(
        ios,
        contains(
            'currentConnectionAdmission(uuid: peripheral.identifier.uuidString)'));
    expect(ios, contains('native reconnect schedule suppressed, tag='));
    expect(android, contains('consumeOtaRebootDisconnectSuppression'));
    expect(iosStore, contains('lastConnectedGeneration'));
  });

  test('Android OTA reboot preserves owner but drops the closed physical GATT',
      () {
    final reconnect = File(
      'android/src/main/kotlin/com/fzfstudio/ezw_ble/ble/BleAutoReconnectSupervisor.kt',
    ).readAsStringSync();

    final detachStart = reconnect.indexOf('fun detachPhysicalGattForOtaReboot');
    final detachEnd = reconnect.indexOf('\n    /**', detachStart + 1);
    final detachMethod = reconnect.substring(detachStart, detachEnd);

    expect(detachMethod, contains('task.passiveGatt = null'));
    expect(detachMethod, contains('task.pendingPhysicalDeadline = null'));
    expect(detachMethod, contains('invalidateRetrySchedule(task)'));
    expect(detachMethod, contains('owner preserved'));
    expect(detachMethod, isNot(contains('reconnectTasks.remove')));
    expect(detachMethod, isNot(contains('persistReconnectTarget')));
  });
}
