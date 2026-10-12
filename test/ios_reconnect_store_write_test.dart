import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// Compile production storage and the actual activation arm method. The Swift
// harness replaces peripheral/config inputs and records UserDefaults calls;
// no reconnect algorithm or persistence implementation is copied into the test.
String _method(String source, String signature) {
  final start = source.indexOf(signature);
  if (start < 0) throw StateError('Missing production method: $signature');
  var depth = 0;
  for (var i = source.indexOf('{', start); i < source.length; i++) {
    if (source[i] == '{') depth++;
    if (source[i] == '}' && --depth == 0) {
      return source.substring(start, i + 1);
    }
  }
  throw StateError('Unterminated production method: $signature');
}

void main() {
  test(
    'optimized native reconnect storage preserves identity and owner behavior',
    () async {
      final temporary = Directory.systemTemp.createTempSync(
        'ezw-ble-reconnect-store-',
      );
      try {
        var store = File(
          'ios/Classes/ble/BleReconnectStore.swift',
        ).readAsStringSync();
        final baseline = Platform.environment['EZW_BLE_STORE_BASELINE'];
        if (baseline != null) {
          final original = await Process.run('git', [
            'show',
            '$baseline:ios/Classes/ble/BleReconnectStore.swift',
          ]);
          expect(original.exitCode, 0, reason: '${original.stderr}');
          store = original.stdout as String;
        }
        final productionStore =
            File('${temporary.path}/BleReconnectStore.swift')
              ..writeAsStringSync(store);
        final connect = File(
          'ios/Classes/ble/models/BleConnect.swift',
        ).readAsStringSync();
        final coordinator = File(
          'ios/Classes/ble/BleAutoReconnectCoordinator.swift',
        ).readAsStringSync();
        final productionMethods =
            File('${temporary.path}/ProductionMethods.swift')
              ..writeAsStringSync('''
import Foundation
${connect.substring(connect.indexOf('enum BleConnectSource:'))}
extension BleManager {
${_method(coordinator, '    func reconnectKey(')}
${_method(coordinator, '    func armReconnectTarget(')}
}
''');
        final executable = '${temporary.path}/reconnect-store-tests';
        final build = await Process.run('xcrun', [
          'swiftc',
          '-O',
          productionStore.path,
          productionMethods.path,
          'ios/Classes/ble/BleConnectionAdmissionGate.swift',
          'ios/Classes/ble/BleG2OtaTransactionRegistry.swift',
          'test/native/reconnect_store_write_test.swift',
          '-o',
          executable,
        ]);
        expect(build.exitCode, 0, reason: '${build.stdout}\n${build.stderr}');
        final result = await Process.run(executable, []);
        // Counts describe persistence calls, never disk flushes or energy.
        // ignore: avoid_print
        print(result.stdout);
        expect(result.exitCode, 0,
            reason: '${result.stdout}\n${result.stderr}');
        expect(
          result.stdout,
          contains('native reconnect store: all behavior checks passed'),
        );
      } finally {
        temporary.deleteSync(recursive: true);
      }
    },
    skip: !Platform.isMacOS,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
