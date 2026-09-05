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
    expect(manager, contains('upgradeStateRegistry.canSend'));
    expect(manager, isNot(contains('upgradeDevices: [String]?')));
  });

  test('iOS OTA no-wait fails closed before CoreBluetooth submission', () {
    final queue = File(
      'ios/Classes/ble/OtaWriteQueue.swift',
    ).readAsStringSync();
    final manager = File('ios/Classes/ble/BleManager.swift').readAsStringSync();

    expect(queue, contains('ota_write_stalled'));
    expect(queue, contains('ota_write_cancelled'));
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
      expect(error, contains('ota_write_unavailable'));
      expect(error, contains('ota_write_unsupported'));
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
