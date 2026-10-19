import 'package:flutter/services.dart';
import 'package:flutter_ezw_ble/core/models/ble_cmd.dart';
import 'package:flutter_ezw_ble/core/models/ble_ota_window.dart';
import 'package:flutter_ezw_ble/core/models/ota_batch_metrics.dart';
import 'package:flutter_ezw_ble/flutter_ezw_ble_method_channel.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('flutter_ezw_ble');

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('measured OTA batch forwards otaWindow without changing packet bytes',
      () async {
    MethodCall? capturedCall;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      capturedCall = call;
      return <String, Object?>{
        'elapsedMs': 24,
        'packetCount': 2,
        'wireBytes': 5,
        'completionKind': 'gatt_write_callback',
      };
    });

    final firstPacket = Uint8List.fromList(<int>[0xAA, 0x12, 0x01]);
    final secondPacket = Uint8List.fromList(<int>[0xAA, 0x12]);
    final expectedAck = Uint8List.fromList(<int>[0xAA, 0x12, 0xC1, 0x00]);
    final metrics = await MethodChannelEzwBle().sendOtaPacketBatchMeasured(
      'left-uuid',
      <Uint8List>[firstPacket, secondPacket],
      expectedSessionGeneration: 0,
      expectedAttemptGeneration: 0,
      otaWindow: BleOtaWindow(
        windowId: 'tx:component:4096',
        expectedAck: expectedAck,
      ),
    );

    final arguments = capturedCall!.arguments as Map;
    final packets = arguments['packets'] as List;
    final otaWindow = arguments['otaWindow'] as Map;
    final bridgedAck = otaWindow['expectedAck'] as Uint8List;

    expect(capturedCall!.method, 'sendOtaPacketBatch');
    expect(packets[0], isA<Uint8List>());
    expect(packets[1], isA<Uint8List>());
    expect(packets[0] as Uint8List, orderedEquals(<int>[0xAA, 0x12, 0x01]));
    expect(packets[1] as Uint8List, orderedEquals(<int>[0xAA, 0x12]));
    expect(firstPacket, orderedEquals(<int>[0xAA, 0x12, 0x01]));
    expect(secondPacket, orderedEquals(<int>[0xAA, 0x12]));
    expect(arguments, containsPair('expectedSessionGeneration', 0));
    expect(arguments, containsPair('expectedAttemptGeneration', 0));
    expect(arguments, containsPair('metricsRequested', true));
    expect(otaWindow, containsPair('windowId', 'tx:component:4096'));
    expect(bridgedAck, orderedEquals(expectedAck));
    // The Dart bridge keeps the expected ACK immutable from caller mutation.
    expect(identical(bridgedAck, expectedAck), isFalse);
    expect(metrics?.elapsedMs, 24);
  });

  test('sendCmdNoWait piggybacks only explicit OTA window credit', () async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
    final control = Uint8List.fromList(<int>[0xC0, 0x14]);

    await MethodChannelEzwBle().sendCmdNoWait(
      'left-uuid',
      control,
      psType: 1,
      otaWindowCredit: const BleOtaWindowReceipt(
        windowId: 'tx:component:4096',
        receiptId: 'native-receipt-1',
      ),
    );
    await MethodChannelEzwBle().sendCmdNoWait(
      'left-uuid',
      control,
      psType: 1,
    );

    final credited = calls[0].arguments as Map;
    final uncredited = calls[1].arguments as Map;
    expect(credited['data'], isA<Uint8List>());
    expect(credited['data'] as Uint8List, orderedEquals(control));
    expect(
      credited['otaWindowCredit'],
      <String, Object>{
        'windowId': 'tx:component:4096',
        'receiptId': 'native-receipt-1',
      },
    );
    expect(uncredited.containsKey('otaWindowCredit'), isFalse);
  });

  test('BleCmd.receiveMap accepts only explicit valid bounded receipts', () {
    final valid = BleCmd.receiveMap(<String, Object?>{
      'uuid': 'left-uuid',
      'psType': 1,
      'data': Uint8List.fromList(<int>[0x01]),
      'isSuccess': true,
      'otaWindowReceipt': <String, Object>{
        'windowId': 'tx:component:4096',
        'receiptId': 'native-receipt-1',
      },
    });
    expect(valid.otaWindowReceipt?.windowId, 'tx:component:4096');
    expect(valid.otaWindowReceipt?.receiptId, 'native-receipt-1');

    final absent = BleCmd.receiveMap(<String, Object?>{
      'uuid': 'left-uuid',
      'psType': 1,
      'windowId': 'tx:component:4096',
      'receiptId': 'native-receipt-1',
    });
    final empty = BleCmd.receiveMap(<String, Object?>{
      'otaWindowReceipt': <String, Object>{
        'windowId': ' ',
        'receiptId': 'native-receipt-1',
      },
    });
    final overlong = BleCmd.receiveMap(<String, Object?>{
      'otaWindowReceipt': <String, Object>{
        'windowId': 'tx:component:4096',
        'receiptId': 'r' * 129,
      },
    });
    final malformed = BleCmd.receiveMap(<String, Object?>{
      'otaWindowReceipt': 'tx:component:4096',
    });

    expect(absent.otaWindowReceipt, isNull);
    expect(empty.otaWindowReceipt, isNull);
    expect(overlong.otaWindowReceipt, isNull);
    expect(malformed.otaWindowReceipt, isNull);
  });

  test('OtaBatchMetrics distinguishes unknown diagnostics from observed zero',
      () {
    final observedZero = OtaBatchMetrics.fromNative(<String, Object?>{
      'elapsedMs': 10,
      'packetCount': 1,
      'wireBytes': 3,
      'completionKind': 'android_submitted',
      'nativeQueueSoftThrottleWaitMs': 0,
      'nativeQueueRetryTimerLateMs': 0,
      'nativeQueuePollResumeCount': 0,
      'nativeQueueCallbackResumeCount': 0,
      'nativeAckToNextFileMs': 0,
      'nativeNotifyToCreditMs': 0,
    });
    final unknown = OtaBatchMetrics.fromNative(<String, Object?>{
      'elapsedMs': 10,
      'packetCount': 1,
      'wireBytes': 3,
      'completionKind': 'android_submitted',
    });

    expect(observedZero?.nativeQueueSoftThrottleWaitMs, 0);
    expect(observedZero?.nativeQueueRetryTimerLateMs, 0);
    expect(observedZero?.nativeQueuePollResumeCount, 0);
    expect(observedZero?.nativeQueueCallbackResumeCount, 0);
    expect(observedZero?.nativeAckToNextFileMs, 0);
    expect(observedZero?.nativeNotifyToCreditMs, 0);
    expect(unknown?.nativeQueueSoftThrottleWaitMs, isNull);
    expect(unknown?.nativeQueueRetryTimerLateMs, isNull);
    expect(unknown?.nativeQueuePollResumeCount, isNull);
    expect(unknown?.nativeQueueCallbackResumeCount, isNull);
    expect(unknown?.nativeAckToNextFileMs, isNull);
    expect(unknown?.nativeNotifyToCreditMs, isNull);
  });
}
