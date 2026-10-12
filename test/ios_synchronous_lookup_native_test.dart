import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'native query executor and pending identity recovery behavior',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'ble-lookup-test-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final executable = '${directory.path}/lookup-test';
      final compile = await Process.run('swiftc', [
        'ios/Classes/ble/BleSynchronousCoreBluetoothLookup.swift',
        'ios/Classes/ble/BleRecoveryActivationGate.swift',
        'test/native/synchronous_lookup_test.swift',
        '-o',
        executable,
      ]);
      expect(
        compile.exitCode,
        0,
        reason: '${compile.stdout}\n${compile.stderr}',
      );
      final run = await Process.run(executable, const []);
      expect(run.exitCode, 0, reason: '${run.stdout}\n${run.stderr}');
      expect(run.stdout, contains('denied query closures untouched'));
      expect(run.stdout, contains('blocks implicit S1 recovery'));
    },
    skip: !Platform.isMacOS,
  );
}
