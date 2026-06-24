import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('example reconnects cached iOS device when BLE becomes available', () {
    final mainSource = File('example/lib/main.dart').readAsStringSync();
    final connectionSource =
        File('example/lib/src/g2_demo_connection.dart').readAsStringSync();

    expect(mainSource, contains('BleState _latestBleState'));
    expect(mainSource, contains('bool _configsReady'));
    expect(mainSource, contains('bool _bleAvailableRecoveryRunning'));
    expect(mainSource, contains('forceRestartConnecting: wasBleUnavailable'));
    expect(mainSource, contains("'bleState available'"));
    expect(mainSource, contains("'initConfigs available'"));

    expect(connectionSource, contains('Future<void> _handleBleAvailable'));
    expect(
      connectionSource,
      contains('_restoreLastDevice(reason: reason, logMissing: true)'),
    );
    expect(
      connectionSource,
      contains('BLE available recovery: reconnect selected'),
    );
    expect(
      connectionSource,
      contains('BLE available recovery restart: reason='),
    );
    expect(
      connectionSource,
      contains('preserveKnownConnectStates: true'),
    );
  });
}
