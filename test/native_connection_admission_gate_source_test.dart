import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Android and iOS expose the same callback-ordered admission gate', () {
    final androidGate = File(
      'android/src/main/kotlin/com/fzfstudio/ezw_ble/ble/BleConnectionAdmissionGate.kt',
    ).readAsStringSync();
    final iosGate = File(
      'ios/Classes/ble/BleConnectionAdmissionGate.swift',
    ).readAsStringSync();

    for (final source in <String>[
      androidGate,
      iosGate,
    ]) {
      expect(source, contains('registerAttempt'));
      expect(source, contains('onPhysicalConnected'));
      expect(source, contains('manual'));
      expect(source, contains('automatic'));
      expect(source, contains('suspendAndReset'));
      expect(source, contains('promote'));
      expect(source, contains('cancelSession'));
    }
  });

  test('iOS cancellation tokens and reconnect identity migration are wired',
      () {
    final gate = File('ios/Classes/ble/BleConnectionAdmissionGate.swift')
        .readAsStringSync();
    final reconnect = File('ios/Classes/ble/BleAutoReconnectCoordinator.swift')
        .readAsStringSync();
    final store =
        File('ios/Classes/ble/BleReconnectStore.swift').readAsStringSync();

    expect(gate, contains('BlePeripheralCancellationBarrierGate'));
    expect(gate, contains('timedOutDebtCounts'));
    expect(gate, contains('current == Int.max ? Int.max : current + 1'));
    expect(gate, contains('activeTokens[key] == token'));
    expect(reconnect, contains('migrateReconnectTaskIdentityIfNeeded'));
    expect(reconnect, contains('system-connected identity takeover'));
    expect(reconnect, contains('reconnectIdentityAliases'));
    expect(store, contains('func migrate('));
    expect(store, contains('matchesSystemConnectedPeripheral'));
  });

  test('bluetooth reset cannot leak a manual source into a new attempt', () {
    final android = File(
      'android/src/main/kotlin/com/fzfstudio/ezw_ble/ble/BleAutoReconnectSupervisor.kt',
    ).readAsStringSync();
    final ios = File('ios/Classes/ble/BleAutoReconnectCoordinator.swift')
        .readAsStringSync();

    for (final source in <String>[android, ios]) {
      expect(source, contains('afterTransportReset()'));
      expect(source, contains('preserveAttemptSource'));
    }
    expect(android, contains('preserveAttemptSource = false'));
    expect(ios, contains('preserveAttemptSource: false'));
  });
}
