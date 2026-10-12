import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_ezw_ble/flutter_ezw_ble.dart';
import 'package:flutter_ezw_ble/flutter_ezw_ble_method_channel.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('flutter_ezw_ble');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test(
    'public Debug API forwards both settings and preserves native failure',
    () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return null;
      });
      await EzwBle.to.setDebugLoggingEnabled(true);
      await MethodChannelEzwBle().setDebugLoggingEnabled(false);
      expect(calls.map((call) => call.method), [
        'setDebugLoggingEnabled',
        'setDebugLoggingEnabled',
      ]);
      expect(calls.map((call) => call.arguments), [true, false]);

      messenger.setMockMethodCallHandler(channel, (_) async {
        throw PlatformException(code: 'native_unavailable');
      });
      await expectLater(
        EzwBle.to.setDebugLoggingEnabled(true),
        throwsA(isA<PlatformException>()),
      );
    },
  );

  test('native dispatcher changes only the independent logging policy', () {
    final ios = File(
      'ios/Classes/ble/BleMethodChannel.swift',
    ).readAsStringSync();
    final debugCase = ios.substring(
      ios.indexOf('case .setDebugLoggingEnabled:'),
      ios.indexOf('case .cleanConnectCache:'),
    );
    expect(
      debugCase,
      contains('BleDebugLogPolicy.setEnabled(arguments as? Bool == true)'),
    );
    expect(debugCase, isNot(contains('BleManager.shared')));
    final android = File(
      'android/src/main/kotlin/com/fzfstudio/ezw_ble/ble/BleMethodChannel.kt',
    ).readAsStringSync();
    final androidCase = android.substring(
      android.indexOf('SET_DEBUG_LOGGING_ENABLED ->'),
      android.indexOf('CLEAN_CONNECT_CACHE ->'),
    );
    expect(androidCase, isNot(contains('BleManager.instance')));
  });

  test(
    'optimized native logging and real OTA queue preserve behavior',
    () async {
      final temporary = Directory.systemTemp.createTempSync(
        'ezw-ble-debug-log-',
      );
      try {
        var manager = File(
          'ios/Classes/ble/BleManager.swift',
        ).readAsStringSync();
        // Optional negative verification compiles the original production logger
        // declarations against the same harness; it does not mirror their logic.
        final baseline = Platform.environment['EZW_BLE_LOG_BASELINE'];
        if (baseline != null) {
          final original = await Process.run('git', [
            'show',
            '$baseline:ios/Classes/ble/BleManager.swift',
          ]);
          expect(original.exitCode, 0, reason: '${original.stderr}');
          manager = original.stdout as String;
        }
        final loggerStart = manager.indexOf('    func loggerD(');
        final loggerEnd = manager.indexOf('\n}\n', loggerStart);
        final scan = File(
          'ios/Classes/ble/BleScanPipeline.swift',
        ).readAsStringSync();
        final scanStart = scan.indexOf('    private func logScanDropOnce(');
        final scanEnd = scan.indexOf('\n    /**', scanStart);
        final productionMethods = File(
          '${temporary.path}/LoggingMethods.swift',
        );
        productionMethods.writeAsStringSync('''
final class BleManager {
${manager.substring(loggerStart, loggerEnd)}
${scan.substring(scanStart, scanEnd)}
    func scanLog(key: @autoclosure () -> String, message: @autoclosure () -> String) {
        logScanDropOnce(key: key(), message: message())
    }
}
${scan.substring(scan.indexOf('private enum BleScanDebugLog {'))}
''');
        // Compile the actual OTA queue. Only the unavailable Flutter module is
        // replaced by the Result/Error boundary declared in the native harness.
        final queue = File('${temporary.path}/OtaWriteQueue.swift');
        queue.writeAsStringSync(
          File(
            'ios/Classes/ble/OtaWriteQueue.swift',
          ).readAsStringSync().replaceFirst('import Flutter', ''),
        );
        final executable = '${temporary.path}/debug-log-tests';
        final build = await Process.run('xcrun', [
          'swiftc',
          '-O',
          'ios/Classes/ble/BleDebugLogPolicy.swift',
          productionMethods.path,
          queue.path,
          'test/native/debug_logging_test.swift',
          '-o',
          executable,
        ]);
        expect(build.exitCode, 0, reason: '${build.stdout}\n${build.stderr}');
        final result = await Process.run(executable, []);
        // Counts describe formatting/emission and queue invariants, not energy.
        // ignore: avoid_print
        print(result.stdout);
        expect(
          result.exitCode,
          0,
          reason: '${result.stdout}\n${result.stderr}',
        );
        expect(
          result.stdout,
          contains('native debug logging: all behavior checks passed'),
        );
      } finally {
        temporary.deleteSync(recursive: true);
      }
    },
    skip: !Platform.isMacOS,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
