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

  test('sampling pause forwards independently and preserves native failure',
      () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
    await EzwBle.to.setConnectionTraceSamplingPaused(true);
    await MethodChannelEzwBle().setConnectionTraceSamplingPaused(false);
    expect(calls.map((c) => c.method), [
      'setConnectionTraceSamplingPaused',
      'setConnectionTraceSamplingPaused'
    ]);
    expect(calls.map((c) => c.arguments), [true, false]);
    messenger.setMockMethodCallHandler(channel, (_) async {
      throw PlatformException(code: 'native_unavailable');
    });
    await expectLater(EzwBle.to.setConnectionTraceSamplingPaused(true),
        throwsA(isA<PlatformException>()));
  });

  test('native setter preserves startup and Android accepts a no-op', () {
    final ios =
        File('ios/Classes/ble/BleMethodChannel.swift').readAsStringSync();
    final setter = ios.substring(
      ios.indexOf('case .setConnectionTraceSamplingPaused:'),
      ios.indexOf('case .setDebugLoggingEnabled:'),
    );
    expect(setter, contains('BleNativeTraceRssiSampler.shared.setPaused'));
    expect(setter, isNot(contains('BleManager.shared')));
    final android = File(
      'android/src/main/kotlin/com/fzfstudio/ezw_ble/ble/BleMethodChannel.kt',
    ).readAsStringSync();
    final noOp = android.substring(
      android.indexOf('SET_CONNECTION_TRACE_SAMPLING_PAUSED ->'),
      android.indexOf('SET_DEBUG_LOGGING_ENABLED ->'),
    );
    expect(noOp, isNot(contains('BleManager.instance')));
  });

  test(
      'optimized production sampler and real Manager methods guard quiet reads',
      () async {
    final temporary = Directory.systemTemp.createTempSync('ezw-rssi-sampling-');
    try {
      final source =
          File('ios/Classes/ble/BleManager.swift').readAsStringSync();
      final methods = File('${temporary.path}/ManagerMethods.swift');
      methods.writeAsStringSync('''
import Foundation
final class BleManager {
    let nativeTraceRssiSampler: BleNativeTraceRssiSampler
    let nativeTraceRssiRequests = BleNativeTraceRssiRequests()
    var connectionTraceEnabled = false
    var nativeConnectionTraces: [String: BleNativeConnectionTraceBuffer] = [:]
    var nativeTraceRssiInFlightAttemptIds: [String: String] = [:]
    var nativeTraceLastConnectStates: [String: String] = [:]
    var connectedDevices: [TestConnectedDevice] = []
    init(sampler: BleNativeTraceRssiSampler) { nativeTraceRssiSampler = sampler }
    func reconnectKey(uuid: String) -> String { uuid }
    func currentConnectionAdmission(uuid: String) -> String? { nil }
    func loggerD(msg: String) {}
    func loggerE(msg: String) {}
${_method(source, '    func setConnectionTraceEnabled(')}
${source.substring(source.indexOf('    func startNativeTraceRssiSampling('), source.indexOf('\n    /**', source.indexOf('    private func readNativeTraceRssi(')))}
${_method(source, '    func peripheral(_ peripheral: CBPeripheral, didReadRSSI')}
}
''');
      final executable = '${temporary.path}/rssi-tests';
      final build = await Process.run('xcrun', [
        'swiftc',
        '-O',
        'ios/Classes/ble/BleNativeTraceRssiSampler.swift',
        'ios/Classes/ble/BleNativeConnectionTrace.swift',
        methods.path,
        'test/native/native_trace_rssi_sampling_test.swift',
        '-o',
        executable,
      ]);
      expect(build.exitCode, 0, reason: '${build.stdout}\n${build.stderr}');
      final result = await Process.run(executable, []);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      expect(result.stdout,
          contains('native RSSI sampling: all behavior checks passed'));
    } finally {
      temporary.deleteSync(recursive: true);
    }
  }, skip: !Platform.isMacOS, timeout: const Timeout(Duration(minutes: 2)));
}

/// Extract the actual production body; the native harness supplies platform
/// types, not a second implementation of the logic under test.
String _method(String source, String declaration) {
  final start = source.indexOf(declaration);
  expect(start, greaterThanOrEqualTo(0));
  final body = source.indexOf('{', start);
  var depth = 1;
  var end = body + 1;
  while (depth > 0 && end < source.length) {
    if (source[end] == '{') depth++;
    if (source[end] == '}') depth--;
    end++;
  }
  expect(depth, 0);
  return source.substring(start, end);
}
