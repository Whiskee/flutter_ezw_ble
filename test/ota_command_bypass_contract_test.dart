import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('OTA batches preserve exact owner through both native submission paths',
      () {
    // 只测试单包入口会漏掉合并时新增 batch 旁路；队列的每次重试也须校验同一 pair。
    final android = File(
      'android/src/main/kotlin/com/fzfstudio/ezw_ble/ble/BleManager.kt',
    ).readAsStringSync();
    final swift = File('ios/Classes/ble/BleManager.swift').readAsStringSync();
    final androidBatch = android.substring(
      android.indexOf('fun sendOtaPacketBatch('),
      android.indexOf('fun enterUpgradeState('),
    );
    final swiftBatch = swift.substring(
      swift.indexOf('func sendOtaPacketBatch('),
      swift.indexOf('private func queueDepthForOta('),
    );
    expect(androidBatch,
        contains('sessionGeneration = expectedSessionGeneration'));
    expect(androidBatch,
        contains('attemptGeneration = expectedAttemptGeneration'));
    expect(swiftBatch,
        contains('submit: { [weak self, device] peripheral, value in'));
    expect(swiftBatch, contains('self.validateOtaWriteIdentity('));
    expect(swiftBatch,
        contains('expectedSessionGeneration: expectedSessionGeneration'));
    expect(swiftBatch,
        contains('expectedAttemptGeneration: expectedAttemptGeneration'));
  });

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

  test(
    'Android OTA no-wait reports queue submission failures asynchronously',
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
      final callback = File(
        'android/src/main/kotlin/com/fzfstudio/ezw_ble/ble/BleGattSessionCallback.kt',
      ).readAsStringSync();
      final cmd = File(
        'android/src/main/kotlin/com/fzfstudio/ezw_ble/ble/models/BleCmd.kt',
      ).readAsStringSync();
      final error = File(
        'android/src/main/kotlin/com/fzfstudio/ezw_ble/ble/BleOtaWriteError.kt',
      ).readAsStringSync();

      expect(channel, contains('expectedSessionGeneration'));
      expect(channel, contains('expectedAttemptGeneration'));
      expect(channel, contains('BleManager.instance.quiteUpgradeState'));
      expect(
        channel,
        contains('result.error(error.code, error.reason, error.details)'),
      );
      expect(
        manager,
        contains('sessionGeneration = expectedSessionGeneration'),
      );
      expect(
          manager, contains('attemptGeneration = expectedAttemptGeneration'));
      expect(
          manager,
          contains(
              'submit = { data, expectedSessionGeneration, expectedAttemptGeneration ->'));
      expect(manager, contains('validateOtaWriteIdentity'));
      expect(manager, contains('attempt identity mismatch'));
      expect(manager, contains('hasExactBusinessGatt'));
      expect(manager, contains('QuiteUpgradeState rejected'));
      expect(manager, contains('drop queued command'));
      expect(manager, contains('BleOtaWriteSubmission.rejected'));
      expect(manager, contains('BleOtaWriteError.unavailable'));
      expect(manager, contains('BleOtaWriteError.unsupported'));
      expect(device, contains('supportsWriteWithoutResponse'));
      expect(device, contains('submitOtaCharacteristic'));
      expect(device, contains('ERROR_GATT_WRITE_REQUEST_BUSY'));
      expect(callback, contains('sessionGeneration = sessionGeneration'));
      expect(callback, contains('attemptGeneration = attemptGeneration'));
      expect(cmd, contains('"sessionGeneration" to sessionGeneration'));
      expect(cmd, contains('"attemptGeneration" to attemptGeneration'));
      expect(error, contains(r'${channel}_write_unavailable'));
      expect(channel, contains('sendOtaPacketBatch'));
      expect(error, contains('channel: String = BleWriteChannel.OTA'));
      expect(error, contains(r'${channel}_write_unsupported'));
    },
  );

  test(
    'iOS OTA no-wait validates optional exact session identity before queueing',
    () {
      final channel = File(
        'ios/Classes/ble/BleMethodChannel.swift',
      ).readAsStringSync();
      final manager = File(
        'ios/Classes/ble/BleManager.swift',
      ).readAsStringSync();

      expect(channel, contains('expectedSessionGeneration'));
      expect(channel, contains('expectedAttemptGeneration'));
      expect(channel, contains('BleManager.shared.quiteUpgradeState'));
      expect(manager, contains('validateOtaWriteIdentity'));
      expect(manager, contains('otaResponseIdentity'));
      expect(manager,
          contains('submit: { [weak self, device] peripheral, value in'));
      expect(
        manager,
        contains('BleExplicitCancellationMetadataPolicy.resolve'),
      );
      expect(manager, contains('attempt identity mismatch'));
      expect(manager, contains('quiteUpgradeState rejected'));
      expect(manager, contains('drop OTA response without exact identity'));
      expect(
        manager,
        contains('queue.enqueue(data: data, target: target, result: result)'),
      );
    },
  );
}
