import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Android OTA gate keeps default deny and explicit control bypass', () {
    final channel = File(
      'android/src/main/kotlin/com/fzfstudio/ezw_ble/ble/BleMethodChannel.kt',
    ).readAsStringSync();
    final manager = File(
      'android/src/main/kotlin/com/fzfstudio/ezw_ble/ble/BleManager.kt',
    ).readAsStringSync();

    expect(channel, contains('as? Boolean ?: false'));
    expect(manager, contains('BleUpgradeCommandPolicy.canSend'));
    expect(manager, contains('Cannot send non-OTA commands during upgrade'));
  });

  test('iOS OTA gate keeps default deny and explicit control bypass', () {
    final channel = File(
      'ios/Classes/ble/BleMethodChannel.swift',
    ).readAsStringSync();
    final manager = File('ios/Classes/ble/BleManager.swift').readAsStringSync();

    expect(channel, contains('as? Bool ?? false'));
    expect(channel, contains('sendOtaPacketBatch'));
    expect(manager, contains('upgradeStateRegistry.canSend'));
    expect(manager, isNot(contains('upgradeDevices: [String]?')));
  });

  test('iOS OTA no-wait fails closed before CoreBluetooth submission', () {
    final queue = File(
      'ios/Classes/ble/OtaWriteQueue.swift',
    ).readAsStringSync();
    final manager = File('ios/Classes/ble/BleManager.swift').readAsStringSync();

    // 队列被 OTA 与文件共用后 code 由通道前缀拼出；默认通道仍是 ota，
    // 所以 OTA 侧的 ota_write_* 分类对 Dart 保持不变。
    expect(queue, contains('static let ota = "ota"'));
    expect(queue, contains(r'\(channel)_write_stalled'));
    expect(queue, contains(r'\(channel)_write_cancelled'));
    expect(queue, contains('channel: String = OtaWriteChannel.ota'));
    expect(queue, contains('head.target.submit(peripheral, head.data)'));
    expect(manager, contains('OtaWriteQueue.unavailableError'));
    expect(manager, contains('OtaWriteQueue.unsupportedError'));
    expect(manager, isNot(contains('fallback to existing path uuid')));
    expect(
      manager,
      isNot(
        contains(
          'OTA characteristic missing writeWithoutResponse property, fallback',
        ),
      ),
    );
  });

  test('Android OTA no-wait reports queue submission failures asynchronously',
      () {
    final channel = File(
      'android/src/main/kotlin/com/fzfstudio/ezw_ble/ble/BleMethodChannel.kt',
    ).readAsStringSync();
    final manager = File(
      'android/src/main/kotlin/com/fzfstudio/ezw_ble/ble/BleManager.kt',
    ).readAsStringSync();
    final device = File(
      'android/src/main/kotlin/com/fzfstudio/ezw_ble/ble/models/BleDevice.kt',
    ).readAsStringSync();
    final error = File(
      'android/src/main/kotlin/com/fzfstudio/ezw_ble/ble/BleOtaWriteError.kt',
    ).readAsStringSync();

    expect(channel,
        contains('BleManager.instance.sendCmdNoWait(uuid, data, psType)'));
    expect(channel, contains('sendOtaPacketBatch'));
    expect(channel,
        contains('result.error(error.code, error.reason, error.details)'));
    expect(
        manager, contains('otaWriteQueueFor(uuid).enqueue(data, completion)'));
    expect(manager, contains('BleOtaWriteSubmission.rejected'));
    expect(manager, contains('BleOtaWriteError.unavailable'));
    expect(manager, contains('BleOtaWriteError.unsupported'));
    expect(device, contains('supportsWriteWithoutResponse'));
    expect(device, contains('submitOtaCharacteristic'));
    expect(device, contains('ERROR_GATT_WRITE_REQUEST_BUSY'));
    expect(error, contains(r'const val OTA = "ota"'));
    expect(error, contains(r'${channel}_write_unavailable'));
    expect(error, contains(r'${channel}_write_unsupported'));
    expect(error, contains('channel: String = BleWriteChannel.OTA'));
  });
}
