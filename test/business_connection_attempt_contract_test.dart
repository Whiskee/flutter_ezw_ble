import 'dart:io';

import 'package:flutter_ezw_ble/core/models/ble_business_connection_attempt.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Dart exposes exact business connection attempt API contract', () {
    const attempt = BleBusinessConnectionAttempt(
      uuid: 'left-uuid',
      sessionGeneration: 37,
      attemptGeneration: 9,
    );

    expect(attempt.toJson(), {
      'uuid': 'left-uuid',
      'sessionGeneration': 37,
      'attemptGeneration': 9,
    });
    expect(BleBusinessConnectionStatus.accepted.name, 'accepted');
    expect(BleBusinessConnectionStatus.attemptMismatch.name, 'attemptMismatch');
  });

  test(
      'native implementations expose exact attempt methods and fail-closed checks',
      () {
    final androidChannel = File(
            'android/src/main/kotlin/com/fzfstudio/ezw_ble/ble/BleMethodChannel.kt')
        .readAsStringSync();
    final androidManager =
        File('android/src/main/kotlin/com/fzfstudio/ezw_ble/ble/BleManager.kt')
            .readAsStringSync();
    final androidAttempt = File(
            'android/src/main/kotlin/com/fzfstudio/ezw_ble/ble/BleBusinessConnectionAttempt.kt')
        .readAsStringSync();
    final androidDevice = File(
            'android/src/main/kotlin/com/fzfstudio/ezw_ble/ble/models/BleDevice.kt')
        .readAsStringSync();
    final androidGattCallback = File(
            'android/src/main/kotlin/com/fzfstudio/ezw_ble/ble/BleGattSessionCallback.kt')
        .readAsStringSync();
    final iosChannel =
        File('ios/Classes/ble/BleMethodChannel.swift').readAsStringSync();
    final iosManager =
        File('ios/Classes/ble/BleManager.swift').readAsStringSync();
    final iosAttempt =
        File('ios/Classes/ble/BleBusinessConnectionAttempt.swift')
            .readAsStringSync();

    for (final method in [
      'prepareBusinessConnection',
      'commitBusinessConnection',
      'abortBusinessConnection',
    ]) {
      expect(androidChannel, contains(method));
      expect(iosChannel, contains(method));
    }

    for (final status in [
      'accepted',
      'invalidArguments',
      'missingAdmission',
      'attemptMismatch',
      'missingPrepare',
      'deviceDisconnected',
      'gattNotReady',
    ]) {
      expect(androidAttempt, contains(status));
      expect(iosAttempt, contains(status));
    }

    expect(androidManager, contains('querySystemGattConnectionState'));
    expect(androidManager, contains('hasCompleteGattReadiness'));
    expect(androidManager, contains('return setConnected(attempt.uuid)'));
    expect(
        androidManager,
        contains(
            'fun setConnected(uuid: String): BleBusinessConnectionStatus'));
    expect(androidDevice, contains('notifiedPsTypes'));
    expect(androidDevice, contains('markNotifyReady'));
    expect(androidDevice, contains('containsAll(expectedTypes)'));
    expect(androidGattCallback, contains('inFlightDescriptorPsType'));
    expect(androidGattCallback, contains('device.markNotifyReady'));
    expect(iosManager, contains('session?.peripheral.state == .connected'));
    expect(iosManager, contains('BleGattReadiness.make'));
    expect(
        iosManager,
        contains(
            'return setConnected(uuid: attempt.uuid, expectedAttempt: attempt)'));
    expect(iosManager,
        contains('expectedAttempt: BleBusinessConnectionAttempt? = nil'));
  });
}
