import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'iOS Code=14 waits for a fresh advertisement instead of retrying a stale peripheral',
    () {
      final manager = File(
        'ios/Classes/ble/BleManager.swift',
      ).readAsStringSync();
      final reconnect = File(
        'ios/Classes/ble/BleAutoReconnectCoordinator.swift',
      ).readAsStringSync();
      final scan = File(
        'ios/Classes/ble/BleScanPipeline.swift',
      ).readAsStringSync();
      final connect = File(
        'ios/Classes/ble/BleConnectCoordinator.swift',
      ).readAsStringSync();

      expect(manager, contains('peerPairingRecoveryRequests'));
      expect(manager, contains('startPeerPairingResetRecovery'));
      expect(manager, contains('wait fresh advertisement before recovery'));
      expect(manager, contains('connectedDevices.removeAll { cached in'));
      expect(manager, contains('if error.code == 14, hasAutoReconnectTask'));
      expect(manager, contains('start fresh-advertisement recovery'));
      expect(
        reconnect,
        contains(
          'defer passive reconnect until fresh advertisement after pairing reset',
        ),
      );
      expect(scan, contains('finishPeerPairingResetRecovery'));
      expect(connect, contains('prepareExplicitConnectAfterPeerPairingRecovery'));
      expect(manager, contains('仅在 pairing-recovery gate 内'));

      final recoveryGateIndex = manager.indexOf(
        'peerPairingRecoveryRequests[reconnectKey(uuid: uuid)] = request',
      );
      final disconnectIndex = manager.indexOf(
        'handleConnectState(uuid: uuid, name: name, state: .disconnectFromSys',
      );
      final evictIndex = manager.indexOf('connectedDevices.removeAll { cached in');
      final scanIndex = manager.indexOf('startScan()', evictIndex);
      expect(recoveryGateIndex, greaterThanOrEqualTo(0));
      expect(disconnectIndex, greaterThan(recoveryGateIndex));
      expect(evictIndex, greaterThan(disconnectIndex));
      expect(scanIndex, greaterThan(evictIndex));
    },
  );
}
