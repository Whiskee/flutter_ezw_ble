import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('native connection-event owner priority and escrow terminal policy',
      () async {
    final directory = await Directory.systemTemp.createTemp('ble-owner-test-');
    addTearDown(() => directory.delete(recursive: true));
    final stub = await Process.run('swiftc', [
      '-parse-as-library',
      '-emit-module',
      '-emit-object',
      '-module-name',
      'CoreBluetooth',
      '-emit-module-path',
      '${directory.path}/CoreBluetooth.swiftmodule',
      'test/native/scan_core_bluetooth_stub.swift',
      '-o',
      '${directory.path}/CoreBluetooth.o',
    ]);
    expect(stub.exitCode, 0, reason: '${stub.stdout}\n${stub.stderr}');
    // Execute the real terminal flow as well as the coordinator policy. Only
    // CoreBluetooth cancel/rearm/log boundaries below are test adapters.
    final flowSource = File('ios/Classes/ble/BleStateRestorationFlow.swift')
        .readAsStringSync();
    final flowStart =
        flowSource.indexOf('func handleStateRestorationEscrowTerminal(');
    var flowEnd = flowSource.indexOf('{', flowStart);
    var flowDepth = 0;
    do {
      if (flowSource[flowEnd] == '{') flowDepth++;
      if (flowSource[flowEnd] == '}') flowDepth--;
      flowEnd++;
    } while (flowDepth > 0);
    final flowFile = File('${directory.path}/escrow-flow.swift');
    await flowFile.writeAsString(
        'import CoreBluetooth\nimport Foundation\nextension EscrowManagerFixture {\n${flowSource.substring(flowStart, flowEnd)}\n}');
    final executable = '${directory.path}/owner-test';
    final compile = await Process.run('swiftc', [
      '-I',
      directory.path,
      '${directory.path}/CoreBluetooth.o',
      flowFile.path,
      'ios/Classes/ble/BleConnectionEventOwnershipPolicy.swift',
      'ios/Classes/ble/BleNativeConnectionTrace.swift',
      'ios/Classes/ble/models/BleConnect.swift',
      'ios/Classes/ble/models/BleConfig.swift',
      'ios/Classes/ble/models/BleMacRule.swift',
      'ios/Classes/ble/models/BlePrivateService.swift',
      'ios/Classes/ble/models/BleScan.swift',
      'ios/Classes/ble/models/BleSecurityGate.swift',
      'ios/Classes/ble/models/BleSnRule.swift',
      'ios/Classes/ble/BleConnectionAdmissionGate.swift',
      'ios/Classes/ble/BleReconnectFailurePolicy.swift',
      'ios/Classes/ble/BleStateRestorationCoordinator.swift',
      'test/native/connection_event_owner_policy_test.swift',
      '-o',
      executable,
    ]);
    expect(compile.exitCode, 0, reason: '${compile.stdout}\n${compile.stderr}');
    final run = await Process.run(executable, const []);
    stdout.write(run.stdout);
    stderr.write(run.stderr);
    expect(run.exitCode, 0, reason: '${run.stdout}\n${run.stderr}');
    expect(run.stdout, contains('connection-event owner priority'));
  }, skip: !Platform.isMacOS);
}
