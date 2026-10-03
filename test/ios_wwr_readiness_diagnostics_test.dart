// iOS WriteWithoutResponse 发送就绪诊断日志的源码契约。
//
// 背景：部分 iOS 26.x 手机上 `canSendWriteWithoutResponse` 长期为 false 且 ready
// 回调不到，但写入仍能送达。排查这类问题需要三项现场证据：
// 1、没有 OTA 队列时 ready 回调是否到达（此前被静默丢弃）；
// 2、普通通道每次写入前后该标志的取值；
// 3、重连前后 CoreBluetooth 是否复用同一个 peripheral 对象。
// 这些采样只用于日志，绝不能参与是否写入的判断。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final manager = File('ios/Classes/ble/BleManager.swift').readAsStringSync();
  final queue = File('ios/Classes/ble/OtaWriteQueue.swift').readAsStringSync();

  String between(String source, String from, String to) {
    final start = source.indexOf(from);
    expect(start, greaterThanOrEqualTo(0), reason: 'missing anchor: $from');
    final end = source.indexOf(to, start + from.length);
    expect(end, greaterThan(start), reason: 'missing anchor: $to');
    return source.substring(start, end);
  }

  test('iOS ready callback without an OTA queue is still logged', () {
    final method = between(
      manager,
      'func peripheralIsReady(toSendWriteWithoutResponse',
      'queue.onPeripheralReadyToSendWriteWithoutResponse()',
    );

    final log = method.indexOf('[ezw_ble][wwr] ready uuid=');
    expect(log, greaterThanOrEqualTo(0));
    expect(method, contains('queue=none'));
    expect(
      method,
      contains(r'canSend=\(peripheral.canSendWriteWithoutResponse)'),
    );
    // 日志必须位于无队列分支的提前返回之前，否则回调仍被静默丢弃。
    expect(log, lessThan(method.indexOf('return')));
  });

  test('iOS OTA queue ready log reports the readiness flag', () {
    final method = between(
      queue,
      'func onPeripheralReadyToSendWriteWithoutResponse()',
      'pump(resumeSource: "callback")',
    );

    // 回调到达但标志仍为 false，与回调根本不到，是两种不同的故障形态。
    expect(method, contains('[ezw_ble][ota] ready endpoint='));
    expect(method, contains('canSend='));
  });

  test('iOS sendCmd samples send readiness around the write', () {
    final method = between(manager, 'func sendCmd(', 'func sendCmdNoWait(');

    final before = method.indexOf(
      'let canSendBefore = device.peripheral.canSendWriteWithoutResponse',
    );
    final write = method.indexOf(
      'device.peripheral.writeValue(data, for: writeChars, '
      'type: .withoutResponse)',
    );
    final log = method.indexOf('wwrDiagnostics(');

    expect(before, greaterThanOrEqualTo(0));
    expect(write, greaterThan(before));
    expect(log, greaterThan(write));
    expect(method, contains('loggerD(msg: "sendCmd: '));
  });

  test('iOS non-OTA sendCmdNoWait samples send readiness around the write', () {
    final branch = between(
      manager,
      '4.4、保持现有非 OTA 行为',
      'private func queueDepthForOta',
    );

    final before = branch.indexOf(
      'let canSendBefore = device.peripheral.canSendWriteWithoutResponse',
    );
    final write = branch.indexOf(
      'device.peripheral.writeValue(data, for: writeChars, '
      'type: .withoutResponse)',
    );
    final log = branch.indexOf('wwrDiagnostics(');

    expect(before, greaterThanOrEqualTo(0));
    expect(write, greaterThan(before));
    expect(log, greaterThan(write));
    expect(branch, contains('loggerD(msg: "sendCmdNoWait: '));
  });

  test('iOS readiness sampling never gates ordinary writes', () {
    final sendCmd = between(manager, 'func sendCmd(', 'func sendCmdNoWait(');
    final noWaitBranch = between(
      manager,
      '4.4、保持现有非 OTA 行为',
      'private func queueDepthForOta',
    );

    // 采样值只允许出现两次：声明一次、传给日志一次。出现第三次说明它被用于
    // 条件判断，普通通道会因此继承 OTA 队列的阻塞问题。
    expect('canSendBefore'.allMatches(sendCmd), hasLength(2));
    expect('canSendBefore'.allMatches(noWaitBranch), hasLength(2));
    expect(sendCmd, isNot(contains('guard device.peripheral.canSend')));
    expect(noWaitBranch, isNot(contains('guard device.peripheral.canSend')));
  });

  test('iOS readiness diagnostics expose post-write flag and object identity',
      () {
    final helper = between(
      manager,
      'func wwrDiagnostics(',
      '\n    }\n',
    );

    expect(helper, contains('peripheral.canSendWriteWithoutResponse'));
    expect(helper, contains('canSendBefore='));
    expect(helper, contains('canSendAfter='));
    // 对象地址用于判断重连前后是否为同一个 CBPeripheral 实例。
    expect(helper, contains('Unmanaged.passUnretained(peripheral).toOpaque()'));
    expect(helper, contains('peripheral='));
  });

  test('iOS OTA queue creation logs the peripheral object identity', () {
    final branch = between(
      manager,
      '4.1、获取或惰性创建 OTA 写队列',
      '4.2、入队后只有真正调用 peripheral.writeValue 才回调成功',
    );

    expect(branch, contains('[ezw_ble][ota] queue created uuid='));
    expect(branch, contains('peripheral='));
  });
}
