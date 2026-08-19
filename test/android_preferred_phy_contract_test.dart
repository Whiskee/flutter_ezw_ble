import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Android requests LE 2M PHY after GATT ready and OTA enter', () {
    final helper = File(
      'android/src/main/kotlin/com/fzfstudio/ezw_ble/ble/BleAndroidPreferredPhy.kt',
    ).readAsStringSync();
    final callback = File(
      'android/src/main/kotlin/com/fzfstudio/ezw_ble/ble/BleGattSessionCallback.kt',
    ).readAsStringSync();
    final manager = File(
      'android/src/main/kotlin/com/fzfstudio/ezw_ble/ble/BleManager.kt',
    ).readAsStringSync();
    final ios = File('ios/Classes/ble/BleManager.swift').readAsStringSync();

    expect(helper, contains('BluetoothDevice.PHY_LE_2M'));
    expect(helper, contains('setPreferredPhy'));
    expect(helper, contains('readPhy()'));
    expect(callback, contains('reason = "connectFinish"'));
    expect(callback, contains('override fun onPhyUpdate'));
    expect(callback, contains('override fun onPhyRead'));
    expect(helper, contains('isLe2MPhySupported'));
    expect(manager, contains('reason = "enterUpgradeState"'));
    expect(manager, contains('logAdapterCapability'));
    expect(ios, contains('logLe2mPhyUnavailable'));
    expect(ios, isNot(contains('setPreferredPHY(')));
  });
}
