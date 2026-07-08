import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('iOS dispatches system-connected peripheral probe', () {
    final source =
        File('ios/Classes/ble/BleMethodChannel.swift').readAsStringSync();

    expect(source, contains('case isSystemConnectedPeripheral'));
    expect(source, contains('case .isSystemConnectedPeripheral:'));
    expect(source, contains('BleManager.shared.isSystemConnectedPeripheral('));
  });
}
