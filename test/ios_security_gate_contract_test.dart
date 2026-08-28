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
    final gateServiceBranch = manager.indexOf(
      'securityGate.serviceUUID == service.uuid',
    );
    final gateStartBeforeOrdinary = manager.indexOf(
      'startSecurityGateIfNeeded(',
      gateServiceBranch,
    );
    final deferReturn = manager.indexOf('return', gateStartBeforeOrdinary);
    final ordinaryPrivateService = manager.indexOf(
      'guard let privateService',
      gateServiceBranch,
    );
    expect(gateStart, isNonNegative);
    expect(protectedWrite, greaterThan(gateStart));
    expect(
      gateStartBeforeOrdinary,
      lessThan(ordinaryPrivateService),
      reason:
          '5403 gate must run before ordinary business characteristic setup',
    );
    expect(
      deferReturn,
      lessThan(ordinaryPrivateService),
      reason: 'ordinary Notify setup must stay deferred while 5403 is pending',
    );
    expect(connectFinish, greaterThan(protectedWrite));
    expect(
      manager,
      contains('didWriteValueFor characteristic: CBCharacteristic'),
    );
    expect(manager, contains('state: .boundFail'));
    expect(manager, contains('state: .securityRecoveryExhausted'));
    expect(manager, contains('registerSecurityGateFailure('));
    expect(
      manager,
      contains('characteristic missing, use legacy AUTH fallback'),
    );
    expect(
      manager,
      contains('the caller must not also process the same service'),
    );
    final missingStart = manager.indexOf(
      'characteristic missing, use legacy AUTH fallback',
    );
    final missingEnd = manager.indexOf(
      'guard let admission = currentConnectionAdmission',
      missingStart,
    );
    final missingBlock = manager.substring(missingStart, missingEnd);
    expect(missingBlock, contains('legacy gate fallback'));
    expect(
      missingBlock,
      contains('return true'),
      reason:
          'missing 5403 fallback owns ordinary discovery to avoid duplicate notify',
    );

    expect(registry, contains('lhs.sessionId == rhs.sessionId'));
    expect(registry, contains('lhs.generation == rhs.generation'));
    expect(
      registry,
      contains('lhs.sessionGeneration == rhs.sessionGeneration'),
    );
    expect(registry, isNot(contains('asyncAfter')));
  });

  test('unsupported iOS security gate write falls back without exhausting', () {
    final manager = File('ios/Classes/ble/BleManager.swift').readAsStringSync();
    final unsupportedStart = manager.indexOf(
      'characteristic does not support write with response',
    );
    final unsupportedEnd = manager.indexOf(
      'securityGateAttempts.start(',
      unsupportedStart,
    );
    final unsupportedBlock =
        manager.substring(unsupportedStart, unsupportedEnd);

    expect(unsupportedBlock, contains('not a real CBATT security failure'));
    expect(unsupportedBlock, contains('unsupported gate fallback'));
    expect(unsupportedBlock, contains('device.securityGateWriteChar = nil'));
    expect(
      unsupportedBlock,
      isNot(contains('securityRecoveryExhausted')),
    );
    expect(
      unsupportedBlock,
      isNot(contains('registerSecurityGateFailure')),
    );
  });
}
