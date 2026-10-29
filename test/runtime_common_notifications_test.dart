import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_ezw_ble/core/models/ble_cmd.dart';
import 'package:flutter_ezw_ble/flutter_ezw_ble.dart';
import 'package:flutter_ezw_ble/flutter_ezw_ble_method_channel.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('flutter_ezw_ble');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('runtime common bridge preserves exact pair and typed write rejection',
      () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'getRuntimeCommonOwner') {
        return {'uuid': 'ring', 'sessionGeneration': 3, 'attemptGeneration': 4};
      }
      if (call.method == 'sendCmd' || call.method == 'sendCmdNoWait') {
        throw PlatformException(code: 'COMMON_NOT_READY');
      }
      return {'status': 'confirmed', 'enabled': false, 'revision': 9};
    });
    final ble = MethodChannelEzwBle();
    final owner = await ble.getRuntimeCommonOwner('ring');
    expect(owner?.sessionGeneration, 3);
    expect(owner?.attemptGeneration, 4);
    final result = await ble.setRuntimeCommonNotifications('ring',
        sessionGeneration: 3,
        attemptGeneration: 4,
        revision: 9,
        enabled: false);
    expect(result.isConfirmed, isTrue);
    expect(result.enabled, isFalse);
    expect(calls.last.arguments, {
      'uuid': 'ring',
      'sessionGeneration': 3,
      'attemptGeneration': 4,
      'revision': 9,
      'enabled': false,
    });
    await ble.disconnectForRuntimeNotificationRecovery('ring',
        sessionGeneration: 3, attemptGeneration: 4, revision: 9);
    expect(calls.last.arguments, {
      'uuid': 'ring',
      'sessionGeneration': 3,
      'attemptGeneration': 4,
      'revision': 9,
    });
    for (final send in [ble.sendCmd, ble.sendCmdNoWait]) {
      await expectLater(
          send('ring', Uint8List(1)),
          throwsA(isA<PlatformException>()
              .having((e) => e.code, 'code', 'COMMON_NOT_READY')));
    }
  });

  test('common observation owner cannot enable strict receive ownership', () {
    final common = BleCmd.receiveMap({
      'uuid': 'ring',
      'psType': 0,
      'sessionGeneration': 3,
      'attemptGeneration': 4
    });
    expect(common.runtimeCommonOwner?.attemptGeneration, 4);
    expect(common.receiveIdentity, isNull);
    expect(
        BleCmd('ring', 1, sessionGeneration: 3, attemptGeneration: 4)
            .runtimeCommonOwner,
        isNull);
    expect(BleCmd('ring', 0).runtimeCommonOwner, isNull);
  });

  test('unknown native result and missing/zero pair fail closed', () {
    expect(
        BleRuntimeCommonOwner.fromNative(
            {'uuid': 'ring', 'sessionGeneration': 3, 'attemptGeneration': 0}),
        isNull);
    expect(BleRuntimeCommonResult.fromNative(null).status,
        BleRuntimeCommonStatus.unavailable);
    expect(BleRuntimeCommonResult.fromNative({'status': 'future'}).isConfirmed,
        isFalse);
  });

  test('optimized production runtime lane serializes physical CCCD callbacks',
      () async {
    final temporary = Directory.systemTemp.createTempSync('ezw-common-lane-');
    try {
      final executable = '${temporary.path}/runtime-common-tests';
      final build = await Process.run('xcrun', [
        'swiftc',
        '-O',
        'ios/Classes/ble/BleRuntimeCommonNotifications.swift',
        'test/native/runtime_common_notifications_test.swift',
        '-o',
        executable,
      ]);
      expect(build.exitCode, 0, reason: '${build.stdout}\n${build.stderr}');
      final result = await Process.run(executable, []);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      expect(result.stdout, contains('all behavior checks passed'));
    } finally {
      temporary.deleteSync(recursive: true);
    }
  }, skip: !Platform.isMacOS, timeout: const Timeout(Duration(minutes: 2)));
  test(
      'production native manager uses exact owners and rejects actual common writes',
      () async {
    final temporary =
        Directory.systemTemp.createTempSync('ezw-common-manager-');
    try {
      final source =
          File('ios/Classes/ble/BleManager.swift').readAsStringSync();
      final extension =
          File('ios/Classes/ble/BleRuntimeCommonCoordinator.swift')
              .readAsStringSync()
              .replaceAll('import CoreBluetooth', '')
              .replaceAll('import Flutter', 'import Foundation');
      final queue = File('${temporary.path}/OtaWriteQueue.swift');
      queue.writeAsStringSync(File('ios/Classes/ble/OtaWriteQueue.swift')
          .readAsStringSync()
          .replaceFirst('import Flutter', ''));
      final reconnectSource =
          File('ios/Classes/ble/BleAutoReconnectCoordinator.swift')
              .readAsStringSync();
      final channelSource =
          File('ios/Classes/ble/BleMethodChannel.swift').readAsStringSync();
      final sendCaseStart = channelSource.indexOf('        case .sendCmd:');
      final sendCaseEnd =
          channelSource.indexOf('        case .sendCmdNoWait:', sendCaseStart);
      expect(sendCaseStart, greaterThanOrEqualTo(0));
      expect(sendCaseEnd, greaterThan(sendCaseStart));
      final sendCase = channelSource.substring(
          sendCaseStart + '        case .sendCmd:'.length, sendCaseEnd);
      final methods = File('${temporary.path}/ManagerMethods.swift');
      methods.writeAsStringSync('''
import Foundation
final class BleManager {
  static let shared = BleManager()
  let runtimeCommonNotifications = BleRuntimeCommonNotifications()
  let upgradeStateRegistry = UpgradeRegistry()
  let g2OtaTransactions = OtaTransactions()
  let centralManager = Central()
  var connectedDevices: [BleConnectedDevice] = []
  var bleConfigs: [Config] = []
  var reconnectTasks: [String: Task] = [:]
  var admission: Admission?
  var peripheralConnectionSessions: [String: ConnectionSession] = [:]
  var otaWriteQueues: [String: OtaWriteQueue] = [:]
  var callable = true
  var cancellationBarrier = false
  func checkIsFunctionCanBeCalled() -> Bool { callable }
  func hasPeripheralCancellationBarrier(_ peripheral: CBPeripheral) -> Bool { cancellationBarrier }
  func currentConnectionAdmission(uuid: String) -> Admission? { admission }
  func isCurrentConnectionPipeline(_ peripheral: CBPeripheral) -> Bool {
    guard let admission = currentConnectionAdmission(uuid: peripheral.identifier.uuidString),
          let session = peripheralConnectionSessions[admission.sessionId] else { return false }
    return session.peripheral === peripheral
  }
  func recordBondSecurityFailureIfNeeded(peripheral: CBPeripheral, error: NSError) {}
  func loggerD(msg: String) {}
  func loggerE(msg: String) {}
  func validateOtaWriteIdentity(uuid: String, device: BleConnectedDevice,
      expectedSessionGeneration: Int64, expectedAttemptGeneration: Int64,
      otaContext: BleG2OtaContext?) -> FlutterError? { nil }
  func dispatchSendCmd(_ arguments: Any?, result: @escaping FlutterResult) {
$sendCase
  }
${_method(source, '    func sendCmd(')}
${_method(source, '    private func receiveDataIdentity(')}
${_method(source, '    private func otaResponseIdentity(')}
${_method(source, '    private func otaWindowCreditOwner(')}
${_method(source, '    private func wwrDiagnostics(')}
${_method(reconnectSource, '    func isSameConnectTarget(')}
${_method(source, '    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor')}
}
$extension
''');
      final commandModel = File('${temporary.path}/BleCmd.swift');
      final commandSource =
          File('ios/Classes/ble/models/BleCmd.swift').readAsStringSync();
      commandModel.writeAsStringSync('import Foundation\n$commandSource');
      final executable = '${temporary.path}/runtime-manager-tests';
      final build = await Process.run('xcrun', [
        'swiftc',
        '-O',
        'ios/Classes/ble/BleRuntimeCommonNotifications.swift',
        'ios/Classes/ble/BleBusinessConnectionAttempt.swift',
        'ios/Classes/ble/BleReceiveIdentityPolicy.swift',
        'ios/Classes/ble/BleDebugLogPolicy.swift',
        'ios/Classes/ble/OtaWindowCreditLedger.swift',
        queue.path,
        methods.path,
        commandModel.path,
        'test/native/runtime_common_manager_test.swift',
        '-o',
        executable,
      ]);
      expect(build.exitCode, 0, reason: '${build.stdout}\n${build.stderr}');
      final result = await Process.run(executable, []);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      expect(result.stdout, contains('all behavior checks passed'));
    } finally {
      temporary.deleteSync(recursive: true);
    }
  }, skip: !Platform.isMacOS, timeout: const Timeout(Duration(minutes: 2)));
}

/// Compile the real method body with platform boundaries replaced in the harness.
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
