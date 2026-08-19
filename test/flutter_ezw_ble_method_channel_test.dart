import 'package:flutter/services.dart';
import 'package:flutter_ezw_ble/core/models/ble_business_connection_attempt.dart';
import 'package:flutter_ezw_ble/flutter_ezw_ble_method_channel.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // MethodChannelEzwBle platform = MethodChannelEzwBle();
  const MethodChannel channel = MethodChannel('flutter_ezw_ble');

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
      return '42';
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('sendCmd forwards the explicit OTA control bypass flag', () async {
    MethodCall? capturedCall;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (methodCall) async {
      capturedCall = methodCall;
      return null;
    });

    await MethodChannelEzwBle().sendCmd(
      'left-uuid',
      Uint8List.fromList(<int>[0xAA]),
      allowDuringUpgrade: true,
    );

    expect(capturedCall?.method, 'sendCmd');
    expect(capturedCall?.arguments, containsPair('allowDuringUpgrade', true));
  });

  test('sendCmdNoWait always forwards to the native no-wait method', () async {
    MethodCall? capturedCall;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (methodCall) async {
      capturedCall = methodCall;
      return null;
    });

    await MethodChannelEzwBle().sendCmdNoWait(
      'left-uuid',
      Uint8List.fromList(<int>[0xBB]),
      psType: 1,
    );

    expect(capturedCall?.method, 'sendCmdNoWait');
    expect(capturedCall?.arguments, containsPair('uuid', 'left-uuid'));
    expect(capturedCall?.arguments, containsPair('psType', 1));
  });

  test('sendOtaPacketBatch forwards framed packets in one MethodChannel call',
      () async {
    MethodCall? capturedCall;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (methodCall) async {
      capturedCall = methodCall;
      return null;
    });

    final packets = <Uint8List>[
      Uint8List.fromList(<int>[0x01]),
      Uint8List.fromList(<int>[0x02]),
    ];
    await MethodChannelEzwBle().sendOtaPacketBatch('left-uuid', packets);

    expect(capturedCall?.method, 'sendOtaPacketBatch');
    expect(capturedCall?.arguments, containsPair('uuid', 'left-uuid'));
    expect(capturedCall?.arguments, containsPair('psType', 1));
    expect(capturedCall?.arguments, containsPair('packets', packets));
  });

  test('sendOtaPacketBatch rejects an empty packet list before native', () {
    expect(
      () => MethodChannelEzwBle().sendOtaPacketBatch(
        'left-uuid',
        const <Uint8List>[],
      ),
      throwsArgumentError,
    );
  });

  test('prepareBusinessConnection forwards exact attempt and decodes status',
      () async {
    MethodCall? capturedCall;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (methodCall) async {
      capturedCall = methodCall;
      return 'accepted';
    });

    final status = await MethodChannelEzwBle().prepareBusinessConnection(
      const BleBusinessConnectionAttempt(
        uuid: 'left-uuid',
        sessionGeneration: 37,
        attemptGeneration: 9,
      ),
    );

    expect(capturedCall?.method, 'prepareBusinessConnection');
    expect(capturedCall?.arguments, containsPair('uuid', 'left-uuid'));
    expect(capturedCall?.arguments, containsPair('sessionGeneration', 37));
    expect(capturedCall?.arguments, containsPair('attemptGeneration', 9));
    expect(status, BleBusinessConnectionStatus.accepted);
  });

  test('commitBusinessConnection decodes attempt mismatch', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (methodCall) async {
      expect(methodCall.method, 'commitBusinessConnection');
      return 'attemptMismatch';
    });

    final status = await MethodChannelEzwBle().commitBusinessConnection(
      const BleBusinessConnectionAttempt(
        uuid: 'left-uuid',
        sessionGeneration: 37,
        attemptGeneration: 8,
      ),
    );

    expect(status, BleBusinessConnectionStatus.attemptMismatch);
  });

  test('abortBusinessConnection returns native boolean', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (methodCall) async {
      expect(methodCall.method, 'abortBusinessConnection');
      return true;
    });

    final aborted = await MethodChannelEzwBle().abortBusinessConnection(
      const BleBusinessConnectionAttempt(
        uuid: 'left-uuid',
        sessionGeneration: 37,
        attemptGeneration: 8,
      ),
    );

    expect(aborted, isTrue);
  });

  // test('getPlatformVersion', () async {
  //   expect(await platform.getPlatformVersion(), '42');
  // });
}
