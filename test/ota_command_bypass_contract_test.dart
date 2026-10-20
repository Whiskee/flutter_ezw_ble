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

    expect(queue, contains(r'\(channel)_write_stalled'));
    expect(queue, contains(r'\(channel)_write_cancelled'));
    expect(queue, contains('func enqueueBatch('));
    expect(queue, contains('func logFileOnly'));
    expect(queue, contains('channel != OtaWriteChannel.ota'));
    expect(queue, contains('backpressureStallTimeout: TimeInterval = 15.0'));
    expect(queue, contains('pending.removeFirst()'));
    expect(queue, contains('"expectedSessionGeneration"'));
    expect(queue, contains('"expectedAttemptGeneration"'));
    expect(queue, isNot(contains('backpressureGraceTimeout')));
    expect(queue, isNot(contains('backpressureEnteredGrace')));
    expect(queue, contains('head.target.submit(peripheral, head.data)'));
    expect(manager, contains('OtaWriteQueue.unavailableError'));
    expect(manager, contains('OtaWriteQueue.unsupportedError'));
    expect(manager, contains('disconnectForOtaRecovery'));
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
    expect(manager, contains('sessionGeneration = expectedSessionGeneration'));
    expect(manager, contains('attemptGeneration = expectedAttemptGeneration'));
    expect(
      manager,
      matches(RegExp(
        r'submit = \{\s*data,\s*expectedSessionGeneration,\s*expectedAttemptGeneration,\s*submitTransactionId,\s*submitOtaGeneration,\s*submitInstanceId,\s*->',
      )),
    );
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
    expect(error, contains(r'${channel}_write_unsupported'));
  });

  test('native OTA log policy suppresses routine success chatter only', () {
    final androidQueue = File(
      'android/src/main/kotlin/com/fzfstudio/ezw_ble/ble/BleAndroidOtaWriteQueue.kt',
    ).readAsStringSync();
    final androidCallback = File(
      'android/src/main/kotlin/com/fzfstudio/ezw_ble/ble/BleGattSessionCallback.kt',
    ).readAsStringSync();
    final iosQueue = File(
      'ios/Classes/ble/OtaWriteQueue.swift',
    ).readAsStringSync();
    final iosManager =
        File('ios/Classes/ble/BleManager.swift').readAsStringSync();

    expect(androidQueue, contains('logFileOnly'));
    expect(androidQueue, contains('channel != BleWriteChannel.OTA'));
    expect(androidQueue, contains(r'[ezw_ble][$channel][android] failed'));
    expect(androidQueue, contains(r'[ezw_ble][$channel][android] stalled'));
    // The merged callback delegates the lazy logging decision to the shared
    // policy. Kotlin policy/callback behavior tests cover both enabled values,
    // failures and owner dispatch; this assertion verifies production wiring.
    expect(androidCallback, contains('BleOtaDebugLogPolicy.logWriteCallback('));
    expect(androidCallback,
        contains('success = status == BluetoothGatt.GATT_SUCCESS'));
    expect(androidCallback, contains('onCharacteristicWriteComplete('));

    expect(iosQueue, contains('func logFileOnly'));
    expect(iosQueue, contains('channel != OtaWriteChannel.ota'));
    expect(iosQueue, contains('[ezw_ble][\\(channel)] stalled'));
    expect(iosQueue, contains('[ezw_ble][\\(channel)] cancelled'));
    expect(iosManager, isNot(contains('[ezw_ble][ota] enqueued uuid=')));
    expect(iosManager, contains('privateService.type != BlePsTypeValue.ota'));
    expect(iosManager, contains('drop OTA response without exact identity'));
    expect(iosManager, contains('already delivered to Dart/metrics'));
  });

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
      expect(
        manager,
        contains('submit: { [weak self, device] peripheral, value in'),
      );
      expect(
        manager,
        contains('BleExplicitCancellationMetadataPolicy.resolve'),
      );
      expect(manager, contains('attempt identity mismatch'));
      expect(manager, contains('quiteUpgradeState rejected'));
      expect(manager, contains('drop OTA response without exact identity'));
      expect(manager,
          contains('expectedSessionGeneration: expectedSessionGeneration'));
      expect(manager,
          contains('expectedAttemptGeneration: expectedAttemptGeneration'));
    },
  );

  test('measured native OTA metrics preserve errors and freeze link context',
      () {
    final androidChannel = File(
      'android/src/main/kotlin/com/fzfstudio/ezw_ble/ble/BleMethodChannel.kt',
    ).readAsStringSync();
    final androidManager = File(
      'android/src/main/kotlin/com/fzfstudio/ezw_ble/ble/BleManager.kt',
    ).readAsStringSync();
    final iosChannel = File(
      'ios/Classes/ble/BleMethodChannel.swift',
    ).readAsStringSync();
    final iosQueue = File(
      'ios/Classes/ble/OtaWriteQueue.swift',
    ).readAsStringSync();

    expect(
      androidChannel,
      contains('var frozenLinkMetrics: Map<String, Any> = emptyMap()'),
    );
    expect(
      androidChannel,
      contains('linkMetrics = { metrics -> frozenLinkMetrics = metrics }'),
    );
    expect(androidChannel, contains('metrics.putAll(frozenLinkMetrics)'));
    expect(
      androidChannel,
      isNot(contains('metrics.putAll(BleManager.instance.otaBatchLinkMetrics')),
    );
    expect(
      androidManager,
      contains('linkMetrics?.invoke(otaBatchLinkMetrics(uuid))'),
    );

    expect(
      iosChannel,
      contains('guard value == nil || value is [String: Any] else'),
    );
    expect(iosChannel, contains('result(value)'));
    expect(
        iosChannel, contains('var metrics = value as? [String: Any] ?? [:]'));
    expect(iosQueue, contains('var monotonicNow: TimeInterval { get }'));
    expect(
      iosQueue,
      contains('clock.monotonicNow - startedAt'),
    );
  });
}
