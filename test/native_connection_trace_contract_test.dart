import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Android connection trace is gated and attached to connect status', () {
    final manager =
        File('android/src/main/kotlin/com/fzfstudio/ezw_ble/ble/BleManager.kt')
            .readAsStringSync();
    final method = File(
      'android/src/main/kotlin/com/fzfstudio/ezw_ble/ble/BleMethodChannel.kt',
    ).readAsStringSync();
    final callback = File(
      'android/src/main/kotlin/com/fzfstudio/ezw_ble/ble/BleGattSessionCallback.kt',
    ).readAsStringSync();

    expect(method, contains('SET_CONNECTION_TRACE_ENABLED'));
    expect(method, contains('setConnectionTraceEnabled'));
    expect(manager, contains('private var connectionTraceEnabled = false'));
    expect(manager, contains('nativeConnectionTraces.clear()'));
    expect(manager, contains('startNativeTrace(endpointId)'));
    expect(manager, contains('.put("nativeTrace", it)'));
    expect(callback, contains('recordTraceStep(address, "connect", "success"'));
    expect(callback, contains('updateTraceRssi(device.uuid, rssi)'));
    expect(callback, contains('updateTracePhy(device.uuid, phyLabel(txPhy))'));
    expect(callback, contains('updateTraceRequestedPriority'));
  });

  test('iOS connection trace is gated and RSSI sampling is exact guarded', () {
    final manager = File('ios/Classes/ble/BleManager.swift').readAsStringSync();
    final method =
        File('ios/Classes/ble/BleMethodChannel.swift').readAsStringSync();
    final admission = File('ios/Classes/ble/BleConnectionAdmissionFlow.swift')
        .readAsStringSync();

    expect(method, contains('case setConnectionTraceEnabled'));
    expect(manager, contains('var connectionTraceEnabled = false'));
    expect(manager, contains('stopAllNativeTraceRssiSampling()'));
    expect(manager, contains('nativeConnectionTraces.removeAll()'));
    expect(admission, contains('startNativeTrace(endpointId: endpointId)'));
    expect(manager, contains('nativeTrace: nativeTraceSnapshot(uuid: uuid)'));
    expect(manager, contains('Timer.scheduledTimer(withTimeInterval: 2.0'));
    expect(manager, contains('Timer.scheduledTimer(withTimeInterval: 15.0'));
    expect(manager, contains('nativeTraceRssiInFlightAttemptIds[key] == nil'));
    expect(
      manager,
      contains('nativeTraceRssiInFlightAttemptIds[key] = expectedAttemptId'),
    );
    expect(manager, contains('trace.attemptId == expectedAttemptId'));
    expect(manager, contains('device.peripheral === peripheral'));
    expect(manager, contains('device.isConnected &&'));
    expect(manager, contains('device.isBleFlowCompleted'));
    expect(
      manager,
      contains(
        'currentConnectionAdmission(uuid: uuid) != nil || hasExactBusinessOwner',
      ),
    );
    expect(manager, contains('trace.attemptId == inFlightAttemptId'));
    expect(manager, contains('currentConnectionAdmission(uuid: uuid) != nil'));
    expect(manager, contains('peripheral.readRSSI()'));
    expect(manager, contains('didReadRSSI RSSI'));
    expect(manager, contains('result: "not_observable"'));
    expect(manager, contains('bondState: "not_observable"'));
    expect(
      RegExp(
        r'stage:\s*"bond"[\s\S]{0,160}result:\s*"success"',
      ).hasMatch(manager),
      isFalse,
      reason: 'CoreBluetooth must never claim an observable bond success',
    );
  });

  test('native trace result vocabulary stays parseable by even_connect', () {
    final nativeSources = <String>[
      File('android/src/main/kotlin/com/fzfstudio/ezw_ble/ble/BleManager.kt')
          .readAsStringSync(),
      File(
        'android/src/main/kotlin/com/fzfstudio/ezw_ble/ble/BleGattSessionCallback.kt',
      ).readAsStringSync(),
      File(
        'android/src/main/kotlin/com/fzfstudio/ezw_ble/ble/BleNativeConnectionTrace.kt',
      ).readAsStringSync(),
      File('ios/Classes/ble/BleManager.swift').readAsStringSync(),
      File('ios/Classes/ble/BleConnectionAdmissionFlow.swift')
          .readAsStringSync(),
      File('ios/Classes/ble/BleScanPipeline.swift').readAsStringSync(),
      File('ios/Classes/ble/BleNativeConnectionTrace.swift').readAsStringSync(),
    ].join('\n');
    final emittedResults = RegExp(
      r'(?:result[: =]\s*|recordTraceStep\([^,\n]+,\s*"[^"]+",\s*)"([a-z_]+)"',
    ).allMatches(nativeSources).map((match) => match.group(1)!).toSet();

    expect(emittedResults, isNot(contains('fail')));
    expect(emittedResults, isNot(contains('physical_success')));
    expect(emittedResults, isNot(contains('matched')));
    expect(emittedResults, isNot(contains('skipped')));
    expect(
      emittedResults.difference(<String>{
        'started',
        'success',
        'failed',
        'timeout',
        'cancelled',
        'expected',
        'abnormal',
        'not_observable',
        // Native-only bridge result; converted to the dedicated link-policy
        // event before even_connect parses normal stage results.
        'state_changed',
        'gap',
      }),
      isEmpty,
    );
  });
}
