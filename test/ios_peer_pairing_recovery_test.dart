import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
      'iOS Code 14 keeps autoReconnect but rebuilds from a fresh advertisement',
      () {
    final manager = File('ios/Classes/ble/BleManager.swift').readAsStringSync();
    final reconnect = File('ios/Classes/ble/BleAutoReconnectCoordinator.swift')
        .readAsStringSync();
    final scan =
        File('ios/Classes/ble/BleScanPipeline.swift').readAsStringSync();
    final store =
        File('ios/Classes/ble/BleReconnectStore.swift').readAsStringSync();

    expect(manager, contains('preparePeerPairingRecovery('));
    expect(manager, contains('nsError?.code == 14, hasAutoReconnectTask'));
    expect(store, contains('requiresFreshAdvertisement'));
    expect(store, contains('requiresForegroundPairingRecovery'));
    expect(reconnect,
        contains('pairingRecoveryDiscoveryTimeout: TimeInterval { 20.0 }'));
    expect(
        reconnect,
        contains(
            'peer pairing recovery scan timed out; resume system pending connect'));
    expect(reconnect, contains('let usesSystemAutoReconnect'));
    expect(scan, contains('resumePeerPairingRecoveryIfMatched('));
  });
}
