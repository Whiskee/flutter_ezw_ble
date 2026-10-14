import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('native business invalidation policy is fail-closed', () async {
    final directory = await Directory.systemTemp.createTemp('ble-invalidate-');
    addTearDown(() => directory.delete(recursive: true));
    final executable = '${directory.path}/business-invalidation-test';
    final compile = await Process.run('swiftc', [
      'ios/Classes/ble/BleNativeConnectionTrace.swift',
      'ios/Classes/ble/models/BleConnect.swift',
      'ios/Classes/ble/models/BleConfig.swift',
      'ios/Classes/ble/models/BleMacRule.swift',
      'ios/Classes/ble/models/BlePrivateService.swift',
      'ios/Classes/ble/models/BleScan.swift',
      'ios/Classes/ble/models/BleSecurityGate.swift',
      'ios/Classes/ble/models/BleSnRule.swift',
      'ios/Classes/ble/BleConnectionAdmissionGate.swift',
      'ios/Classes/ble/BleBusinessConnectionAttempt.swift',
      'test/native/business_connection_invalidation_policy_test.swift',
      '-o',
      executable,
    ]);
    expect(compile.exitCode, 0, reason: '${compile.stdout}\n${compile.stderr}');
    final run = await Process.run(executable, const []);
    stdout.write(run.stdout);
    stderr.write(run.stderr);
    expect(run.exitCode, 0, reason: '${run.stdout}\n${run.stderr}');
    expect(run.stdout, contains('accepts only current committed owners'));
  }, skip: !Platform.isMacOS);
}
