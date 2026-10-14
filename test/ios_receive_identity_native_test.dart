import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('native receive identity policy freezes exact notify provenance',
      () async {
    final directory = await Directory.systemTemp.createTemp('ble-receive-id-');
    addTearDown(() => directory.delete(recursive: true));
    final executable = '${directory.path}/receive-identity-test';
    final compile = await Process.run('swiftc', [
      'ios/Classes/ble/BleReceiveIdentityPolicy.swift',
      'ios/Classes/ble/models/BleCmd.swift',
      'test/native/receive_identity_policy_test.swift',
      '-o',
      executable,
    ]);
    expect(compile.exitCode, 0, reason: '${compile.stdout}\n${compile.stderr}');
    final run = await Process.run(executable, const []);
    stdout.write(run.stdout);
    stderr.write(run.stderr);
    expect(run.exitCode, 0, reason: '${run.stdout}\n${run.stderr}');
    expect(
      run.stdout,
      contains('freezes exact notify provenance and fails closed'),
    );
  }, skip: !Platform.isMacOS);
}
