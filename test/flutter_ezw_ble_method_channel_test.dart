import 'package:flutter/services.dart';
import 'package:flutter_ezw_ble/core/models/ble_business_connection_attempt.dart';
import 'package:flutter_ezw_ble/core/models/ble_device.dart';
import 'package:flutter_ezw_ble/core/models/ble_g2_ota_transaction.dart';
import 'package:flutter_ezw_ble/core/models/ble_ota_recovery_disconnect_result.dart';
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

  test('G2 transaction bridge preserves frozen scope and explicit receipts',
      () async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return <String, Object?>{
        'transactionId': 'tx-10',
        'generation': 10,
        'instanceId': 'native-1',
        'status': call.method == 'finishG2OtaTransaction'
            ? 'committed'
            : call.method == 'queryG2OtaTransaction'
                ? 'alreadyCommitted'
                : 'accepted',
      };
    });
    final platform = MethodChannelEzwBle();
    const context = BleG2OtaContext(
      transactionId: 'tx-10',
      generation: 10,
      instanceId: 'native-1',
    );
    const endpoints = [
      BleG2OtaEndpointIdentity(
        uuid: 'left',
        name: 'Even G2 L',
        sessionGeneration: 8,
        attemptGeneration: 12,
      ),
      BleG2OtaEndpointIdentity(uuid: 'right', name: 'Even G2 R'),
    ];
    final began = await platform.beginG2OtaTransaction(
      transactionId: 'tx-10',
      generation: 10,
      config: 'G2',
      sn: 'frozen-sn',
      endpoints: endpoints,
    );
    final parked = await platform.updateG2OtaEndpoint(
      context: context,
      uuid: 'left',
      action: BleG2OtaEndpointAction.park,
      sessionGeneration: 8,
      attemptGeneration: 12,
    );
    final finished = await platform.finishG2OtaTransaction(
      transactionId: 'tx-10',
      generation: 10,
      instanceId: 'native-1',
      reason: 'success',
      config: 'G2',
      sn: 'frozen-sn',
      endpoints: endpoints,
    );
    final queried = await platform.queryG2OtaTransaction(
      transactionId: 'tx-10',
      generation: 10,
      instanceId: 'native-1',
    );

    expect(began.status, BleG2OtaTransactionStatus.accepted);
    expect(parked.status, BleG2OtaTransactionStatus.accepted);
    expect(finished.isRetired, isTrue);
    expect(queried.status, BleG2OtaTransactionStatus.alreadyCommitted);
    expect(calls.map((call) => call.method), [
      'beginG2OtaTransaction',
      'updateG2OtaEndpoint',
      'finishG2OtaTransaction',
      'queryG2OtaTransaction',
    ]);
    expect(calls[0].arguments, {
      'transactionId': 'tx-10',
      'generation': 10,
      'config': 'G2',
      'sn': 'frozen-sn',
      'endpoints': endpoints.map((endpoint) => endpoint.toJson()).toList(),
    });
    expect(calls[1].arguments, {
      ...context.toJson(),
      'uuid': 'left',
      'action': 'park',
      'sessionGeneration': 8,
      'attemptGeneration': 12,
    });
    expect(calls[2].arguments, {
      ...calls[0].arguments as Map,
      'instanceId': 'native-1',
      'reason': 'success',
    });
    expect(calls[3].arguments, context.toJson());
  });

  test('G2 transaction platform errors are not success receipts', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async {
      throw PlatformException(code: 'native_unavailable');
    });
    await expectLater(
      MethodChannelEzwBle().queryG2OtaTransaction(
        transactionId: 'tx-10',
        generation: 10,
        instanceId: 'native-1',
      ),
      throwsA(isA<PlatformException>()),
    );
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

  test('sendCmd forwards the native G2 OTA transaction context', () async {
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
      otaContext: const BleG2OtaContext(
        transactionId: 'tx-1',
        generation: 37,
        instanceId: 'native-1',
      ),
    );

    expect(capturedCall?.method, 'sendCmd');
    expect(
      capturedCall?.arguments,
      containsPair(
        'otaContext',
        containsPair('transactionId', 'tx-1'),
      ),
    );
    expect(
      capturedCall?.arguments['otaContext'],
      containsPair('generation', 37),
    );
    expect(
      capturedCall?.arguments['otaContext'],
      containsPair('instanceId', 'native-1'),
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

  test('sendCmdNoWait forwards the native G2 OTA transaction context',
      () async {
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
      otaContext: const BleG2OtaContext(
        transactionId: 'tx-1',
        generation: 37,
        instanceId: 'native-1',
      ),
    );

    expect(capturedCall?.method, 'sendCmdNoWait');
    expect(
      capturedCall?.arguments,
      containsPair(
        'otaContext',
        containsPair('transactionId', 'tx-1'),
      ),
    );
    expect(
      capturedCall?.arguments['otaContext'],
      containsPair('generation', 37),
    );
    expect(
      capturedCall?.arguments['otaContext'],
      containsPair('instanceId', 'native-1'),
    );
  });

  test('activateAutoReconnectTargets forwards optional OTA context', () async {
    MethodCall? capturedCall;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (methodCall) async {
      capturedCall = methodCall;
      return <Object?>[];
    });

    await MethodChannelEzwBle().activateAutoReconnectTargets(
      <BleDevice>[
        BleDevice('cfg', 'left-uuid', 'Even G2 L', 'sn', -40),
      ],
      otaContext: const BleG2OtaContext(
        transactionId: 'tx-1',
        generation: 37,
        instanceId: 'native-1',
      ),
    );

    expect(capturedCall?.method, 'activateAutoReconnectTargets');
    expect(
      capturedCall?.arguments,
      containsPair(
        'otaContext',
        containsPair('transactionId', 'tx-1'),
      ),
    );
    expect(
      capturedCall?.arguments['otaContext'],
      containsPair('generation', 37),
    );
    expect(
      capturedCall?.arguments['otaContext'],
      containsPair('instanceId', 'native-1'),
    );
  });

  test('G2 OTA transaction methods fail closed on missing native status',
      () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (methodCall) async => null);

    final result = await MethodChannelEzwBle().finishG2OtaTransaction(
      transactionId: 'tx-1',
      generation: 37,
      instanceId: 'native-1',
      reason: 'success',
      config: 'cfg',
      sn: 'sn',
      endpoints: const <BleG2OtaEndpointIdentity>[
        BleG2OtaEndpointIdentity(uuid: 'left-uuid', name: 'Even G2 L'),
      ],
    );

    expect(result.status, BleG2OtaTransactionStatus.unknown);
    expect(result.isRetired, isFalse);
  });

  test('G2 OTA transaction parser rejects malformed success identities',
      () async {
    final emptyIdentity = BleG2OtaTransactionResult.fromNative(
      const <String, Object?>{
        'status': 'committed',
        'transactionId': '',
        'generation': 37,
        'instanceId': 'native-1',
      },
    );
    final fractionalGeneration = BleG2OtaTransactionResult.fromNative(
      const <String, Object?>{
        'status': 'accepted',
        'transactionId': 'tx-1',
        'generation': 37.5,
        'instanceId': 'native-1',
      },
    );

    expect(emptyIdentity.status, BleG2OtaTransactionStatus.unknown);
    expect(fractionalGeneration.status, BleG2OtaTransactionStatus.unknown);
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
    'disconnectForOtaRecovery returns native exact teardown status',
    () async {
      MethodCall? capturedCall;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (methodCall) async {
        capturedCall = methodCall;
        return 'accepted';
      });

      final status = await MethodChannelEzwBle().disconnectForOtaRecovery(
        'left-uuid',
        expectedSessionGeneration: 37,
        expectedAttemptGeneration: 9,
        otaContext: const BleG2OtaContext(
          transactionId: 'tx-stall',
          generation: 11,
          instanceId: 'native-stall',
        ),
      );

      expect(status, BleOtaRecoveryDisconnectResult.accepted);
      expect(capturedCall?.method, 'disconnectForOtaRecovery');
      expect(capturedCall?.arguments, containsPair('uuid', 'left-uuid'));
      expect(
        capturedCall?.arguments,
        containsPair('expectedSessionGeneration', 37),
      );
      expect(
        capturedCall?.arguments,
        containsPair('expectedAttemptGeneration', 9),
      );
      expect(
        capturedCall?.arguments['otaContext'],
        containsPair('transactionId', 'tx-stall'),
      );
      expect(
        capturedCall?.arguments['otaContext'],
        containsPair('generation', 11),
      );
      expect(
        capturedCall?.arguments['otaContext'],
        containsPair('instanceId', 'native-stall'),
      );
    },
  );

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
