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
    final androidAttemptDispatcher = File(
      'android/src/main/kotlin/com/fzfstudio/ezw_ble/ble/BleReconnectAttemptDispatcher.kt',
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
      contains('beginDirectReconnectAttempt'),
    );
    expect(
      iosReconnect,
      contains('connectPeripheralAfterCancellationBarrier'),
    );
    expect(
      iosReconnect,
      contains('state != .noDeviceFound'),
    );
    expect(
      iosReconnect,
      contains('no peripheral cache yet, wait concurrent scan/retrieve'),
    );
    // UUID 已知的常规回连不扫描；仅 CBError 14 的配对失配恢复才有一个 20 秒、
    // 精确 owner 的例外扫描窗口，不能回退为所有 autoReconnect scan-first。
    final normalReconnect = iosReconnect.substring(
      iosReconnect.indexOf('func beginDirectReconnectAttempt'),
      iosReconnect.indexOf('func preparePeerPairingRecovery'),
    );
    expect(normalReconnect, isNot(contains('startScan()')));
    expect(iosReconnect,
        contains('pairingRecoveryDiscoveryTimeout: TimeInterval { 20.0 }'));
    expect(iosReconnect, contains('resumePeerPairingRecoveryIfMatched'));
    expect(
      iosConnect,
      contains('autoReconnect directConnect: no peripheral cache, skip scan'),
    );
    expect(
      iosManager,
      isNot(contains('passiveReconnectWatchdogTimers')),
    );
    expect(
      iosReconnect,
      contains('[CBConnectPeripheralOptionEnableAutoReconnect: true]'),
    );
    expect(
      iosReconnect,
      isNot(
        contains('["CBConnectPeripheralOptionEnableAutoReconnect": true]'),
      ),
    );
    expect(
      iosManager,
      contains('systemAutoReconnectInProgress: isReconnecting'),
    );
    expect(
      iosManager,
      contains('adoptSystemAutoReconnect'),
    );
    expect(
      iosManager,
      contains('pendingPhysicalConnectWatchdogs'),
    );
    expect(
      iosManager,
      isNot(
        contains(
            'sendConnectStateToFlutter(uuid: uuid, name: name, state: .timeout'),
      ),
    );
    expect(
      androidAttemptDispatcher,
      contains('所有回连路径固定使用 autoConnect=true'),
    );
    expect(androidAttemptDispatcher, contains('device.connectGatt('));
    expect(androidAttemptDispatcher,
        contains('device.connectGatt(context, true, callback)'));
    expect(
      androidReconnect,
      contains('startPendingPhysicalDeadline'),
    );
    expect(
      androidReconnect,
      contains('pendingPhysicalDeadlineMs(config)'),
    );
    expect(
      androidReconnect,
      contains('invalidatePendingPassiveGatt(uuid, expectedGatt)'),
    );
    expect(
      androidReconnect,
      contains('不经 handleConnectState(TIMEOUT)'),
    );
    expect(
      androidReconnect,
      isNot(contains('BleConnectState.CONNECTING')),
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
      isNot(
        contains(
            'handleConnectState(task.uuid, task.name, BleConnectState.TIMEOUT)'),
      ),
    );
  });
}
