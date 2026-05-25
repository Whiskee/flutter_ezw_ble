import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('iOS scan-then-connect paths are guarded by a timeout', () {
    final source = File('ios/Classes/ble/BleManager.swift').readAsStringSync();

    expect(source, contains('scanConnectTimeoutTimers'));
    expect(source, contains('startScanConnectTimeout'));
    expect(source, contains('cancelScanConnectTimeout'));

    expect(
      source,
      contains('state: .noDeviceFound, tag: "scan connect timeout"'),
    );

    expect(
      source,
      contains('tag += "no local device found, start scan device"'),
    );
    expect(
      source,
      contains('let cachedServiceUUIDs = bleConfig.privateServices.map { \$0.serviceUUID }'),
    );
    expect(
      source,
      contains('let systemConnected = oldPeripheral?.state == .connected'),
    );
    expect(
      source,
      contains('cached device is system-connected (ANCS), skip scan, connect directly'),
    );
    expect(
      source,
      contains(
        'startScanConnectTimeout(currentConfig: bleConfig, uuid: newEasyConnect.uuid, name: newEasyConnect.name, afterUpgrade: easyConnect.afterUpgrade)',
      ),
    );
    expect(
      source,
      contains(
        'tag += ", target not visible in current scan, start scan device"',
      ),
    );
    expect(
      source,
      contains('state: .noDeviceFound, tag: "scan timestamp fallback"'),
    );
    expect(source, isNot(contains('peripheral.name!')));
    expect(source, contains('afterUpgrade: afterUpgrade, isAuthGrace: true'));
    expect(source, contains('cancelScanConnectTimeout(uuid: connectDevice.uuid, name: connectDevice.name)'));
    expect(source, contains('scanConnectTimeoutTimers.forEach'));
    expect(source, contains('connectingTimeoutTimers.forEach'));
  });
}
