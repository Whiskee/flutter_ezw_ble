import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _sourceBetween(String source, String startMarker, String endMarker) {
  final start = source.indexOf(startMarker);
  expect(start, isNonNegative, reason: 'missing start marker: $startMarker');
  final end = source.indexOf(endMarker, start);
  expect(end, isNonNegative, reason: 'missing end marker: $endMarker');
  return source.substring(start, end);
}

void main() {
  final reconnectSource = File(
    'ios/Classes/ble/BleAutoReconnectCoordinator.swift',
  ).readAsStringSync();
  final reconnectStore = File(
    'ios/Classes/ble/BleReconnectStore.swift',
  ).readAsStringSync();
  final manager = File('ios/Classes/ble/BleManager.swift').readAsStringSync();
  final methodChannel =
      File('ios/Classes/ble/BleMethodChannel.swift').readAsStringSync();

  test('iOS Bluetooth ON waits for one explicit final recovery activation', () {
    final resume = _sourceBetween(
      reconnectSource,
      'func resumeReconnectTasksAfterBluetoothOn()',
      '    /**\n     *  如果蓝牙已开启，则尝试恢复暂停任务。',
    );

    expect(reconnectStore, contains('var awaitingRecoveryActivation: Bool'));
    expect(resume, contains('awaitingRecoveryActivation = true'));
    expect(resume, isNot(contains('scheduleReconnect(')));
    expect(resume, isNot(contains('beginReconnectAttempt(')));
    expect(resume, isNot(contains('connectPeripheral')));
    expect(resume, isNot(contains('cancelPeripheralConnection')));
    expect(resume, isNot(contains('beginPeripheralCancellationBarrier')));
  });

  test('implicit iOS reconnect scheduling cannot consume reset recovery gate',
      () {
    final schedule = _sourceBetween(
      reconnectSource,
      'func scheduleReconnect(',
      '    /**\n     *  计算下一次尝试序号。',
    );
    final begin = _sourceBetween(
      reconnectSource,
      'func beginReconnectAttempt(uuid: String)',
      '    func otaReconnectSchedulingAdmission(',
    );

    expect(schedule, contains('task.awaitingRecoveryActivation'));
    expect(begin, contains('task.awaitingRecoveryActivation'));
  });

  test('only explicit activation consumes gate with a newer positive session',
      () {
    expect(
      reconnectSource,
      contains('consumeRecoveryActivationGate('),
    );
    final consume = _sourceBetween(
      reconnectSource,
      'func consumeRecoveryActivationGate(',
      '    /// Code 14',
    );

    expect(
      reconnectStore,
      contains('incomingSessionGeneration > 0'),
    );
    expect(
      reconnectStore,
      contains('incomingSessionGeneration > currentSessionGeneration'),
    );
    expect(
      reconnectStore,
      contains('incomingRecoveryEpoch == currentRecoveryEpoch'),
    );
    expect(consume, contains('BleRecoveryActivationGatePolicy.evaluate('));
    expect(consume, contains('current.awaitingRecoveryActivation = false'));
    expect(consume, contains('current.pausedByBluetoothOff = false'));
  });

  test('arm-only and lifecycle compensation preserve recovery activation gate',
      () {
    final arm = _sourceBetween(
      reconnectSource,
      'func armReconnectTarget(',
      '    /// 显式 activation 原子消费 transport reset 门禁',
    );
    final lifecycleResume = _sourceBetween(
      reconnectSource,
      'private func resumeAppInactiveDeferredReconnects()',
      '    /// App 不再 active',
    );

    expect(arm, isNot(contains('awaitingRecoveryActivation = false')));
    expect(
      lifecycleResume,
      isNot(contains('consumeRecoveryActivationGate(')),
    );
  });

  test('stale recovery activation is rejected before owner mutation', () {
    final activation = _sourceBetween(
      reconnectSource,
      'func activateAutoReconnectTargets(',
      '    /**\n     *  普通前台冷启动对缺失 peripheral',
    );

    expect(activation, contains('canMutateForRecoveryActivation('));
    expect(
      activation.indexOf('canMutateForRecoveryActivation('),
      lessThan(activation.indexOf('clearStoppedPeerPairingRecovery(')),
    );
    expect(
      activation.indexOf('canMutateForRecoveryActivation('),
      lessThan(activation.indexOf('armReconnectTarget(')),
    );
  });

  test('continuous reset cycles use an exact native recovery epoch', () {
    expect(manager, contains('currentTransportRecoveryEpoch + 1'));
    expect(
      reconnectSource,
      contains('task.recoveryEpoch = recoveryEpoch'),
    );
    expect(manager, contains('func beginTransportRecoveryCycleIfNeeded()'));
    expect(
      reconnectSource,
      contains('task.recoveryEpoch = beginTransportRecoveryCycleIfNeeded()'),
    );
    expect(methodChannel, contains('case .bleRecoveryEpoch:'));
    expect(methodChannel, contains('data["recoveryEpoch"]'));
    expect(
      reconnectSource,
      contains('incomingRecoveryEpoch: recoveryEpoch'),
    );
  });

  test('Code 14 advertisement cannot mutate an awaiting reset owner', () {
    final freshAdvertisement = _sourceBetween(
      reconnectSource,
      'func resumePeerPairingRecoveryIfMatched(',
      '    /**\n     * 接管 CoreBluetooth 已自动建立的 reconnect owner。',
    );
    expect(
      freshAdvertisement,
      contains('!task.awaitingRecoveryActivation'),
    );
    final systemReconnect = _sourceBetween(
      reconnectSource,
      'func adoptSystemAutoReconnect(',
      '    /// 同名辅助扫描命中新 UUID',
    );
    expect(
      systemReconnect,
      contains('!task.awaitingRecoveryActivation'),
    );
  });
}
