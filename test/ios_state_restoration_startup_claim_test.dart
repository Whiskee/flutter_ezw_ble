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
    // finalize 只收口认领窗口快照内的对象；窗口后新入队 escrow 不被迟到债务误取消。
    expect(flow, contains('drainClaimWindowPeripherals()'));
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

  test(
    'SR hardening: process latch, powered-on rearm, window finalize, guarded name claim',
    () {
      final manager =
          File('ios/Classes/ble/BleManager.swift').readAsStringSync();
      final method =
          File('ios/Classes/ble/BleMethodChannel.swift').readAsStringSync();
      final flow = File(
        'ios/Classes/ble/BleStateRestorationFlow.swift',
      ).readAsStringSync();
      final coordinator = File(
        'ios/Classes/ble/BleStateRestorationCoordinator.swift',
      ).readAsStringSync();
      final reconnect = File(
        'ios/Classes/ble/BleAutoReconnectCoordinator.swift',
      ).readAsStringSync();

      // 1、willRestoreState 事实必须在 escrow 建立前一次性锁存，且只读暴露。
      expect(
        manager,
        contains(
          'private(set) static var didExperienceStateRestorationThisProcess',
        ),
      );
      final latchIndex = manager
          .indexOf('BleManager.didExperienceStateRestorationThisProcess = true');
      final escrowIndex = manager.indexOf(
        'escrowStateRestorationPeripheral(peripheral, source: "willRestoreState")',
      );
      expect(latchIndex, isNonNegative);
      expect(
        latchIndex,
        lessThan(escrowIndex),
        reason: '进程级 SR 事实先于 escrow 建立锁存，claim/finalize 清空后仍可查询',
      );
      expect(method, contains('case didExperienceStateRestorationThisProcess'));
      expect(
        method,
        contains('result(BleManager.didExperienceStateRestorationThisProcess)'),
      );

      // 2、缺失 bluetooth-central 的降级必须发射可 grep 的排障警告。
      expect(
        manager,
        contains('NSLog("%@", stateRestorationMissingBluetoothCentralWarning)'),
      );
      expect(
        manager,
        contains(
          'BleEC.logger.emit("[e]-\\(stateRestorationMissingBluetoothCentralWarning)")',
        ),
      );

      // 3、escrow rearm 未 poweredOn 时挂起，poweredOn 后补偿执行。
      expect(flow, contains('guard centralManager.state == .poweredOn else'));
      expect(flow, contains('deferPowerOnRearm(uuid:'));
      expect(
        flow,
        contains('func rearmDeferredStateRestorationEscrowsAfterPowerOn()'),
      );
      expect(
        manager,
        contains('rearmDeferredStateRestorationEscrowsAfterPowerOn()'),
        reason: 'poweredOn 分支必须补偿被挂起的 escrow rearm',
      );

      // 4、activation 建立认领窗口，finalize 只收口窗口快照内对象。
      expect(coordinator, contains('func markClaimWindowSnapshot()'));
      expect(coordinator, contains('func drainClaimWindowPeripherals()'));
      expect(
        reconnect,
        contains('restorationCoordinator.markClaimWindowSnapshot()'),
      );

      // 5、名称兜底认领必须同时命中目标 config 的 nameFilters。
      expect(
        coordinator,
        contains('nameFilters.contains { peripheralName.contains(\$0) }'),
      );
      expect(reconnect, contains('nameFilters: config.scan.nameFilters'));
    },
  );

  test(
    'connection event never re-escrows a peripheral already owned by an active '
    'connect request (2026-09-02 device: claimed leg held 21 s before GATT)',
    () {
      final manager = File('ios/Classes/ble/BleManager.swift').readAsStringSync();
      final handler = manager.substring(
        manager.indexOf('connectionEventDidOccur event: CBConnectionEvent'),
        manager.indexOf('didDisconnectPeripheral peripheral: CBPeripheral, timestamp'),
      );
      final ownerGuard = handler.indexOf(
        'findActiveConnectRequest(peripheral: peripheral) != nil',
      );
      final escrow = handler.indexOf(
        'escrowStateRestorationPeripheral(peripheral, source: "connectionEvent")',
      );
      expect(ownerGuard, isNonNegative);
      expect(escrow, greaterThan(ownerGuard));
      expect(handler, contains('reason=activeConnectRequest'));
    },
  );
}
