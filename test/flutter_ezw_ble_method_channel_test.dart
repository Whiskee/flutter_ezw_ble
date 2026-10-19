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

  test(
      'startScan forwards optional iOS service filtering without changing defaults',
      () async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (methodCall) async {
      calls.add(methodCall);
      return const <String, Object?>{
        'started': true,
        'generation': 7,
        'reason': 'started',
      };
    });

    final platform = MethodChannelEzwBle();
    await platform.startScan();
    await platform.startScan(
      turnOnPureModel: true,
      iosServiceUuids: const ['', 'fe59', 'FE59', '180F'],
      includeUnfilteredScan: false,
      includeNormalScanResults: true,
      includeUnfilteredPureScanResults: false,
    );

    expect(calls.map((call) => call.method), ['startScan', 'startScan']);
    expect(calls[0].arguments, {
      'turnOnPureModel': false,
      'iosServiceUuids': <String>[],
      'includeUnfilteredScan': true,
      'includeNormalScanResults': false,
      'includeUnfilteredPureScanResults': true,
    });
    expect(calls[1].arguments, {
      'turnOnPureModel': true,
      'iosServiceUuids': ['', 'fe59', 'FE59', '180F'],
      'includeUnfilteredScan': false,
      'includeNormalScanResults': true,
      'includeUnfilteredPureScanResults': false,
    });
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
    await MethodChannelEzwBle().sendOtaPacketBatch(
      'left-uuid',
      packets,
      expectedSessionGeneration: 37,
      expectedAttemptGeneration: 9,
    );

    expect(capturedCall?.method, 'sendOtaPacketBatch');
    expect(capturedCall?.arguments, containsPair('uuid', 'left-uuid'));
    expect(capturedCall?.arguments, containsPair('psType', 1));
    expect(capturedCall?.arguments, containsPair('packets', packets));
    expect(
        capturedCall?.arguments, containsPair('expectedSessionGeneration', 37));
    expect(
        capturedCall?.arguments, containsPair('expectedAttemptGeneration', 9));
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

  test('measured OTA batch requests one native result without changing bytes',
      () async {
    MethodCall? capturedCall;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      capturedCall = call;
      return <String, Object?>{
        'elapsedMs': 12,
        'packetCount': 2,
        'wireBytes': 4,
        'completionKind': 'corebluetooth_submitted',
        'writeLimitBytes': 244,
        'mtu': 247,
        'requestedPhy': '2M',
        'actualPhy': '1M',
        'lastRssiDbm': -58,
        'rssiAgeMs': 420,
        'nativeQueueBackpressureCount': 3,
        'nativeQueueBackpressureWaitMs': 150,
        'nativeQueueSoftThrottleCount': 1,
      };
    });
    final packets = <Uint8List>[
      Uint8List.fromList(<int>[1, 2]),
      Uint8List.fromList(<int>[3, 4]),
    ];
    final metrics = await MethodChannelEzwBle().sendOtaPacketBatchMeasured(
      'left-uuid',
      packets,
      expectedSessionGeneration: 37,
      expectedAttemptGeneration: 9,
    );
    expect(capturedCall?.arguments, containsPair('packets', packets));
    expect(capturedCall?.arguments, containsPair('metricsRequested', true));
    expect(metrics?.elapsedMs, 12);
    expect(metrics?.completionKind, 'corebluetooth_submitted');
    expect(metrics?.writeLimitBytes, 244);
    expect(metrics?.mtu, 247);
    expect(metrics?.requestedPhy, '2M');
    expect(metrics?.actualPhy, '1M');
    expect(metrics?.lastRssiDbm, -58);
    expect(metrics?.rssiAgeMs, 420);
    expect(metrics?.nativeQueueBackpressureCount, 3);
    expect(metrics?.nativeQueueBackpressureWaitMs, 150);
    expect(metrics?.nativeQueueSoftThrottleCount, 1);
  });

  test('measured OTA batch keeps missing diagnostic fields unknown', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      return <String, Object?>{
        'elapsedMs': 12,
        'packetCount': 2,
        'wireBytes': 4,
        'completionKind': 'gatt_write_callback',
      };
    });

    final metrics = await MethodChannelEzwBle().sendOtaPacketBatchMeasured(
      'left-uuid',
      <Uint8List>[
        Uint8List.fromList(<int>[1, 2]),
        Uint8List.fromList(<int>[3, 4]),
      ],
    );

    expect(metrics?.writeLimitBytes, isNull);
    expect(metrics?.mtu, isNull);
    expect(metrics?.requestedPhy, isNull);
    expect(metrics?.actualPhy, isNull);
    expect(metrics?.lastRssiDbm, isNull);
    expect(metrics?.rssiAgeMs, isNull);
    expect(metrics?.nativeQueueBackpressureCount, isNull);
    expect(metrics?.nativeQueueBackpressureWaitMs, isNull);
    expect(metrics?.nativeQueueSoftThrottleCount, isNull);
  });

  test('sendFilePacketBatch forwards framed packets on the file channel',
      () async {
    MethodCall? capturedCall;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (methodCall) async {
      capturedCall = methodCall;
      return null;
    });

    final packets = <Uint8List>[
      Uint8List.fromList(<int>[0x03]),
      Uint8List.fromList(<int>[0x04]),
    ];
    await MethodChannelEzwBle().sendFilePacketBatch('left-uuid', packets);

    expect(capturedCall?.method, 'sendFilePacketBatch');
    expect(capturedCall?.arguments, containsPair('uuid', 'left-uuid'));
    expect(capturedCall?.arguments, containsPair('psType', 3));
    expect(capturedCall?.arguments, containsPair('packets', packets));
  });

  test('sendFilePacketBatch rejects an empty packet list before native', () {
    expect(
      () => MethodChannelEzwBle().sendFilePacketBatch(
        'left-uuid',
        const <Uint8List>[],
      ),
      throwsArgumentError,
    );
  });

  test('sendFilePacketBatch refuses to borrow the OTA channel', () {
    // 文件批次绝不能落进 OTA 队列：quiteUpgradeState 会取消整条 OTA attempt，
    // 借道会让一次退出升级顺手打断正在进行的文件传输。
    expect(
      () => MethodChannelEzwBle().sendFilePacketBatch(
        'left-uuid',
        <Uint8List>[
          Uint8List.fromList(<int>[0x05])
        ],
        psType: 1,
      ),
      throwsArgumentError,
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

  test('business commit preserves exact identity and defaults native arming on',
      () async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (methodCall) async {
      calls.add(methodCall);
      return 'accepted';
    });
    const attempt = BleBusinessConnectionAttempt(
      uuid: 'temp-left',
      sessionGeneration: 51,
      attemptGeneration: 7,
    );

    // The Android opt-out must travel with the same exact AUTH commit, avoiding
    // a separate disarm call that could race a disconnect or a newer owner.
    await MethodChannelEzwBle().commitBusinessConnection(attempt);
    await MethodChannelEzwBle().commitBusinessConnection(
      attempt,
      armAutoReconnect: false,
    );

    expect(calls.map((call) => call.method),
        everyElement('commitBusinessConnection'));
    expect(calls[0].arguments, {...attempt.toJson(), 'armAutoReconnect': true});
    expect(
        calls[1].arguments, {...attempt.toJson(), 'armAutoReconnect': false});
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

  test('invalidateBusinessConnection forwards exact attempt', () async {
    MethodCall? capturedCall;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (methodCall) async {
      capturedCall = methodCall;
      return true;
    });

    final invalidated =
        await MethodChannelEzwBle().invalidateBusinessConnection(
      const BleBusinessConnectionAttempt(
        uuid: 'left-uuid',
        sessionGeneration: 51,
        attemptGeneration: 13,
      ),
    );

    expect(capturedCall?.method, 'invalidateBusinessConnection');
    expect(capturedCall?.arguments, containsPair('uuid', 'left-uuid'));
    expect(capturedCall?.arguments, containsPair('sessionGeneration', 51));
    expect(capturedCall?.arguments, containsPair('attemptGeneration', 13));
    expect(invalidated, isTrue);
  });

  // test('getPlatformVersion', () async {
  //   expect(await platform.getPlatformVersion(), '42');
  // });
}
