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
      contains('createConnectCallBack(plan.request.uuid)'),
    );
    expect(
      reconnectSource,
      contains('createConnectCallback(task.uuid)'),
    );
  });

  test(
      'Android auto reconnect keeps the live passive GATT after business connected',
      () {
    final reconnectSource = File(
      'android/src/main/kotlin/com/fzfstudio/ezw_ble/ble/BleAutoReconnectSupervisor.kt',
    ).readAsStringSync();

    expect(
      reconnectSource,
      contains('passiveGattIsLiveConnection'),
    );
    expect(
      reconnectSource,
      contains('passiveGatt == device.myGatt'),
    );
    expect(
      reconnectSource,
      contains('device.connectState.isConnected'),
    );
    expect(
      reconnectSource,
      contains('如果在 arm 阶段 close 它，Dart 已收到 connected，但系统 GATT 会立刻断开'),
    );
    expect(
      reconnectSource,
      contains('if (passiveGatt != null && !passiveGattIsLiveConnection)'),
    );
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
