import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 2026-09-07 真机：iOS 通知转发走 ANCS，切换眼镜后旧眼镜的右腿仍由系统持有链路并被
/// 系统自动重连；本 central 按私有服务注册的 connection event 把它再次交来，escrow 对
/// `.disconnected` 对象 rearm（connect），旧眼镜于是跟着每次重启一起回来，还留下 finalize
/// 取消与 barrier 的一连串副作用。以下契约固定「只为当前目标 rearm / 只托管当前目标」。
void main() {
  final flow = File(
    'ios/Classes/ble/BleStateRestorationFlow.swift',
  ).readAsStringSync();
  final coordinator = File(
    'ios/Classes/ble/BleStateRestorationCoordinator.swift',
  ).readAsStringSync();

  test('restoration target = persisted reconnect target or runtime reconnect owner', () {
    final target = flow.substring(
      flow.indexOf('func isStateRestorationTarget(_ peripheral: CBPeripheral) -> Bool'),
      flow.indexOf('func escrowStateRestorationPeripheral('),
    );
    expect(target, contains('reconnectStore.target(uuid: uuid, name: name) != nil'));
    expect(target, contains('reconnectTasks.values.contains'));
    expect(target, contains('isSameConnectTarget(storedUuid: task.uuid, storedName: task.name, uuid: uuid, name: name)'));
    expect(coordinator, contains('func contains(uuid: String) -> Bool'));
  });

  test('connection events for non-target peripherals are ignored before escrow', () {
    final escrow = flow.substring(
      flow.indexOf('func escrowStateRestorationPeripheral('),
      flow.indexOf('func handleStateRestorationEscrowDidConnect('),
    );
    expect(escrow, contains('if source == "connectionEvent",'));
    expect(escrow, contains('!isStateRestorationTarget(peripheral),'));
    expect(escrow, contains('!restorationCoordinator.contains(uuid: peripheral.identifier.uuidString)'));
    expect(escrow, contains('detail: "reason=notRestorationTarget, state='));
    // 忽略分支必须先于 delegate 赋值与 enqueue。
    expect(
      escrow.indexOf('reason=notRestorationTarget'),
      lessThan(escrow.indexOf('peripheral.delegate = self')),
    );
    expect(
      escrow.indexOf('peripheral.delegate = self'),
      lessThan(escrow.indexOf('restorationCoordinator.enqueue(peripheral)')),
    );
  });

  test('escrow rearm only issues connect for restoration targets', () {
    final rearm = flow.substring(
      flow.indexOf('private func rearmStateRestorationEscrow('),
      flow.indexOf('func rearmDeferredStateRestorationEscrowsAfterPowerOn()'),
    );
    expect(rearm, contains('guard isStateRestorationTarget(peripheral) else {'));
    expect(rearm, contains('type: "ios_restore_escrow_rearm_skipped"'));
    expect(
      rearm.indexOf('ios_restore_escrow_rearm_skipped'),
      lessThan(rearm.indexOf('connectPeripheral(peripheral, autoReconnect: true)')),
    );
    // 未认领的 .disconnected 非目标由 finalize 直接丢弃，不 cancel。
    expect(flow, contains('if peripheral.state != .disconnected {'));
  });
}
