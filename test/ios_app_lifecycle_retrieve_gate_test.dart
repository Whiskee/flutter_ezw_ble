import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('iOS synchronous CoreBluetooth retrieval is active-only', () {
    final manager = File('ios/Classes/ble/BleManager.swift').readAsStringSync();
    final connect = File(
      'ios/Classes/ble/BleConnectCoordinator.swift',
    ).readAsStringSync();
    final reconnect = File(
      'ios/Classes/ble/BleAutoReconnectCoordinator.swift',
    ).readAsStringSync();

    expect(
      manager,
      contains('UIApplication.willResignActiveNotification'),
    );
    expect(manager, contains('UIApplication.didEnterBackgroundNotification'));
    expect(manager, contains('UIApplication.willTerminateNotification'));
    expect(manager, contains('allowsSynchronousCoreBluetoothLookup = false'));
    expect(reconnect, contains('allowsSynchronousCoreBluetoothLookup = true'));

    expect(
      manager,
      contains('func retrieveConnectedPeripheralsWhenAppActive('),
    );
    expect(manager, contains('func retrievePeripheralsWhenAppActive('));
    expect(
      manager,
      contains('guard allowsSynchronousCoreBluetoothLookup else'),
    );

    expect(
      connect,
      isNot(contains('centralManager.retrieveConnectedPeripherals(')),
    );
    expect(
      connect,
      isNot(contains('centralManager.retrievePeripherals(')),
    );
    expect(
      reconnect,
      isNot(contains('centralManager.retrieveConnectedPeripherals(')),
    );
    expect(
      reconnect,
      isNot(contains('centralManager.retrievePeripherals(')),
    );
  });

  test('inactive auto reconnect defers without manufacturing failure', () {
    final store = File(
      'ios/Classes/ble/BleReconnectStore.swift',
    ).readAsStringSync();
    final reconnect = File(
      'ios/Classes/ble/BleAutoReconnectCoordinator.swift',
    ).readAsStringSync();

    expect(store, contains('var deferredByAppInactivity: Bool = false'));
    expect(reconnect, contains('"appInactiveDeferred"'));
    expect(reconnect, contains('deferReconnectTaskForAppInactivity('));
    expect(reconnect, contains('resumeAppInactiveDeferredReconnects()'));
    expect(reconnect, contains('resolveAppInactivePendingIdentities()'));

    final directAttempt = reconnect.substring(
      reconnect.indexOf('func beginDirectReconnectAttempt'),
      reconnect.indexOf('func registerPeerPairingFailure'),
    );
    final inactiveGuard = directAttempt.indexOf(
      'guard allowsSynchronousCoreBluetoothLookup else',
    );
    final noDeviceFailure = directAttempt.indexOf('state: .noDeviceFound');
    expect(inactiveGuard, isNonNegative);
    expect(noDeviceFailure, greaterThan(inactiveGuard));
    expect(
      directAttempt.substring(inactiveGuard, noDeviceFailure),
      contains('deferReconnectTaskForAppInactivity('),
    );
  });

  test('foreground compensation keeps exact owner and generation checks', () {
    final reconnect = File(
      'ios/Classes/ble/BleAutoReconnectCoordinator.swift',
    ).readAsStringSync();

    final resumeStart = reconnect.indexOf(
      'func resolveAppInactivePendingIdentities()',
    );
    final resumeEnd = reconnect.indexOf(
      'func shouldScheduleReconnect',
      resumeStart,
    );
    expect(resumeStart, isNonNegative);
    expect(resumeEnd, greaterThan(resumeStart));
    final resume = reconnect.substring(resumeStart, resumeEnd);

    expect(resume, contains('current.deferredByAppInactivity'));
    expect(
      resume,
      contains('current.sessionGeneration == deferred.sessionGeneration'),
    );
    expect(resume, contains(r'$0.autoReconnect'));
    expect(resume, contains('pendingReconnectIdentities[pending.key]'));
    expect(
      resume,
      contains('currentPending.sessionGeneration == pending.sessionGeneration'),
    );
    expect(resume, contains('resolvePendingReconnectIdentity('));
  });
}
