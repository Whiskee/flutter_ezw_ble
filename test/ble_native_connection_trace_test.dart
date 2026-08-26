import 'dart:convert';
import 'dart:io';

import 'package:flutter_ezw_ble/core/models/ble_connect_model.dart';
import 'package:flutter_ezw_ble/core/models/ble_connect_state.dart';
import 'package:flutter_ezw_ble/core/models/ble_native_connection_trace.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('connect model decodes old payload without nativeTrace', () {
    final model = BleConnectModel.fromJson(<String, dynamic>{
      'uuid': 'AA:BB',
      'name': 'Even',
      'connectState': 'connecting',
      'generation': 7,
    });

    expect(model.connectState, BleConnectState.connecting);
    expect(model.sessionGeneration, 7);
    expect(model.nativeTrace, isNull);
  });

  test('connect model round-trips native trace snapshot', () {
    const trace = BleNativeConnectionTrace(
      attemptId: 'attempt-1',
      capturedElapsedMs: 45,
      lastRssiDbm: -72,
      rssiAgeMs: 1200,
      phy: '1M',
      requestedPriority: 'HIGH',
      steps: <BleNativeConnectionTraceStep>[
        BleNativeConnectionTraceStep(
          stepSeq: 1,
          stage: 'attempt',
          result: 'started',
          elapsedMs: 0,
        ),
        BleNativeConnectionTraceStep(
          stepSeq: 2,
          stage: 'bond',
          result: 'not_observable',
          elapsedMs: 31,
          bondState: 'not_observable',
          writeLimitBytes: 244,
          linkTrigger: 'platform_capability',
          priorityAction: 'unsupported',
          actionResult: 'not_applicable',
        ),
      ],
    );
    final model = BleConnectModel(
      'AA:BB',
      'Even',
      BleConnectState.connectFinish,
      nativeTrace: trace,
    );

    final decoded = BleConnectModel.fromJson(
      jsonDecode(jsonEncode(model.toJson())) as Map<String, dynamic>,
    );

    expect(decoded.nativeTrace?.attemptId, 'attempt-1');
    expect(decoded.nativeTrace?.capturedElapsedMs, 45);
    expect(decoded.nativeTrace?.lastRssiDbm, -72);
    expect(decoded.nativeTrace?.steps.map((step) => step.stepSeq), [1, 2]);
    expect(decoded.nativeTrace?.steps.last.bondState, 'not_observable');
    expect(decoded.nativeTrace?.steps.last.writeLimitBytes, 244);
    expect(decoded.nativeTrace?.steps.last.priorityAction, 'unsupported');
  });

  test('native trace source contracts preserve monotonic bounded snapshots',
      () {
    final androidTrace = File(
      'android/src/main/kotlin/com/fzfstudio/ezw_ble/ble/BleNativeConnectionTrace.kt',
    ).readAsStringSync();
    final iosTrace = File('ios/Classes/ble/BleNativeConnectionTrace.swift')
        .readAsStringSync();

    expect(androidTrace, contains('const val MAX_STEPS = 32'));
    expect(androidTrace,
        contains('steps.forEach { step -> array.put(step.toJson()) }'));
    expect(androidTrace, contains('stepSeq = step.stepSeq'));
    expect(androidTrace, contains('step.copy(stepSeq = nextStepSeq++)'));
    expect(androidTrace, isNot(contains('normalizedStepSeq')));
    expect(androidTrace, contains('stage = "trace"'));
    expect(androidTrace, contains('result = "gap"'));
    expect(androidTrace, contains('droppedCount = droppedCount'));
    expect(iosTrace, contains('static let maxSteps = 32'));
    expect(iosTrace, contains('steps: steps'));
    expect(iosTrace, contains('stepSeq: step.stepSeq'));
    expect(iosTrace, contains('terminal.stepSeq = nextStepSeq'));
    expect(iosTrace, isNot(contains('normalized.stepSeq')));
    expect(iosTrace, contains('stage: "trace"'));
    expect(iosTrace, contains('result: "gap"'));
    expect(iosTrace, contains('droppedCount: droppedCount'));
  });
}
