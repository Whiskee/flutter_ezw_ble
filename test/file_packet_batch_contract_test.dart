// 文件通道批量写的原生契约回归。
//
// 文件 RAW 批次与 OTA 批次共用队列实现，但必须保持通道隔离：`quiteUpgradeState`
// 只取消 OTA attempt，如果两条通道共用队列实例，一次退出升级就会打断用户正在进行的
// 文件传输；反过来升级态仍必须拒绝文件写入。这些约束都在原生侧，只能按源码锁定。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Android file batch owns a queue separate from the OTA attempt', () {
    final manager = File(
      'android/src/main/kotlin/com/fzfstudio/ezw_ble/ble/BleManager.kt',
    ).readAsStringSync();
    final channel = File(
      'android/src/main/kotlin/com/fzfstudio/ezw_ble/ble/BleMethodChannel.kt',
    ).readAsStringSync();

    expect(manager, contains('fileWriteQueues'));
    expect(manager, contains('fun sendFilePacketBatch'));
    expect(manager, contains('BleWriteChannel.FILE'));
    expect(channel, contains('SEND_FILE_PACKET_BATCH'));
    expect(
      channel,
      contains('BleManager.instance.sendFilePacketBatch(uuid, packets, psType)'),
    );

    // 退出升级只能取消 OTA 队列；文件队列必须留给自己的 generation 收口。
    final cancelAttempt = manager.substring(
      manager.indexOf('private fun cancelOtaWriteAttempt'),
      manager.indexOf('private fun discardWriteQueuesForSession'),
    );
    expect(cancelAttempt, contains('otaWriteQueues[reconnectKey(uuid)]'));
    expect(cancelAttempt, isNot(contains('fileWriteQueues')));

    // 物理 session 失效与整机 teardown 必须同时释放两条通道的 Dart await。
    expect(manager, contains('otaWriteQueues.remove(key)?.cancelAll(reason)'));
    expect(manager, contains('fileWriteQueues.remove(key)?.cancelAll(reason)'));
  });

  test('Android normal queue yields the GATT slot to an in-flight file batch',
      () {
    final manager = File(
      'android/src/main/kotlin/com/fzfstudio/ezw_ble/ble/BleManager.kt',
    ).readAsStringSync();
    final policy = File(
      'android/src/main/kotlin/com/fzfstudio/ezw_ble/ble/'
      'BleGattWriteCallbackOwnerPolicy.kt',
    ).readAsStringSync();

    expect(
      manager,
      contains('fileWriteQueues[key]?.hasOutstandingGattWrite == true'),
    );
    expect(manager, contains('fileHasOutstandingWrite ='));
    expect(policy, contains('BleGattWriteCallbackOwner.FILE'));
  });

  test('iOS file batch uses its own write queue and shares readiness', () {
    final manager = File('ios/Classes/ble/BleManager.swift').readAsStringSync();
    final channel = File(
      'ios/Classes/ble/BleMethodChannel.swift',
    ).readAsStringSync();

    expect(manager, contains('fileWriteQueues'));
    expect(manager, contains('func sendFilePacketBatch'));
    expect(manager, contains('channel: OtaWriteChannel.file'));
    expect(channel, contains('sendFilePacketBatch'));

    // peripheralIsReady 不区分通道，两条队列都要被唤醒，否则文件批次只能等兜底重查。
    final ready = manager.substring(
      manager.indexOf('func peripheralIsReady(toSendWriteWithoutResponse'),
    );
    final readyBody = ready.substring(0, ready.indexOf('\n    }'));
    expect(
      readyBody,
      contains('otaWriteQueues[uuid]?.onPeripheralReadyToSendWriteWithoutResponse()'),
    );
    expect(
      readyBody,
      contains(
        'fileWriteQueues[uuid]?.onPeripheralReadyToSendWriteWithoutResponse()',
      ),
    );
  });

  test('both platforms keep the file batch behind the upgrade gate', () {
    final androidManager = File(
      'android/src/main/kotlin/com/fzfstudio/ezw_ble/ble/BleManager.kt',
    ).readAsStringSync();
    final iosManager = File(
      'ios/Classes/ble/BleManager.swift',
    ).readAsStringSync();

    final androidSubmit = androidManager.substring(
      androidManager.indexOf('private fun submitPacketBatch'),
    );
    expect(androidSubmit, contains('BleUpgradeCommandPolicy.canSend'));
    expect(androidSubmit, contains('upgrade gate rejected'));

    final iosSubmit = iosManager.substring(
      iosManager.indexOf('private func submitPacketBatch'),
    );
    expect(iosSubmit, contains('upgradeStateRegistry.canSend'));
    expect(iosSubmit, contains('upgrade gate rejected'));
  });
}
