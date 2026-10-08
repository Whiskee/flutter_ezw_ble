import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('native frozen identity continues validated ordinary scan delivery',
      () async {
    final directory = await Directory.systemTemp.createTemp('ble-scan-test-');
    addTearDown(() => directory.delete(recursive: true));
    for (final stub in {
      'CoreBluetooth': 'test/native/scan_core_bluetooth_stub.swift',
      'flutter_ezw_utils': 'test/native/scan_utils_stub.swift',
    }.entries) {
      final compile = await Process.run('swiftc', [
        '-parse-as-library',
        '-emit-module',
        '-emit-object',
        '-module-name',
        stub.key,
        '-emit-module-path',
        '${directory.path}/${stub.key}.swiftmodule',
        stub.value,
        '-o',
        '${directory.path}/${stub.key}.o',
      ]);
      expect(compile.exitCode, 0,
          reason: '${compile.stdout}\n${compile.stderr}');
    }
    final executable = '${directory.path}/scan-test';
    final compile = await Process.run('swiftc', [
      '-I',
      directory.path,
      '${directory.path}/CoreBluetooth.o',
      '${directory.path}/flutter_ezw_utils.o',
      'ios/Classes/ble/BleScanPipeline.swift',
      'ios/Classes/ble/BlePendingReconnectIdentity.swift',
      'ios/Classes/ble/BleRecoveryActivationGate.swift',
      'ios/Classes/ble/models/BleDevice.swift',
      'ios/Classes/ble/models/BleScan.swift',
      'ios/Classes/ble/models/BleMacRule.swift',
      'ios/Classes/ble/models/BleSnRule.swift',
      'ios/Classes/ble/models/BleMatchDevice.swift',
      'test/native/scan_manager_fixture.swift',
      'test/native/pending_identity_scan_test.swift',
      '-o',
      executable,
    ]);
    expect(compile.exitCode, 0, reason: '${compile.stdout}\n${compile.stderr}');
    final run = await Process.run(executable, const []);
    // Emit the real regression result as well as asserting it, so the red/green
    // artifact distinguishes behavioral failure from a compilation failure.
    stdout.write(run.stdout);
    stderr.write(run.stderr);
    expect(run.exitCode, 0, reason: '${run.stdout}\n${run.stderr}');
    expect(run.stdout,
        contains('production scan/resolver preserves frozen owner'));
  }, skip: !Platform.isMacOS);
}
