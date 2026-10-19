import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _sourceBetween(String source, String startMarker, String endMarker) {
  final start = source.indexOf(startMarker);
  expect(start, isNonNegative, reason: 'missing start marker: $startMarker');
  final end = source.indexOf(endMarker, start);
  expect(end, isNonNegative, reason: 'missing end marker: $endMarker');
  return source.substring(start, end);
}

void main() {
  test('Bluetooth ON waits for the Dart recovery batch before opening GATT',
      () {
    final source = File(
      'android/src/main/kotlin/com/fzfstudio/ezw_ble/ble/'
      'BleAutoReconnectSupervisor.kt',
    ).readAsStringSync();
    final resume = _sourceBetween(
      source,
      'fun resumeAfterBluetoothOn()',
      '    /**\n     * 判断某个设备是否处于自动回连中的连接尝试。',
    );

    expect(resume, contains('awaitingRecoveryActivation'));
    expect(resume, isNot(contains('schedule(')));
    expect(resume, isNot(contains('beginInitialAttempt(')));
  });

  test('deadline and visibility paths classify owner health explicitly', () {
    final supervisor = File(
      'android/src/main/kotlin/com/fzfstudio/ezw_ble/ble/'
      'BleAutoReconnectSupervisor.kt',
    ).readAsStringSync();
    final manager = File(
      'android/src/main/kotlin/com/fzfstudio/ezw_ble/ble/BleManager.kt',
    ).readAsStringSync();

    expect(supervisor, contains('BlePendingOwnerDisposition'));
    expect(supervisor, contains('repairStalePendingOwner'));
    final manualPromotion = _sourceBetween(
      supervisor,
      'fun promotePendingAttempt(uuid: String)',
      '    /**\n     * OTA reboot 前只剥离当前物理 GATT',
    );
    expect(manualPromotion, contains('classifyPendingPassiveGattOwner'));
    expect(manualPromotion, contains('BlePendingOwnerHealth.STALE'));
    expect(
      supervisor,
      isNot(contains('if (!invalidatePendingPassiveGatt(uuid, expectedGatt))')),
    );
    expect(manager, contains('classifyPendingPassiveGattOwner'));
    expect(manager, contains('BlePendingOwnerHealth.STALE'));
    expect(manager, contains('STALE_OWNER_DROPPED'));

    // 已有 GATT 时 beginAttempt 只跳过重复建链；该 GATT 的物理 deadline 必须保留，
    // 否则 Manager 已回收的孤儿 owner 再无 watchdog 回收重建，原生回连会停摆。
    final beginAttempt = _sourceBetween(
      supervisor,
      'private fun beginAttempt(',
      'private fun beginPassiveReconnect(',
    );
    final existingOwnerReturn = beginAttempt.indexOf(
      'task.passiveGatt != null || task.pendingAdmission',
    );
    expect(existingOwnerReturn, isNonNegative);
    expect(
      beginAttempt.indexOf('task.pendingPhysicalDeadline?.cancel()'),
      greaterThan(existingOwnerReturn),
    );
    // 更高 session 的 exact 换绑被拒时，STALE 孤儿 owner 先修复再安装新 session；
    // 非 STALE 与 OTA recovery owner 仍保持拒绝。
    final sessionRebind = _sourceBetween(
      supervisor,
      'BleReconnectSessionUpdateAction.REBUILD_PHYSICAL_OWNER) {',
      '// 3、没有 live GATT 的 task',
    );
    expect(sessionRebind, contains('repairStaleOwnerForSessionRebind('));
    final staleRebind = _sourceBetween(
      supervisor,
      'private fun repairStaleOwnerForSessionRebind(',
      'private fun clearRecycledPendingOwner(',
    );
    expect(staleRebind, contains('otaRecoveryContext != null'));
    expect(staleRebind, contains('BlePendingOwnerHealth.STALE'));
  });
}
