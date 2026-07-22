import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Android GATT callbacks are scoped to the requested device UUID', () {
    final callbackSource = File(
      'android/src/main/kotlin/com/fzfstudio/ezw_ble/ble/BleGattSessionCallback.kt',
    ).readAsStringSync();
    final managerSource =
        File('android/src/main/kotlin/com/fzfstudio/ezw_ble/ble/BleManager.kt')
            .readAsStringSync();
    final reconnectSource = File(
      'android/src/main/kotlin/com/fzfstudio/ezw_ble/ble/BleAutoReconnectSupervisor.kt',
    ).readAsStringSync();

    expect(callbackSource, contains('private val expectedUuid: String?'));
    expect(
      callbackSource,
      contains('!address.equals(expectedUuid, ignoreCase = true)'),
    );
    expect(
      callbackSource,
      contains('connection connected") ?: return'),
    );
    expect(
      callbackSource,
      contains('非目标事件只忽略，不 close，防止误杀其它设备的正常 GATT'),
    );
    expect(
      managerSource,
      matches(
        RegExp(
          r'createConnectCallBack\(\s*plan\.request\.uuid,\s*source = BleConnectSource\.FOREGROUND',
        ),
      ),
    );
    expect(
      reconnectSource,
      contains(
          'createConnectCallback(task.uuid, task.source, task.sessionGeneration)'),
    );
  });

  test(
      'Android auto reconnect keeps the live passive GATT after business connected',
      () {
    final reconnectSource = File(
      'android/src/main/kotlin/com/fzfstudio/ezw_ble/ble/BleAutoReconnectSupervisor.kt',
    ).readAsStringSync();

    final armStart = reconnectSource.indexOf('fun arm(');
    final armEnd = reconnectSource.indexOf('fun activate(', armStart);
    final armSource = reconnectSource.substring(armStart, armEnd);

    expect(armSource, contains('pending GATT 必须复用'));
    expect(armSource, isNot(contains('passiveGatt?.close()')));
    expect(armSource, isNot(contains('passiveGatt?.disconnect()')));
  });

  test('manual activation promotes a pending owner without reopening GATT', () {
    final reconnectSource = File(
      'android/src/main/kotlin/com/fzfstudio/ezw_ble/ble/BleAutoReconnectSupervisor.kt',
    ).readAsStringSync();
    final managerSource =
        File('android/src/main/kotlin/com/fzfstudio/ezw_ble/ble/BleManager.kt')
            .readAsStringSync();

    final activateStart = reconnectSource.indexOf('fun activate(');
    final promoteStart = reconnectSource.indexOf(
      'fun promotePendingAttempt(',
      activateStart,
    );
    final activateSource =
        reconnectSource.substring(activateStart, promoteStart);

    expect(activateSource,
        contains('task.passiveGatt != null || task.timer != null'));
    expect(activateSource,
        contains('source == BleConnectSource.MANUAL_RECONNECT'));
    expect(activateSource, contains('promotePendingAdmission(device.uuid)'));
    expect(activateSource, isNot(contains('passiveGatt?.close()')));
    expect(activateSource, isNot(contains('passiveGatt?.disconnect()')));
    expect(
        managerSource,
        contains(
            'autoReconnectSupervisor.activate(seedDevice, source, sessionGeneration)'));
  });

  test('Android plugin unregisters Activity lifecycle callbacks on detach', () {
    final pluginSource = File(
      'android/src/main/kotlin/com/fzfstudio/ezw_ble/FlutterEzwBlePlugin.kt',
    ).readAsStringSync();

    expect(pluginSource, contains('private var lifecycleApplication'));
    expect(pluginSource, contains('private var activityLifecycleCallbacks'));
    expect(pluginSource,
        contains('application.registerActivityLifecycleCallbacks(callbacks)'));
    expect(pluginSource, contains('unregisterActivityLifecycleCallbacks()'));
    expect(
      pluginSource,
      contains('application.unregisterActivityLifecycleCallbacks(callbacks)'),
    );
  });
}
