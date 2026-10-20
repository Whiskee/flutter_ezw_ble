import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('native scan-window reconcile uses production BleManager policy',
      () async {
    final managerSource =
        File('ios/Classes/ble/BleManager.swift').readAsStringSync();
    final start = managerSource.indexOf('    /**\n     * Dart 层外部扫描 owner 入口。');
    const endMarker = '    /**\n     *  目标外设是否已被系统/CoreBluetooth 持有连接。';
    final end = managerSource.indexOf(endMarker, start);
    expect(start, isNonNegative, reason: 'startExternalScan block moved');
    expect(end, greaterThan(start),
        reason: 'clearScanProjection boundary moved');
    final productionMethods = managerSource.substring(start, end);
    expect(productionMethods, contains('func startExternalScan('));
    expect(productionMethods, contains('func reconcileScanWindow('));
    expect(productionMethods,
        contains('func startPairingRecoveryScanOwner(key: String)'));
    expect(productionMethods, contains('private func clearScanProjection()'));

    final template =
        File('test/native/scan_window_test.swift').readAsStringSync();
    final directory = await Directory.systemTemp.createTemp('ble-scan-window-');
    addTearDown(() => directory.delete(recursive: true));
    final source = File('${directory.path}/main.swift');
    await source.writeAsString(
      template.replaceFirst(
          '// PRODUCTION_METHODS_PLACEHOLDER', productionMethods),
    );

    final executable = '${directory.path}/scan-window-test';
    final compile = await Process.run('swiftc', [
      'ios/Classes/ble/BleDebugLogPolicy.swift',
      source.path,
      '-o',
      executable,
    ]);
    expect(compile.exitCode, 0, reason: '${compile.stdout}\n${compile.stderr}');
    final run = await Process.run(executable, const []);
    stdout.write(run.stdout);
    stderr.write(run.stderr);
    expect(run.exitCode, 0, reason: '${run.stdout}\n${run.stderr}');
    expect(
        run.stdout,
        contains(
            'production BleManager scan-window policy preserves FE59 DFU'));
  }, skip: !Platform.isMacOS);
}
