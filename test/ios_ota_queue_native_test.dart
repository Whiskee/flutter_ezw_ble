import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('native OTA/file timer ownership and observation-only ACK regressions',
      () async {
    final directory = await Directory.systemTemp.createTemp('ota-queue-test-');
    addTearDown(() => directory.delete(recursive: true));
    // Compile the production queue against a minimal Flutter result/error stub;
    // the ledger uses Foundation only. No device or altered production SDK.
    final stub = await Process.run('swiftc', [
      '-module-cache-path',
      '${directory.path}/module-cache',
      '-parse-as-library',
      '-emit-module',
      '-emit-object',
      '-module-name',
      'Flutter',
      '-emit-module-path',
      '${directory.path}/Flutter.swiftmodule',
      'test/native/FlutterStub.swift',
      '-o',
      '${directory.path}/Flutter.o',
    ]);
    expect(stub.exitCode, 0, reason: '${stub.stdout}\n${stub.stderr}');
    for (final target in <String, List<String>>{
      'queue': [
        'ios/Classes/ble/BleDebugLogPolicy.swift',
        'ios/Classes/ble/OtaWindowCreditLedger.swift',
        'ios/Classes/ble/OtaWriteQueue.swift',
        'test/native/ota_write_queue_log_test.swift',
      ],
      'credit-ledger': [
        'ios/Classes/ble/OtaWindowCreditLedger.swift',
        'test/native/ota_window_credit_ledger_test.swift',
      ],
      'file-owner': [
        'ios/Classes/ble/BleDebugLogPolicy.swift',
        'ios/Classes/ble/OtaWindowCreditLedger.swift',
        'ios/Classes/ble/OtaWriteQueue.swift',
        'test/native/file_batch_owner_test.swift',
      ],
    }.entries) {
      final executable = '${directory.path}/${target.key}';
      final compile = await Process.run('swiftc', [
        '-module-cache-path',
        '${directory.path}/module-cache',
        '-I',
        directory.path,
        '${directory.path}/Flutter.o',
        ...target.value,
        '-o',
        executable,
      ]);
      expect(compile.exitCode, 0,
          reason: '${target.key}: ${compile.stdout}\n${compile.stderr}');
      final run = await Process.run(executable, const []);
      expect(run.exitCode, 0,
          reason: '${target.key}: ${run.stdout}\n${run.stderr}');
      stdout.write(run.stdout);
    }

    // Exercise the exact private production validator, not a duplicated policy.
    // Identity-only fakes let every revoked-target branch run without hardware.
    final manager = File('ios/Classes/ble/BleManager.swift').readAsStringSync();
    final start = manager.indexOf('    private func canSubmitFilePacket(');
    final end = manager.indexOf('\n    /// OTA 错误 details', start);
    expect(start, isNonNegative);
    expect(end, greaterThan(start));
    expect(manager, contains('!self.canSubmitFilePacket(uuid: uuid'));
    final template =
        File('test/native/file_write_target_test.swift').readAsStringSync();
    final source = File('${directory.path}/file-target.swift');
    await source.writeAsString(template.replaceFirst(
      '    // PRODUCTION_FILE_TARGET_VALIDATOR',
      manager.substring(start, end),
    ));
    final executable = '${directory.path}/file-target';
    final compile = await Process.run(
        'swiftc', ['-parse-as-library', source.path, '-o', executable]);
    expect(compile.exitCode, 0, reason: '${compile.stdout}\n${compile.stderr}');
    final run = await Process.run(executable, const []);
    expect(run.exitCode, 0, reason: '${run.stdout}\n${run.stderr}');
    stdout.write(run.stdout);

    // Compile actual manager and MethodChannel FILE methods together with the
    // production queue. Only platform identity/writes and registry are fake.
    final ownerStart = manager.indexOf('    func beginFilePacketBatch(');
    final ownerEnd = manager.indexOf('\n    /// OTA 错误 details', ownerStart);
    expect(ownerStart, isNonNegative);
    expect(ownerEnd, greaterThan(ownerStart));
    final channel =
        File('ios/Classes/ble/BleMethodChannel.swift').readAsStringSync();
    final dispatchStart =
        channel.indexOf('        case .beginFilePacketBatch:');
    final dispatchEnd =
        channel.indexOf('        case .enterUpgradeState:', dispatchStart);
    final decoderStart =
        channel.indexOf('    private static func decodeFramedBatchPackets(');
    final ownerTemplate =
        File('test/native/file_batch_manager_test.swift').readAsStringSync();
    final readyStart = manager
        .indexOf('    func peripheralIsReady(toSendWriteWithoutResponse');
    final readyEnd =
        manager.indexOf('\n    /// Routes a consumed 5403 failure', readyStart);
    expect(readyStart, isNonNegative);
    expect(readyEnd, greaterThan(readyStart));
    final ownerSource = File('${directory.path}/file-manager.swift');
    await ownerSource.writeAsString(ownerTemplate
        .replaceFirst('    // PRODUCTION_FILE_BATCH_MANAGER',
            manager.substring(ownerStart, ownerEnd))
        .replaceFirst('    // PRODUCTION_FILE_READY_CALLBACK',
            manager.substring(readyStart, readyEnd))
        .replaceFirst('        // PRODUCTION_FILE_BATCH_DISPATCH',
            channel.substring(dispatchStart, dispatchEnd))
        .replaceFirst('    // PRODUCTION_FILE_BATCH_DECODER',
            channel.substring(decoderStart, channel.lastIndexOf('\n}'))));
    final ownerExecutable = '${directory.path}/file-manager';
    final ownerCompile = await Process.run('swiftc', [
      '-module-cache-path',
      '${directory.path}/module-cache',
      '-parse-as-library',
      '-I',
      directory.path,
      '${directory.path}/Flutter.o',
      'ios/Classes/ble/BleDebugLogPolicy.swift',
      'ios/Classes/ble/OtaWindowCreditLedger.swift',
      'ios/Classes/ble/OtaWriteQueue.swift',
      ownerSource.path,
      '-o',
      ownerExecutable,
    ]);
    expect(ownerCompile.exitCode, 0,
        reason: '${ownerCompile.stdout}\n${ownerCompile.stderr}');
    final ownerRun = await Process.run(ownerExecutable, const []);
    expect(ownerRun.exitCode, 0,
        reason: '${ownerRun.stdout}\n${ownerRun.stderr}');
    stdout.write(ownerRun.stdout);
  }, skip: !Platform.isMacOS);
}
