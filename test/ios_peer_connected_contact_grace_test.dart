import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 2026-09-03 真机：戒指 State Restoration 交还 `.connecting` 对象后，系统随即
/// 发出 `peerConnected`（设置页显示已连接），但 restored pending 请求 26 分钟没有
/// `didConnect`；提升前台后 `findPeripheralFromConnected` 命中，却因 pending 对象
/// 不是 `.connected` 而静默 return。以下契约固定两条修复路径。
void main() {
  final admissionFlow = File(
    'ios/Classes/ble/BleConnectionAdmissionFlow.swift',
  ).readAsStringSync();
  final coordinator = File(
    'ios/Classes/ble/BleAutoReconnectCoordinator.swift',
  ).readAsStringSync();
  final manager = File('ios/Classes/ble/BleManager.swift').readAsStringSync();
  final restoration = File(
    'ios/Classes/ble/BleStateRestorationCoordinator.swift',
  ).readAsStringSync();
  final restorationFlow = File(
    'ios/Classes/ble/BleStateRestorationFlow.swift',
  ).readAsStringSync();

  test('peer connected without didConnect arms a bounded contact grace', () {
    expect(
      admissionFlow,
      contains('var peerConnectedContactGraceTimeout: TimeInterval { 10.0 }'),
    );
    expect(
      admissionFlow,
      contains(
        'func armPeerConnectedContactGrace(_ peripheral: CBPeripheral, reason: String)',
      ),
    );
    // 只有长期 reconnect owner 才允许替换后重新注册；普通前台手动 attempt 不介入。
    expect(
      admissionFlow,
      contains(
        'reconnectTasks[reconnectKey(uuid: admission.endpointId)] != nil else',
      ),
    );
    expect(
      manager,
      contains(
        'let peerConnectedContactGraceWatchdogs = BlePendingPhysicalConnectWatchdogRegistry()',
      ),
    );
    // endpoint teardown / 蓝牙关闭 / 物理接触 / 释放 admission 都要撤销宽限 timer。
    expect(
      manager,
      contains(
        'peerConnectedContactGraceWatchdogs.remove(endpointIds: endpointIds).forEach { \$0.cancel() }',
      ),
    );
    expect(
      admissionFlow,
      contains(
        'peerConnectedContactGraceWatchdogs.removeAll().forEach { \$0.cancel() }',
      ),
    );
    expect(
      'peerConnectedContactGraceWatchdogs.takeIfCurrent(admission)?.cancel()'
          .allMatches(admissionFlow)
          .length,
      greaterThanOrEqualTo(2),
      reason: 'enqueuePhysicalConnectionThroughGate 与 stale replacement 都要取消宽限',
    );
    expect(
      admissionFlow,
      contains(
        'peerConnectedContactGraceWatchdogs.takeIfCurrent(current)?.cancel()',
      ),
    );
  });

  test('contact grace expiry replaces the stalled pending attempt exactly', () {
    final expiry = admissionFlow.substring(
      admissionFlow.indexOf('private func expirePeerConnectedContactGrace('),
    );
    expect(
      expiry,
      contains(
        'guard peerConnectedContactGraceWatchdogs.takeIfCurrent(expectedAdmission) != nil',
      ),
    );
    expect(expiry, contains('session.peripheral === peripheral'));
    expect(expiry, contains('!session.hasObservedPhysicalContact'));
    // 状态已 connected 但回调丢失时与 pending watchdog 一致，直接进 Gate。
    expect(expiry, contains('enqueuePhysicalConnectionThroughGate(peripheral)'));
    expect(expiry, contains('trigger: .peerConnectedWithoutContact'));
    expect(expiry, contains('beginReconnectAttempt(uuid: admission.endpointId)'));
    expect(expiry, contains('ios_peer_connected_pending_replaced'));
    // 新 trigger 不叠加 pending 时长门槛：宽限已单独计时。
    expect(admissionFlow, contains('case .peerConnectedWithoutContact:'));
    expect(
      admissionFlow,
      contains('''        case .peerConnectedWithoutContact:
            // 宽限已由 contact grace watchdog 单独计时，这里不再叠加 pending 时长门槛。
            replacementThreshold = 0'''),
    );
  });

  test('connection event with active request arms grace instead of only skipping', () {
    final handler = manager.substring(
      manager.indexOf('connectionEventDidOccur event: CBConnectionEvent'),
    );
    final peerConnected = handler.substring(
      handler.indexOf('case .peerConnected:'),
      handler.indexOf('case .peerDisconnected:'),
    );
    expect(peerConnected, contains('reason=activeConnectRequest'));
    expect(
      peerConnected,
      contains(
        'armPeerConnectedContactGrace(peripheral, reason: "connectionEvent peerConnected")',
      ),
    );
    // 顺序：先记录 ignored 事件与日志，再武装宽限，最后 return，不进入 escrow。
    expect(
      peerConnected.indexOf('armPeerConnectedContactGrace'),
      greaterThan(peerConnected.indexOf('ios_connection_event_ignored')),
    );
    expect(
      peerConnected.indexOf('armPeerConnectedContactGrace'),
      lessThan(peerConnected.indexOf('escrowStateRestorationPeripheral')),
    );
  });

  test('escrow remembers peerConnected evidence and claim arms grace', () {
    expect(restoration, contains('var peerConnectedObservedAt: Date? = nil'));
    expect(
      restoration,
      contains('func notePeerConnectedObservation(uuid: String, at date: Date = Date())'),
    );
    expect(
      restoration,
      contains('peerConnectedObservations\n            .removeValue(forKey: peripheral.identifier.uuidString)'),
    );
    // remove / drain / clear 都要同步清理观察记录，不得让旧证据跨对象复活。
    expect(
      'peerConnectedObservations.removeValue(forKey: \$0)'.allMatches(restoration).length,
      greaterThanOrEqualTo(2),
    );
    expect(restoration, contains('peerConnectedObservations.removeAll()'));
    expect(
      restorationFlow,
      contains('if source == "connectionEvent", action == .keepPending {'),
    );
    expect(
      restorationFlow,
      contains(
        'restorationCoordinator.notePeerConnectedObservation(uuid: peripheral.identifier.uuidString)',
      ),
    );
    final claim = coordinator.substring(
      coordinator.indexOf('private func activateClaimedStateRestoration('),
    );
    final pendingCase = claim.substring(
      claim.indexOf('case .pending:'),
      claim.indexOf('case .idle:'),
    );
    expect(pendingCase, contains('startPendingPhysicalConnectWatchdog('));
    expect(pendingCase, contains('if claim.peerConnectedObservedAt != nil {'));
    expect(
      pendingCase,
      contains('reason: "stateRestoration claim after peerConnected"'),
    );
  });

  test('foreground system-connected reconcile no longer returns silently', () {
    final direct = coordinator.substring(
      coordinator.indexOf('func beginDirectReconnectAttempt('),
    );
    expect(direct, contains('var systemConnectedTakeover = false'));
    expect(direct, contains('systemConnectedTakeover = true'));
    // 原有 `.connected` 分支保持不变。
    expect(
      direct,
      contains('current pending object is now system-connected; enter exact Gate'),
    );
    expect(
      direct,
      contains('system-connected peripheral replaces stale pending object'),
    );
    // 新增：对象非 connected 但系统已持有链路时，按同一 trigger/threshold 替换。
    expect(direct, contains('} else if systemConnectedTakeover,'));
    expect(
      direct,
      contains('system-connected peripheral replaces stalled pending connect state='),
    );
    final stalledBranch = direct.substring(
      direct.indexOf('} else if systemConnectedTakeover,'),
      direct.indexOf('system-connected peripheral replaces stalled pending connect'),
    );
    expect(stalledBranch, contains('trigger: .systemConnectedReconcile'));
    expect(stalledBranch, contains('systemConnectedStalledReplacementMinInterval'));
    expect(stalledBranch, contains('systemConnectedStalledReplacementAt[key] = Date()'));
    expect(stalledBranch, contains('currentIsPendingTeardown = true'));
    expect(
      admissionFlow,
      contains('var systemConnectedStalledReplacementMinInterval: TimeInterval { 15.0 }'),
    );
    expect(manager, contains('var systemConnectedStalledReplacementAt: [String: Date] = [:]'));
  });

  test('stale peerConnected evidence is dropped on peerDisconnected / terminal', () {
    expect(restoration, contains('func clearPeerConnectedObservation(uuid: String)'));
    final terminate = restoration.substring(
      restoration.indexOf('func didTerminate('),
      restoration.indexOf('func drainPendingPeripherals()'),
    );
    expect(
      terminate,
      contains('peerConnectedObservations.removeValue(forKey: peripheral.identifier.uuidString)'),
    );
    final handler = manager.substring(
      manager.indexOf('connectionEventDidOccur event: CBConnectionEvent'),
    );
    final peerDisconnected = handler.substring(
      handler.indexOf('case .peerDisconnected:'),
      handler.indexOf('@unknown default:'),
    );
    expect(
      peerDisconnected,
      contains('restorationCoordinator.clearPeerConnectedObservation(uuid: uuid)'),
    );
    // 武装只写日志；持久化事件环只记录真正到期替换。
    expect(admissionFlow, isNot(contains('ios_peer_connected_contact_grace')));
    expect(admissionFlow, contains('ios_peer_connected_pending_replaced'));
  });
}
