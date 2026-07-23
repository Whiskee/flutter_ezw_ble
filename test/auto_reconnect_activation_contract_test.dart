import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_ezw_ble/core/models/ble_connect_model.dart';
import 'package:flutter_ezw_ble/core/models/ble_connect_source.dart';
import 'package:flutter_ezw_ble/core/models/ble_connect_state.dart';
import 'package:flutter_ezw_ble/core/models/ble_device.dart';
import 'package:flutter_ezw_ble/core/models/ble_reconnect_activation_result.dart';
import 'package:flutter_ezw_ble/flutter_ezw_ble.dart';
import 'package:flutter_ezw_ble/flutter_ezw_ble_method_channel.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(ezwBleTag);
  final platform = MethodChannelEzwBle();

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('BleConnectModel keeps unknown source for old native payloads', () {
    final model = BleConnectModel.fromJson({
      'uuid': 'AA:BB:CC:DD:EE:FF',
      'name': 'Even G2',
      'connectState': 'contactDevice',
      'mtu': 247,
    });

    expect(model.source, BleConnectSource.unknown);
    expect(model.generation, 0);
    expect(model.toJson()['source'], 'unknown');
    expect(model.toJson()['generation'], 0);
  });

  test('BleConnectModel tolerates null and future native source values', () {
    for (final source in <Object?>[null, 'futureReconnect', 'AUTORECONNECT']) {
      final model = BleConnectModel.fromJson({
        'uuid': 'AA:BB:CC:DD:EE:FF',
        'name': 'Even G2',
        'connectState': 'contactDevice',
        'source': source,
      });

      expect(model.source, BleConnectSource.unknown);
    }
  });

  test('BleConnectModel round-trips every public connection source', () {
    for (final source in BleConnectSource.values) {
      final model = BleConnectModel(
        'device-1',
        'Even G2',
        BleConnectState.contactDevice,
        source: source,
      );

      expect(BleConnectModel.fromJson(model.toJson()).source, source);
    }
  });

  test('BleConnectModel round-trips session and attempt generations', () {
    final model = BleConnectModel(
      'device-1',
      'Even G2',
      BleConnectState.contactDevice,
      sessionGeneration: 42,
      attemptGeneration: 7,
    );

    expect(model.toJson()['generation'], 42);
    expect(model.toJson()['attemptGeneration'], 7);
    final decoded = BleConnectModel.fromJson(model.toJson());
    expect(decoded.generation, 42);
    expect(decoded.sessionGeneration, 42);
    expect(decoded.attemptGeneration, 7);
  });

  test('BleConnectModel treats legacy generation as session generation', () {
    final model = BleConnectModel.fromJson({
      'uuid': 'device-1',
      'name': 'Even G2',
      'connectState': 'contactDevice',
      'generation': 42,
      'attemptGeneration': 7,
    });

    expect(model.generation, 42);
    expect(model.sessionGeneration, 42);
    expect(model.attemptGeneration, 7);
  });

  test('activateAutoReconnectTargets sends targets and defaults source',
      () async {
    MethodCall? captured;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      captured = call;
      return null;
    });

    await platform.activateAutoReconnectTargets([
      BleDevice('g2', 'AA:BB', 'Even G2', 'SN-1', -50),
    ]);

    expect(captured?.method, 'activateAutoReconnectTargets');
    final arguments = captured?.arguments as Map<Object?, Object?>;
    expect(arguments['source'], 'autoReconnect');
    expect(arguments['devices'], isA<List<Object?>>());
    expect(
      (arguments['devices'] as List<Object?>).single,
      containsPair('uuid', 'AA:BB'),
    );
  });

  test('activateAutoReconnectTargets preserves an explicit manual source',
      () async {
    MethodCall? captured;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      captured = call;
      return null;
    });

    await platform.activateAutoReconnectTargets(
      [BleDevice('ring', '11:22', 'Even R1', 'R1-1', -42)],
      source: BleConnectSource.manualReconnect,
      sessionGeneration: 37,
    );

    final arguments = captured?.arguments as Map<Object?, Object?>;
    expect(arguments['source'], 'manualReconnect');
    expect(arguments['sessionGeneration'], 37);
  });

  test('removed userRepairRequired acknowledgement fails closed', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async {
      return [
        {
          'belongConfig': 'ring_bcl_1',
          'uuid': 'ring-uuid',
          'name': 'EVEN R1_2639B0',
          'state': 'userRepairRequired',
          'reason': 'peerPairingInformationRemoved',
          'source': 'manualReconnect',
          'sessionGeneration': 37,
        },
      ];
    });

    final results = await platform.activateAutoReconnectTargets(
      [BleDevice('ring_bcl_1', 'ring-uuid', 'EVEN R1_2639B0', 'R1', -50)],
      source: BleConnectSource.manualReconnect,
      sessionGeneration: 37,
    );

    expect(results.single.state, BleReconnectActivationState.rejected);
    expect(results.single.isAccepted, isFalse);
    expect(results.single.source, BleConnectSource.manualReconnect);
    expect(results.single.sessionGeneration, 37);
  });

  test('target visible hint uses named uuid and name arguments', () async {
    MethodCall? captured;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      captured = call;
      return true;
    });

    final accepted = await platform.notifyAutoReconnectTargetVisible(
      uuid: 'AA:BB:CC:DD:EE:FF',
      name: 'Even G2_32_L_ABCDEF',
    );

    expect(accepted, isTrue);
    expect(captured?.method, 'notifyAutoReconnectTargetVisible');
    expect(captured?.arguments, {
      'uuid': 'AA:BB:CC:DD:EE:FF',
      'name': 'Even G2_32_L_ABCDEF',
    });
  });

  test('batch cancellation preserves exact targets and removal intent',
      () async {
    MethodCall? captured;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      captured = call;
      return null;
    });

    await platform.cancelAutoReconnectTargets(
      [
        BleDevice('g2', 'AA:01', 'Even G2_L', 'G2-1', -50),
        BleDevice('g2', 'AA:02', 'Even G2_R', 'G2-1', -50),
      ],
      removeBond: true,
      reason: 'remove device G2-1',
    );

    expect(captured?.method, 'cancelAutoReconnectTargets');
    final arguments = captured?.arguments as Map<Object?, Object?>;
    expect(arguments['removeBond'], isTrue);
    expect(arguments['reason'], 'remove device G2-1');
    expect(arguments['devices'], hasLength(2));
  });

  test('native batch cancellation invalidates Gate before endpoint teardown',
      () {
    final android = File(
      'android/src/main/kotlin/com/fzfstudio/ezw_ble/ble/BleManager.kt',
    ).readAsStringSync();
    final ios = File('ios/Classes/ble/BleManager.swift').readAsStringSync();

    final androidMethod = _methodBody(
      android,
      'fun cancelAutoReconnectTargets(',
      'fun disconnectForOtaReboot(',
    );
    // 1、批量取消必须先让 Manager/Gate 共同推进一次 generation。
    expect(
      androidMethod.indexOf('invalidateConnectionAttempts(endpointIds)'),
      lessThan(androidMethod.indexOf('releaseDeviceRuntime(')),
    );
    // 2、逐 endpoint teardown 只能释放 runtime，不得再次推进 Gate generation。
    expect(androidMethod, contains('admissionAlreadyInvalidated = true'));
    expect(androidMethod, isNot(contains('releaseDevice(endpointId')));

    final iosMethod = _methodBody(
      ios,
      'func cancelAutoReconnectTargets(',
      'func disconnectForOtaReboot(',
    );
    expect(
      iosMethod.indexOf('connectionAdmissionGate.cancelEndpoints'),
      lessThan(iosMethod.indexOf('disconnect(uuid: target.uuid')),
    );
  });

  test('name-only iOS target is preserved and parses identityPending ack',
      () async {
    MethodCall? captured;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      captured = call;
      return [
        {
          'belongConfig': 'ring_bcl_1',
          'uuid': '',
          'name': 'EVEN R1_2639B0',
          'state': 'identityPending',
          'reason': 'awaitingPeripheralIdentity',
        },
      ];
    });

    final results = await platform.activateAutoReconnectTargets([
      BleDevice(
        'ring_bcl_1',
        '',
        'EVEN R1_2639B0',
        'EVEN R1_2639B0',
        -50,
        mac: 'ED:0E:DC:26:39:B0',
      ),
    ]);

    final arguments = captured?.arguments as Map<Object?, Object?>;
    final target =
        (arguments['devices'] as List<Object?>).single as Map<Object?, Object?>;
    expect(target['uuid'], '');
    expect(target['name'], 'EVEN R1_2639B0');
    expect(target['mac'], 'ED:0E:DC:26:39:B0');
    expect(results.single.state, BleReconnectActivationState.identityPending);
    expect(results.single.isAccepted, isTrue);
  });

  test('restoration activation keeps request key and exposes resolved UUID',
      () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async {
      return [
        {
          'belongConfig': 'ring_bcl_1',
          // uuid 保留请求身份，防止 recovery batch 在回执期改 key。
          'uuid': '',
          'name': 'EVEN R1_F9B658',
          'state': 'resolved',
          'reason': 'restoredPeripheralClaimed',
          'source': 'autoReconnect',
          'sessionGeneration': 7,
          'resolvedUuid': '5FB51C30-E13C-A3B7-F542-796E2CE78830',
          'resolutionSource': 'stateRestoration',
        },
      ];
    });

    final results = await platform.activateAutoReconnectTargets([
      BleDevice(
        'ring_bcl_1',
        '',
        'EVEN R1_F9B658',
        'EVEN R1_F9B658',
        -50,
        mac: 'DA:93:14:F9:B6:58',
      ),
    ], sessionGeneration: 7);

    final result = results.single;
    expect(result.uuid, '');
    expect(
      result.resolvedUuid,
      '5FB51C30-E13C-A3B7-F542-796E2CE78830',
    );
    expect(result.resolutionSource, 'stateRestoration');
    expect(result.sessionGeneration, 7);
    expect(result.state, BleReconnectActivationState.resolved);
  });

  test('activation ack keeps native rejection observable', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async {
      return [
        {
          'belongConfig': 'ring_bcl_1',
          'uuid': '',
          'name': '',
          'state': 'rejected',
          'reason': 'emptyIdentity',
        },
      ];
    });

    final results = await platform.activateAutoReconnectTargets([
      BleDevice('ring_bcl_1', '', '', 'R1', -50),
    ]);

    expect(results.single.state, BleReconnectActivationState.rejected);
    expect(results.single.isAccepted, isFalse);
    expect(results.single.reason, 'emptyIdentity');
  });
}

String _methodBody(String source, String start, String end) {
  final startIndex = source.indexOf(start);
  final endIndex = source.indexOf(end, startIndex + start.length);
  expect(startIndex, isNonNegative, reason: 'missing $start');
  expect(endIndex, greaterThan(startIndex), reason: 'missing boundary $end');
  return source.substring(startIndex, endIndex);
}
