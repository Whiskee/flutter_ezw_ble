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
    expect(android, contains('DISCONNECT_FOR_OTA_REBOOT'));
    expect(ios, contains('case disconnectForOtaReboot'));
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
    expect(androidMethod, isNot(contains('autoReconnectSupervisor.cancel')));
    expect(androidMethod, isNot(contains('removePersistedReconnectTarget')));

    final iosStart = ios.indexOf('func disconnectForOtaReboot');
    final iosEnd = ios.indexOf('\n    /// 标记/消费 OTA', iosStart);
    final iosMethod = ios.substring(iosStart, iosEnd);
    expect(iosMethod, contains('state: .disconnectFromSys'));
    expect(iosMethod, contains('suppressReconnectSchedule: true'));
    expect(iosMethod, isNot(contains('cancelReconnectTask')));
    expect(iosMethod, isNot(contains('removePersistedReconnectTarget')));
    expect(ios, contains('consumeOtaRebootDisconnectSuppression'));
    expect(ios,
        contains('OTA reboot teardown suppresses native reconnect schedule'));
    expect(android, contains('consumeOtaRebootDisconnectSuppression'));
    expect(iosStore, contains('lastConnectedGeneration'));
  });
}
