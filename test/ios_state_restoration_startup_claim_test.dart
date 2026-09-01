import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('startup reset preserves restoration debt for current-target claim', () {
    final manager = File('ios/Classes/ble/BleManager.swift').readAsStringSync();
    final method = File(
      'ios/Classes/ble/BleMethodChannel.swift',
    ).readAsStringSync();
    final plugin = File(
      'ios/Classes/FlutterEzwBlePlugin.swift',
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
    expect(flow, contains('func hasPendingStateRestoration() -> Bool'));
    expect(flow, contains('restorationCoordinator.hasPendingPeripherals'));
    expect(flow, contains('drainPendingPeripherals()'));
    expect(flow,
        contains('centralManager.cancelPeripheralConnection(peripheral)'));
    expect(plugin, contains('registrar.addApplicationDelegate(instance)'));
    expect(plugin, contains('launchOptions?[.bluetoothCentrals]'));
    expect(
      plugin,
      contains('centralIdentifiers.contains(BleManager.restorationIdentifier)'),
    );
    expect(method, contains('case wasLaunchedForBluetoothStateRestoration'));
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

  test('restoration callbacks stay in physical escrow until exact claim', () {
    final manager = File('ios/Classes/ble/BleManager.swift').readAsStringSync();
    final flow = File(
      'ios/Classes/ble/BleStateRestorationFlow.swift',
    ).readAsStringSync();
    final reconnect = File(
      'ios/Classes/ble/BleAutoReconnectCoordinator.swift',
    ).readAsStringSync();

    expect(manager, contains('escrowStateRestorationPeripheral('));
    expect(
      manager.indexOf('handleStateRestorationEscrowDidConnect(peripheral)'),
      lessThan(manager.indexOf('guard let connectRequest =')),
      reason: 'claim 前 didConnect 不能落入 noBleConfigFound',
    );
    expect(
      manager.indexOf('handleStateRestorationEscrowTerminal('),
      lessThan(manager.indexOf('handleConnectError(peripheral: peripheral')),
      reason: 'claim 前 terminal 必须先重挂，不能进入普通 owner 判断',
    );
    expect(flow, contains('type: "ios_restore_escrow_rearm"'));
    expect(flow, contains('type: "ios_restore_escrow_connected"'));
    expect(flow, contains('beginPeripheralCancellationBarrier(peripheral)'));
    expect(reconnect, contains('activateClaimedStateRestoration('));
    expect(reconnect, contains('type: "ios_restore_escrow_claimed"'));
    expect(
      reconnect,
      contains('else if peripheral.state == .connecting'),
      reason: '已 pending 的 CoreBluetooth connect 只附着 admission，不得重复 connect',
    );
  });

  test(
    'cached restored characteristics reconcile notify before duplicate return',
    () {
      final manager = File(
        'ios/Classes/ble/BleManager.swift',
      ).readAsStringSync();

      final duplicateBranch = manager.indexOf(
        'duplicate chars reconcile notify readiness',
      );
      final duplicateReconcile = manager.indexOf(
        'updateConnectedDevice(',
        duplicateBranch,
      );
      final duplicateReturn = manager.indexOf(
        '\n            return',
        duplicateBranch,
      );

      expect(duplicateBranch, isNonNegative);
      expect(duplicateReconcile, greaterThan(duplicateBranch));
      expect(
        duplicateReconcile,
        lessThan(duplicateReturn),
        reason: '缓存 characteristic 不能绕过当前 restoration attempt 的 notify 对账',
      );
      expect(manager, contains('if readChars.isNotifying'));
      expect(
        manager,
        contains(
          'tryEmitConnectFinish(uuid: uuid, name: name, bleConfig: connectedDevice.belongConfig, tag: "updateConnectedDevice")',
        ),
        reason: '缓存 notify 与正常回调必须复用同一个 exact attempt 完成闸',
      );
    },
  );
}
