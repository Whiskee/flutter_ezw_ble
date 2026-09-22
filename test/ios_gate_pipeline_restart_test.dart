import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 2026-09-07 真机：重启后 SR 交还 .connected 的左腿，claim 后 250 ms 系统 peerDisconnected、
/// 200 ms 后 peerConnected + didConnect；已发出的 discoverServices 随旧链路作废，
/// CoreBluetooth 不回 didDisconnect，didConnect 被当作「duplicate physical callback」
/// 忽略，pipeline 20 秒超时，右腿排在 Gate 后面一直拿不到准入。以下契约固定修复。
void main() {
  final flow = File(
    'ios/Classes/ble/BleConnectionAdmissionFlow.swift',
  ).readAsStringSync();
  final gate = File(
    'ios/Classes/ble/BleConnectionAdmissionGate.swift',
  ).readAsStringSync();
  final manager = File('ios/Classes/ble/BleManager.swift').readAsStringSync();

  test('peerDisconnected after contact and before readiness marks the session', () {
    expect(gate, contains('var linkDroppedSinceContact: Bool = false'));
    expect(gate, contains('func isActiveOwner(_ admission: BleConnectionAdmission) -> Bool'));
    final peerDisconnected = manager.substring(
      manager.indexOf('case .peerDisconnected:'),
      manager.indexOf('@unknown default:', manager.indexOf('case .peerDisconnected:')),
    );
    expect(peerDisconnected, contains('markLinkDroppedBeforeReadiness(peripheral)'));
    final mark = flow.substring(
      flow.indexOf('func markLinkDroppedBeforeReadiness('),
      flow.indexOf('func startGrantedGattPipeline('),
    );
    expect(mark, contains('session.peripheral === peripheral'));
    expect(mark, contains('session.hasObservedPhysicalContact'));
    // 业务已 connected 的链路不记，真实断连仍由 didDisconnectPeripheral 收口。
    expect(mark, contains('guard !businessConnected else { return }'));
    expect(mark, contains('session.linkDroppedSinceContact = true'));
  });

  test('duplicate physical callback restarts the pipeline only for the active owner after a drop', () {
    final dup = flow.substring(
      flow.indexOf('case .duplicate:'),
      flow.indexOf('duplicate physical callback ignored'),
    );
    expect(dup, contains('latest.linkDroppedSinceContact,'));
    expect(dup, contains('connectionAdmissionGate.isActiveOwner(admission)'));
    expect(dup, contains('restarted.linkDroppedSinceContact = false'));
    expect(dup, contains('type: "ios_gate_pipeline_restarted"'));
    expect(dup, contains('startGrantedGattPipeline(admission)'));
    // 没有掉链证据或非 active owner 时仍按重复回调忽略。
    expect(flow, contains('duplicate physical callback ignored'));
  });
}
