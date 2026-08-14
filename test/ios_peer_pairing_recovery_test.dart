import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('iOS automatic Code 14 keeps owner across fresh advertisement windows',
      () {
    final manager = File('ios/Classes/ble/BleManager.swift').readAsStringSync();
    final reconnect = File('ios/Classes/ble/BleAutoReconnectCoordinator.swift')
        .readAsStringSync();
    final scan =
        File('ios/Classes/ble/BleScanPipeline.swift').readAsStringSync();
    final store =
        File('ios/Classes/ble/BleReconnectStore.swift').readAsStringSync();

    expect(manager, contains('registerPeerPairingFailure('));
    expect(manager, contains('nsError?.code == 14, hasAutoReconnectTask'));
    expect(store, contains('enum BlePeerPairingRecoveryState'));
    expect(store, contains('case awaitingFreshAdvertisement'));
    expect(store, contains('case waitingFreshAdvertisementRetry'));
    expect(store, contains('case foregroundRecoveryConnecting'));
    expect(store, contains('enum BlePeerPairingFailureAction'));
    expect(store, contains('case retryFreshAdvertisement'));
    expect(store, contains('case stopAttempt'));
    expect(reconnect, contains('automaticPairingRecoveryScanWindow'));
    expect(reconnect, contains('pairingRecoveryRetryDelay'));
    expect(store, contains('source == .manualReconnect ? 20 : 10'));
    expect(store, contains('static let retryDelay: TimeInterval = 5'));
    expect(
        reconnect,
        contains(
            'current.pairingRecoveryState = .waitingFreshAdvertisementRetry'));
    expect(reconnect, contains('schedulePairingRecoveryRetry'));
    expect(reconnect, contains('freshAdvertisementWindowMissed'));
    expect(reconnect, contains('freshAdvertisementRetryScheduled'));
    expect(
      reconnect,
      isNot(contains(
          'stopPeerPairingRecoveryTask(current, reason: "freshAdvertisementTimeout")')),
    );
    expect(reconnect, contains('reason: "peerPairingRecoveryStopped"'));
    expect(reconnect, contains('reason: "freshPairingRecoveryStarted"'));
    expect(reconnect, contains('advertisedMac: String'));
    expect(reconnect, contains('expectedMacSuffix'));
    expect(
      reconnect,
      contains('expectedMacSuffix: target.expectedMacSuffix'),
    );
    expect(
      store,
      contains('"expectedMacSuffix": expectedMacSuffix'),
    );
    expect(reconnect, contains('cancelPairingRecoveryDiscovery(key: key)'));
    expect(reconnect, contains('pausePeerPairingRecoveryForAppInactivity'));
    expect(reconnect, contains('pausePeerPairingRecoveryForBluetoothOff'));
    expect(scan, contains('resumePeerPairingRecoveryIfMatched('));
    expect(reconnect, isNot(contains('waitingUserRepair')));
    expect(reconnect, isNot(contains('rearmAutoReconnectAfterUserRepair')));
  });

  test('manual or repeated Code 14 stops the attempt and maps actual failure',
      () {
    final reconnect = File('ios/Classes/ble/BleAutoReconnectCoordinator.swift')
        .readAsStringSync();
    final manager = File('ios/Classes/ble/BleManager.swift').readAsStringSync();

    expect(
        reconnect,
        contains(
            'source == .manualReconnect || task.hasAttemptedPairingRecovery'));
    expect(reconnect, contains('return .stopAttempt'));
    expect(reconnect, contains('freshPeripheralStillRejectedPairing'));
    expect(reconnect, contains('stoppedPeerPairingRecoveryKeys.insert'));
    expect(reconnect, contains('cancelPairingRecoveryDiscovery'));
    expect(
      manager,
      contains('registerPeerPairingFailure('),
    );
    expect(
      manager,
      contains(
          'let stoppedForPairingFailure = pairingFailureAction == .stopAttempt'),
    );
    expect(
      manager,
      contains('? .alreadyBound\n                : .disconnectFromSys'),
    );
    expect(reconnect, isNot(contains('waitingUserRepair')));
    expect(manager, isNot(contains('needsManualRepair')));
  });

  test(
      'iOS manual activation promotes a healthy pending admission without reconnecting',
      () {
    final reconnect = File('ios/Classes/ble/BleAutoReconnectCoordinator.swift')
        .readAsStringSync();
    final activationStart = reconnect.indexOf(
      'private func activateArmedReconnectTask',
    );
    final activationEnd = reconnect.indexOf(
      '/// 扫描仅为已声明的 name-only owner',
      activationStart,
    );
    final activation = reconnect.substring(activationStart, activationEnd);

    expect(activation, contains('if source == .manualReconnect'));
    expect(activation, contains('replaceStalePendingManualAttemptIfNeeded'));
    expect(activation, contains('_ = promotePendingAttempt(uuid: task.uuid)'));
    expect(activation, contains('return'));
    expect(activation, isNot(contains('cancelPeripheral(')));
  });

  test('manual takeover of automatic pairing recovery never mutates active source',
      () {
    final reconnect = File('ios/Classes/ble/BleAutoReconnectCoordinator.swift')
        .readAsStringSync();

    expect(reconnect, contains('takeOverPeerPairingRecoveryManually'));
    expect(reconnect, contains('current.source != .manualReconnect'));
    expect(
      reconnect,
      contains('deferConnectionAdmissionReleaseUntilPeripheralTerminal'),
    );
    expect(reconnect, contains('centralManager.cancelPeripheralConnection'));
  });

  test('non Code 14 terminal exits specialized recovery before normal reconnect',
      () {
    final reconnect = File('ios/Classes/ble/BleAutoReconnectCoordinator.swift')
        .readAsStringSync();
    final manager = File('ios/Classes/ble/BleManager.swift').readAsStringSync();

    expect(reconnect, contains('resetPeerPairingRecoveryAfterNonPairingFailure'));
    expect(manager, contains('nsError?.code != 14'));
    expect(manager, contains('error.code != 14'));
  });
}
