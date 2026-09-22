import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 2026-09-07 真机：重启后 finalize 取消未认领的 escrow（另一台眼镜的右腿），
/// cancel 后 CBPeripheral 无人强持有随即释放；watchdog 弱持有导致 barrier token
/// 永远留在 activeTokens。用户随后从搜索页切换到该眼镜，右腿 connect 被
/// 「defer connect behind cancellation barrier」挂起 60 秒直至超时，只有蓝牙开关
/// 重置 Gate 才恢复。以下契约固定修复。
void main() {
  final admissionFlow = File(
    'ios/Classes/ble/BleConnectionAdmissionFlow.swift',
  ).readAsStringSync();

  String segment(String source, String start, String end) {
    final begin = source.indexOf(start);
    expect(begin, isNonNegative, reason: 'missing $start');
    final finish = source.indexOf(end, begin);
    expect(finish, isNonNegative, reason: 'missing $end');
    return source.substring(begin, finish);
  }

  test('cancellation barrier watchdog retains the peripheral until it fires', () {
    final begin = segment(
      admissionFlow,
      'func beginPeripheralCancellationBarrier(',
      'func connectPeripheralAfterCancellationBarrier(',
    );
    expect(begin, contains('let workItem = DispatchWorkItem { [weak self] in'));
    expect(
      begin,
      isNot(contains('weak peripheral')),
      reason: '弱持有会让已释放对象的 barrier 永远不过期',
    );
    expect(begin, contains('self.expirePeripheralCancellationBarrier('));
    expect(begin, contains('deadline: .now() + peripheralCancellationBarrierTimeout'));
  });

  test('deferred connect after barrier release drives the current session object', () {
    final deferred = segment(
      admissionFlow,
      'private func startDeferredPeripheralConnection(',
      'private func redriveCurrentConnectionAfterCancellationDebt(',
    );
    expect(deferred, isNot(contains('session.peripheral === peripheral,')));
    expect(deferred, contains('if session.peripheral !== peripheral {'));
    expect(
      deferred,
      contains('''        drivePeripheralConnection(
            session.peripheral,'''),
    );
    expect(deferred, contains('reason: "cancellation barrier released"'));
  });
}
