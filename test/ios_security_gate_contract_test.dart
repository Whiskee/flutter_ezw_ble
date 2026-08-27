import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('iOS protected write gates connectFinish on the exact attempt', () {
    final manager = File('ios/Classes/ble/BleManager.swift').readAsStringSync();
    final registry = File(
      'ios/Classes/ble/BleSecurityGateAttemptRegistry.swift',
    ).readAsStringSync();

    final gateStart = manager.indexOf('securityGateAttempts.start(');
    final protectedWrite = manager.indexOf('type: .withResponse', gateStart);
    final connectFinish = manager.indexOf(
      'state: .connectFinish',
      protectedWrite,
    );
    expect(gateStart, isNonNegative);
    expect(protectedWrite, greaterThan(gateStart));
    expect(connectFinish, greaterThan(protectedWrite));
    expect(
      manager,
      contains('didWriteValueFor characteristic: CBCharacteristic'),
    );
    expect(manager, contains('state: .boundFail'));
    expect(
      manager,
      contains('characteristic missing, use legacy AUTH fallback'),
    );

    expect(registry, contains('lhs.sessionId == rhs.sessionId'));
    expect(registry, contains('lhs.generation == rhs.generation'));
    expect(
      registry,
      contains('lhs.sessionGeneration == rhs.sessionGeneration'),
    );
    expect(registry, isNot(contains('asyncAfter')));
  });
}
