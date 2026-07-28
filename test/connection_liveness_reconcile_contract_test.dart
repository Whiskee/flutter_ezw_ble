import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_ezw_ble/core/models/ble_connect_state.dart';
import 'package:flutter_ezw_ble/core/models/ble_device.dart';
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

  test(
    'business liveness reconcile forwards exact connected snapshots',
    () async {
      MethodCall? captured;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        captured = call;
        return null;
      });

      await platform.reconcileBusinessConnections([
        BleDevice(
          'ring_bcl_1',
          'AA:BB:CC:DD:EE:FF',
          'EVEN R1_ABCDEF',
          'R1-1',
          -45,
          connectState: BleConnectState.connected,
        ),
      ]);

      expect(captured?.method, 'reconcileBusinessConnections');
      final devices = captured?.arguments as List<Object?>;
      expect(devices, hasLength(1));
      expect(
        devices.single,
        allOf(
          containsPair('belongConfig', 'ring_bcl_1'),
          containsPair('uuid', 'AA:BB:CC:DD:EE:FF'),
          containsPair('sn', 'R1-1'),
        ),
      );
    },
  );

  test('iOS contract is an explicit no-op', () {
    final source = File(
      'ios/Classes/ble/BleMethodChannel.swift',
    ).readAsStringSync();

    expect(source, contains('case reconcileBusinessConnections'));
    expect(source, contains('case .reconcileBusinessConnections:'));
    expect(
      source.indexOf('case .reconcileBusinessConnections:'),
      lessThan(source.indexOf('case .disconnectForOtaReboot:')),
    );
  });

  test('write failure reconciles even after native device snapshot is gone',
      () {
    final source = File(
      'android/src/main/kotlin/com/fzfstudio/ezw_ble/ble/BleManager.kt',
    ).readAsStringSync();

    final writeStart = source.indexOf('private fun writeNextCommand');
    final nextSection =
        source.indexOf('/// =========== Method: Flutter Method');
    expect(writeStart, greaterThanOrEqualTo(0));
    expect(nextSection, greaterThan(writeStart));

    final branch = source.substring(writeStart, nextSection);
    expect(branch, contains('autoReconnectSupervisor.ownerSnapshot(cmd.uuid)'));
    expect(branch, contains('trigger = "writeStartFailed"'));
  });
}
