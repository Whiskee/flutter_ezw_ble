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
      expectedSessionGeneration: 37,
      expectedAttemptGeneration: 9,
    );

    expect(capturedCall?.method, 'sendCmd');
    expect(capturedCall?.arguments, containsPair('allowDuringUpgrade', true));
    expect(
      capturedCall?.arguments,
      containsPair('expectedSessionGeneration', 37),
    );
    expect(
      capturedCall?.arguments,
      containsPair('expectedAttemptGeneration', 9),
    );
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
    expect(
      capturedCall?.arguments,
      containsPair('expectedSessionGeneration', 0),
    );
    expect(
      capturedCall?.arguments,
      containsPair('expectedAttemptGeneration', 0),
    );
  });

  test('sendCmdNoWait forwards exact OTA session identity', () async {
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
      expectedSessionGeneration: 37,
      expectedAttemptGeneration: 9,
    );

    expect(capturedCall?.method, 'sendCmdNoWait');
    expect(
      capturedCall?.arguments,
      containsPair('expectedSessionGeneration', 37),
    );
    expect(
      capturedCall?.arguments,
      containsPair('expectedAttemptGeneration', 9),
    );
  });

  test('quiteUpgradeState forwards exact OTA session identity', () async {
    MethodCall? capturedCall;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (methodCall) async {
      capturedCall = methodCall;
      return null;
    });

    await MethodChannelEzwBle().quiteUpgradeState(
      'left-uuid',
      expectedSessionGeneration: 37,
      expectedAttemptGeneration: 9,
    );

    expect(capturedCall?.method, 'quiteUpgradeState');
    expect(capturedCall?.arguments, containsPair('uuid', 'left-uuid'));
    expect(
      capturedCall?.arguments,
      containsPair('expectedSessionGeneration', 37),
    );
    expect(
      capturedCall?.arguments,
      containsPair('expectedAttemptGeneration', 9),
    );
  });

  test('disconnectForOtaReboot forwards exact OTA session identity', () async {
    MethodCall? capturedCall;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (methodCall) async {
      capturedCall = methodCall;
      return null;
    });

    await MethodChannelEzwBle().disconnectForOtaReboot(
      'left-uuid',
      'Even G2 L',
      expectedSessionGeneration: 37,
      expectedAttemptGeneration: 9,
    );

    expect(capturedCall?.method, 'disconnectForOtaReboot');
    expect(capturedCall?.arguments, containsPair('uuid', 'left-uuid'));
    expect(capturedCall?.arguments, containsPair('name', 'Even G2 L'));
    expect(
      capturedCall?.arguments,
      containsPair('expectedSessionGeneration', 37),
    );
    expect(
      capturedCall?.arguments,
      containsPair('expectedAttemptGeneration', 9),
    );
  });

  test(
    'prepareBusinessConnection forwards exact attempt and decodes status',
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
    },
  );

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
