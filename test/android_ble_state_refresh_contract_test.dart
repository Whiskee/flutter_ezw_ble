import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final managerSource = File(
    'android/src/main/kotlin/com/fzfstudio/ezw_ble/ble/BleManager.kt',
  ).readAsStringSync();
  final pluginSource = File(
    'android/src/main/kotlin/com/fzfstudio/ezw_ble/FlutterEzwBlePlugin.kt',
  ).readAsStringSync();
  final channelSource = File(
    'android/src/main/kotlin/com/fzfstudio/ezw_ble/ble/BleMethodChannel.kt',
  ).readAsStringSync();

  test('BLE state query and Activity resume refresh live permissions', () {
    expect(
      channelSource,
      contains('refreshBleState("methodChannel.bleState")'),
    );
    expect(pluginSource, contains('refreshBleState("activityStarted")'));
    expect(pluginSource, contains('refreshBleState("activityResumed")'));
    expect(managerSource, contains('if (refreshedState != previousState)'));
  });

  test('scan starts only after live state and a successful system call', () {
    final start = managerSource.indexOf('fun startScan(');
    final stop = managerSource.indexOf('fun stopScan(', start);
    final source = managerSource.substring(start, stop);

    expect(source, contains('refreshBleState("startScan")'));
    expect(source, contains('if (scanner == null)'));
    expect(
      source.indexOf('scanner.startScan(null, scanSettings, callback)'),
      lessThan(source.indexOf('isScanning = true')),
    );
    expect(
      source.indexOf('isScanning = true'),
      lessThan(source.indexOf('Start scan: success')),
    );
    expect(source, contains('catch (error: Exception)'));
    expect(source, contains('clearLocalScanState()'));
  });

  test('stop scan always releases local state after permission revocation', () {
    final stop = managerSource.indexOf('fun stopScan(');
    final clear = managerSource.indexOf(
      'private fun clearLocalScanState()',
      stop,
    );
    final source = managerSource.substring(stop, clear);

    expect(source, contains('finally'));
    expect(source, contains('clearLocalScanState()'));
    expect(source, isNot(contains('checkIsFunctionCanBeCalled()')));
  });
}
