import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('native auto reconnect does not enter explicit scan routes', () {
    final androidManager =
        File('android/src/main/kotlin/com/fzfstudio/ezw_ble/ble/BleManager.kt')
            .readAsStringSync();
    final androidReconnect = File(
      'android/src/main/kotlin/com/fzfstudio/ezw_ble/ble/BleAutoReconnectSupervisor.kt',
    ).readAsStringSync();
    final iosReconnect =
        File('ios/Classes/ble/BleAutoReconnectCoordinator.swift')
            .readAsStringSync();
    final iosConnect =
        File('ios/Classes/ble/BleConnectCoordinator.swift').readAsStringSync();
    final iosManager =
        File('ios/Classes/ble/BleManager.swift').readAsStringSync();

    expect(
      androidReconnect,
      contains('private fun shouldScheduleReconnect(state: BleConnectState)'),
    );
    expect(
      androidManager,
      contains('该入口只建立长期回连 owner：不发起前台连接'),
    );
    expect(
      androidManager,
      contains('direct connect without scan'),
    );

    expect(
      iosReconnect,
      contains('autoReconnect 已经持有稳定 CoreBluetooth identity'),
    );
    expect(
      iosReconnect,
      contains('directConnect: true'),
    );
    expect(
      iosReconnect,
      contains('state != .noDeviceFound'),
    );
    expect(
      iosReconnect,
      contains('按固定防抖等下一轮系统恢复机会'),
    );
    expect(
      iosReconnect,
      isNot(contains('directConnect: config.autoReconnectUseNativePassive')),
    );
    expect(
      iosConnect,
      contains('autoReconnect directConnect: no peripheral cache, skip scan'),
    );
    expect(
      iosConnect,
      contains('startNativePassiveReconnectWatchdog'),
    );
    expect(
      iosManager,
      contains(
          'native passive watchdog observed pending connect, keep connecting'),
    );
    expect(
      iosManager,
      isNot(
        contains(
            'sendConnectStateToFlutter(uuid: uuid, name: name, state: .timeout'),
      ),
    );
    expect(
      androidReconnect,
      contains('passive deadline reached, rebuild after'),
    );
    expect(
      androidReconnect,
      contains('passive watchdog rebuild missing handle'),
    );
    expect(
      androidReconnect,
      contains('过高频率 register/unregister'),
    );
    expect(
      androidReconnect,
      isNot(contains('PASSIVE_REFRESH_RETRY_DELAY_MS')),
    );
    expect(
      androidReconnect,
      contains('误判为“仍有等待任务”而无法重建 GATT'),
    );
    expect(
      androidReconnect,
      isNot(contains('task.timer == null')),
    );
    expect(
      androidReconnect,
      isNot(
        contains(
            'handleConnectState(task.uuid, task.name, BleConnectState.TIMEOUT)'),
      ),
    );
  });
}
