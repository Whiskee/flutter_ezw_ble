import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final callback = File(
    'android/src/main/kotlin/com/fzfstudio/ezw_ble/ble/BleGattSessionCallback.kt',
  ).readAsStringSync();
  final manager = File(
    'android/src/main/kotlin/com/fzfstudio/ezw_ble/ble/BleManager.kt',
  ).readAsStringSync();
  final methodChannel = File(
    'android/src/main/kotlin/com/fzfstudio/ezw_ble/ble/BleMethodChannel.kt',
  ).readAsStringSync();
  final store = File(
    'android/src/main/kotlin/com/fzfstudio/ezw_ble/ble/BleReconnectStore.kt',
  ).readAsStringSync();

  test('5403 protected write gates ordinary notify and connectFinish', () {
    final write = callback.indexOf('startSecurityGateWrite(');
    final ordinary = callback.indexOf('startPrivateGattReadiness(');
    final notify = callback.indexOf('setCharacteristicNotification');
    final finish = callback.indexOf('connectingFlowFinish(');

    expect(write, greaterThan(0));
    expect(ordinary, greaterThan(write));
    expect(notify, greaterThan(ordinary));
    expect(finish, greaterThan(notify));
    expect(
        callback, contains('BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT'));
    expect(callback, contains('securityGateAttempts.consume('));
  });

  test('Android config parses and persists securityGate', () {
    expect(methodChannel, contains('get("securityGate")'));
    expect(methodChannel, contains('toBleSecurityGate()'));
    expect(store,
        contains('put("securityGate", securityGate?.toPersistedJson())'));
    expect(
        store, contains('optJSONObject("securityGate")?.toBleSecurityGate()'));
  });

  test('automatic exhaustion is a silent exact native terminal', () {
    expect(manager, contains('"securityRecoveryExhausted"'));
    expect(
        manager,
        contains(
            'autoReconnectSupervisor.cancel(uuid, reason = "securityRecoveryExhausted")'));
    expect(manager,
        contains('reconnectStore.removeTarget(weakContext?.get(), uuid)'));
    expect(manager, isNot(contains('removeBond(current.endpointId)')));
  });
}
