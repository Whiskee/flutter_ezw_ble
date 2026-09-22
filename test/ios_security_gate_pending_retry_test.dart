import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 截取 [source] 中从 [start] 到 [end]（不含）之间的片段，用于把断言限定在单个函数内。
String _slice(String source, String start, String end) {
  final from = source.indexOf(start);
  expect(from, isNonNegative, reason: '找不到起点：$start');
  final to = source.indexOf(end, from + start.length);
  expect(to, greaterThan(from), reason: '找不到终点：$end');
  return source.substring(from, to);
}

/// 2026-09-18 真机回归（iOS 26.5.2 重启后 SR 后台拉起）：G2 右腿是 ANCS 客户端，
/// 链路由系统持有、永不广播。5403 超时后旧实现等待只在 active 时扫描的新鲜广播，
/// 整段后台单腿；前台对账又用 escrow rearm 发出无主 connect，产生 noBleConfigFound(0)。
void main() {
  final store =
      File('ios/Classes/ble/BleReconnectStore.swift').readAsStringSync();
  final manager = File('ios/Classes/ble/BleManager.swift').readAsStringSync();
  final reconnect = File('ios/Classes/ble/BleAutoReconnectCoordinator.swift')
      .readAsStringSync();
  final admission = File('ios/Classes/ble/BleConnectionAdmissionFlow.swift')
      .readAsStringSync();

  test('5403 automatic failures 1-4 rebuild a pending connect, not fresh ads',
      () {
    expect(store, contains('case retryPendingConnect'));
    expect(
      store,
      contains('case retryFreshAdvertisement'),
      reason: 'R1 Code 14 仍保留新鲜广播恢复',
    );
    final policy = _slice(
      store,
      'static func actionAfterSecurityGateFailure(',
      'enum BlePeerPairingFailureAction',
    );
    expect(policy, contains(': .retryPendingConnect'));
    expect(policy, isNot(contains('.retryFreshAdvertisement')));

    final register = _slice(
      reconnect,
      'func registerSecurityGateFailure(',
      'func resetSecurityGateRecoveryAfterSuccess(',
    );
    expect(register, contains('return .retryPendingConnect'));
    expect(register, isNot(contains('return .retryFreshAdvertisement')));
    expect(
      register,
      isNot(contains('task.pairingRecoveryState = .awaitingFreshAdvertisement')),
      reason: '5403 不得进入只在 active 时扫描的新鲜广播恢复',
    );
    expect(
      register,
      isNot(contains('task.hasAttemptedPairingRecovery = true')),
      reason: '5403 不等于 Code 14，之后首个 Code 14 仍应获得一次新鲜广播恢复',
    );
    expect(
      register,
      isNot(contains('purgeStaleScanCache(')),
      reason: 'inactive 只能复用进程内 peripheral，不能清掉其来源',
    );
    expect(register, contains('cancelPairingRecoveryDiscovery(key: key)'));
    expect(register, contains('task.pairingRecoveryState = .normal'));
    expect(
      register.indexOf('upsertSecurityRecoveryRecord('),
      lessThan(register.indexOf('return .retryPendingConnect')),
      reason: '预算必须在任何 owner 变更前落盘',
    );
  });

  test('retryPendingConnect tears down through the barrier and reschedules',
      () {
    final handle = _slice(
      manager,
      'private func handleSecurityGateFailure(',
      '/// Completes only the protected write',
    );
    final retry = handle.indexOf('if recoveryAction == .retryPendingConnect {');
    expect(retry, isNonNegative);
    expect(handle, isNot(contains('.retryFreshAdvertisement')));
    final retryBranch = handle.substring(
      retry,
      handle.indexOf('if recoveryAction == .securityRecoveryExhausted {'),
    );
    expect(retryBranch, contains('state: .disconnectFromSys'));
    expect(retryBranch, contains('preserveSecurityGateRecovery: true'));

    // barrier 终态/2 秒 watchdog 之后才清 request 并补调度，由同一 owner 重建 attempt。
    final teardown = _slice(
      admission,
      'func completePendingConnectionAdmissionTeardown(',
      'loggerD(msg: "admission gate: \\(pending.admission.endpointId), teardown complete',
    );
    final removeRequest = teardown.indexOf('removeActiveConnectRequest(');
    final preserve = teardown.indexOf('if !pending.preserveSecurityGateRecovery');
    final schedule = teardown.indexOf('scheduleReconnect(');
    expect(removeRequest, isNonNegative);
    expect(preserve, greaterThan(removeRequest));
    expect(schedule, greaterThan(preserve));

    // inactive 时 beginDirectReconnectAttempt 只复用进程内对象，随后登记 attempt 再 connect。
    final begin = _slice(
      reconnect,
      'func beginDirectReconnectAttempt(',
      'func registerPeerPairingFailure(',
    );
    final inMemory = begin.indexOf('inMemoryReconnectPeripheral(task)');
    final systemConnected = begin.indexOf('findPeripheralFromConnected(');
    final connect = begin.indexOf('connectPeripheralAfterCancellationBarrier(');
    expect(inMemory, isNonNegative);
    expect(systemConnected, greaterThan(inMemory));
    expect(connect, greaterThan(systemConnected));
  });

  test('foreground reconciliation never re-arms an unowned connect', () {
    final reconcile = _slice(
      reconnect,
      'private func runActiveStartupReconciliation(',
      'func resumeAutoReconnectFromConnectionEvent(',
    );
    expect(
      reconcile,
      isNot(contains('escrowStateRestorationPeripheral(')),
      reason: 'rearm 会在 owner 认领前直接 connect，owner 拒绝时留下无主链路',
    );
    expect(
      reconcile,
      isNot(contains('resumeAutoReconnectFromConnectionEvent(peripheral)')),
    );
    expect(
      'activateAutoReconnectTargets('.allMatches(reconcile).length,
      2,
      reason: '有/无 physical session 两个分支都走 exact activation',
    );
    expect(
      'scheduleActiveReconciliation: false'.allMatches(reconcile).length,
      2,
    );
    expect(reconcile, contains('ios_active_startup_reconcile_resolved'));
    expect(reconcile, contains('ios_active_startup_reconcile_takeover'));
  });
}
