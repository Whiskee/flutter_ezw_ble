import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Android connection callback uses HCI status semantics', () {
    final callbackSource = File(
      'android/src/main/kotlin/com/fzfstudio/ezw_ble/ble/BleGattSessionCallback.kt',
    ).readAsStringSync();
    final statusSource = File(
      'android/src/main/kotlin/com/fzfstudio/ezw_ble/ble/models/BluetoothGattStatus.kt',
    ).readAsStringSync();

    final connectionStart =
        callbackSource.indexOf('override fun onConnectionStateChange');
    final servicesStart =
        callbackSource.indexOf('override fun onServicesDiscovered');
    final connectionCallback =
        callbackSource.substring(connectionStart, servicesStart);

    expect(statusSource, contains('HCI_CONNECTION_TIMEOUT'));
    expect(statusSource, contains('GATT_INSUFFICIENT_AUTHORIZATION'));
    expect(
      connectionCallback,
      contains('getConnectionStatusDescription(status)'),
    );
    expect(
      connectionCallback,
      isNot(contains('recoverInsufficientAuthorization')),
    );
    expect(connectionCallback, isNot(contains('refreshDeviceCache')));
    expect(connectionCallback, isNot(contains('needsScanBeforeConnect')));
    expect(
      connectionCallback,
      isNot(contains('BluetoothGatt.GATT_INSUFFICIENT_AUTHORIZATION')),
    );
  });

  test('Android GATT operation callbacks keep authorization status semantics',
      () {
    final callbackSource = File(
      'android/src/main/kotlin/com/fzfstudio/ezw_ble/ble/BleGattSessionCallback.kt',
    ).readAsStringSync();

    final descriptorStart =
        callbackSource.indexOf('override fun onDescriptorWrite');
    final characteristicStart =
        callbackSource.indexOf('override fun onCharacteristicWrite');
    final mtuStart = callbackSource.indexOf('override fun onMtuChanged');
    final descriptorCallback =
        callbackSource.substring(descriptorStart, characteristicStart);
    final characteristicCallback =
        callbackSource.substring(characteristicStart, mtuStart);

    expect(
      descriptorCallback,
      contains('getGattOperationStatusDescription(status)'),
    );
    expect(
      descriptorCallback,
      contains('status == BluetoothGattStatus.GATT_INSUFFICIENT_AUTHORIZATION'),
    );
    expect(
      descriptorCallback,
      contains('recoverInsufficientAuthorization(gatt, device)'),
    );
    expect(
      descriptorCallback,
      contains(
          'terminateSession(gatt, BleConnectState.CHARS_FAIL, DEFAULT_MTU)'),
    );
    expect(
      descriptorCallback,
      contains(r'status=$operationStatus'),
    );
    expect(
      characteristicCallback,
      contains('getGattOperationStatusDescription(status)'),
    );
    expect(
      characteristicCallback,
      contains('status == BluetoothGattStatus.GATT_INSUFFICIENT_AUTHORIZATION'),
    );
    expect(
      characteristicCallback,
      contains('recoverInsufficientAuthorization(gatt, device)'),
    );
    expect(
      characteristicCallback,
      contains(
        'terminateSession(gatt, BleConnectState.DISCONNECT_FROM_SYS, DEFAULT_MTU)',
      ),
    );
    expect(
      callbackSource,
      contains('onSessionTerminal(gatt, state, mtu)'),
    );
    final authorizationBranchStart = characteristicCallback.indexOf(
      'if (status == BluetoothGattStatus.GATT_INSUFFICIENT_AUTHORIZATION)',
    );
    final authorizationBranchEnd = characteristicCallback.indexOf(
      '\n        // 4.',
      authorizationBranchStart,
    );
    expect(authorizationBranchStart, isNonNegative);
    expect(authorizationBranchEnd, greaterThan(authorizationBranchStart));
    final authorizationBranch = characteristicCallback.substring(
      authorizationBranchStart,
      authorizationBranchEnd,
    );
    expect(
      authorizationBranch,
      isNot(contains('onCharacteristicWriteComplete')),
    );
    expect(
      characteristicCallback,
      contains(r'status=$operationStatus'),
    );
  });
}
