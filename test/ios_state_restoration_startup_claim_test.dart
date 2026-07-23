import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('startup reset preserves restoration debt for current-target claim', () {
    final manager = File('ios/Classes/ble/BleManager.swift').readAsStringSync();
    final method = File(
      'ios/Classes/ble/BleMethodChannel.swift',
    ).readAsStringSync();
    final coordinator = File(
      'ios/Classes/ble/BleStateRestorationCoordinator.swift',
    ).readAsStringSync();

    expect(
      manager,
      contains('func reset(preserveStateRestoration: Bool = false)'),
    );
    expect(
      manager,
      contains('if !preserveStateRestoration'),
      reason: 'hard reset 必须清理 restoration，startup reset 必须保留',
    );
    expect(
      method,
      contains('data["preserveStateRestoration"] as? Bool ?? false'),
    );
    expect(coordinator, contains('func claimPendingPeripheral('));
    expect(coordinator, contains('guard matches.count == 1'));
    expect(
      coordinator,
      contains('pendingPeripherals.remove(at: match.offset)'),
    );
    final flow = File(
      'ios/Classes/ble/BleStateRestorationFlow.swift',
    ).readAsStringSync();
    expect(flow, contains('func finalizeStateRestorationClaims()'));
    expect(flow, contains('drainPendingPeripherals()'));
    expect(flow,
        contains('centralManager.cancelPeripheralConnection(peripheral)'));
  });

  test(
    'name-only activation claims restoration before identityPending scan',
    () {
      final manager = File(
        'ios/Classes/ble/BleManager.swift',
      ).readAsStringSync();
      final reconnect = File(
        'ios/Classes/ble/BleAutoReconnectCoordinator.swift',
      ).readAsStringSync();

      final claim = reconnect.indexOf(
        'restorationCoordinator.claimPendingPeripheral(',
      );
      final identityPending = reconnect.indexOf(
        'autoReconnect identityPending:',
      );
      expect(claim, isNonNegative);
      expect(identityPending, greaterThan(claim));
      expect(reconnect, contains('findPeripheralFromConnected('));
      expect(reconnect, contains('requireUniqueMatch: true'));
      expect(reconnect, contains('restoredPeripheralClaimed'));
      expect(reconnect, contains('resolvedUuid: resolvedUuid'));
      expect(
        reconnect,
        contains('activateArmedReconnectTask(task, source: source)'),
      );
      expect(
        manager,
        isNot(contains('self?.flushPendingRestoredPeripherals()')),
        reason: 'initConfigs 不能在当前设备 identity 就绪前恢复历史设备',
      );
    },
  );
}
