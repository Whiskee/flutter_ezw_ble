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

  test('iOS preserves CDM and PI attempts as automatic reconnect sources', () {
    final model = File('ios/Classes/ble/models/BleConnect.swift')
        .readAsStringSync();
    final flow = File('ios/Classes/ble/BleConnectionAdmissionFlow.swift')
        .readAsStringSync();

    expect(model, contains('case androidCdm'));
    expect(model, contains('case androidBlePendingIntent'));
    expect(model, contains('var isAutomaticReconnect: Bool'));
    expect(flow, contains('admission.source.isAutomaticReconnect'));
  });
}
