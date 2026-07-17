import 'dart:typed_data';

import 'package:flutter_ezw_ble/core/models/ble_config.dart';
import 'package:flutter_ezw_ble/core/models/ble_cmd.dart';
import 'package:flutter_ezw_ble/core/models/ble_connect_source.dart';
import 'package:flutter_ezw_ble/core/models/ble_device.dart';
import 'package:flutter_ezw_ble/core/models/ble_reconnect_activation_result.dart';
import 'package:flutter_ezw_ble/flutter_ezw_ble_method_channel.dart';
import 'package:flutter_ezw_ble/flutter_ezw_ble_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class MockFlutterEzwBlePlatform
    with MockPlatformInterfaceMixin
    implements FlutterEzwBlePlatform {
  @override
  Future<String?> getPlatformVersion() {
    throw UnimplementedError();
  }

  @override
  Future<int> bleState() {
    throw UnimplementedError();
  }

  @override
  Future<void> initConfigs(List<BleConfig> configs) {
    throw UnimplementedError();
  }

  @override
  Future<void> startScan({bool turnOnPureModel = false}) {
    throw UnimplementedError();
  }

  @override
  Future<void> stopScan() {
    throw UnimplementedError();
  }

  @override
  Future<bool> isSystemConnectedPeripheral(
    String belongConfig,
    String uuid,
    String name,
  ) {
    throw UnimplementedError();
  }

  @override
  Future<void> connectDevice(
    String belongConfig,
    String uuid,
    String name, {
    String? sn,
    bool? afterUpgrade,
    bool directConnect = false,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<void> disconnectDevice(String uuid, String name,
      {bool removeBond = false}) {
    throw UnimplementedError();
  }

  @override
  Future<void> disconnectForOtaReboot(String uuid, String name) {
    throw UnimplementedError();
  }

  @override
  Future<void> devicePreConnected(String uuid) {
    throw UnimplementedError();
  }

  @override
  Future<void> deviceConnected(String uuid) {
    throw UnimplementedError();
  }

  @override
  Future<void> armAutoReconnectTargets(List<BleDevice> devices) {
    throw UnimplementedError();
  }

  @override
  Future<List<BleReconnectActivationResult>> activateAutoReconnectTargets(
    List<BleDevice> devices, {
    BleConnectSource source = BleConnectSource.autoReconnect,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<bool> notifyAutoReconnectTargetVisible({
    required String uuid,
    String name = '',
  }) {
    throw UnimplementedError();
  }

  @override
  Future<void> sendCmd(
    String uuid,
    Uint8List data, {
    int psType = 0,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<void> sendCmdNoWait(
    String uuid,
    Uint8List data, {
    int psType = 0,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<void> openAppSettings() {
    throw UnimplementedError();
  }

  @override
  Future<void> openBleSettings() {
    throw UnimplementedError();
  }

  @override
  Future<void> enterUpgradeState(String uuid) {
    throw UnimplementedError();
  }

  @override
  Future<void> quiteUpgradeState(String uuid) {
    throw UnimplementedError();
  }

  @override
  Future<void> cleanConnectCache() {
    throw UnimplementedError();
  }

  @override
  Future<void> resetBle() {
    throw UnimplementedError();
  }

  @override
  Future<List<Map<String, dynamic>>> drainAutoReconnectEvents() {
    throw UnimplementedError();
  }
}

void main() {
  final FlutterEzwBlePlatform initialPlatform = FlutterEzwBlePlatform.instance;

  test('$MethodChannelEzwBle is the default instance', () {
    expect(initialPlatform, isInstanceOf<MethodChannelEzwBle>());
  });

  test('BleCmd.receiveMap decodes stable receiveData payloads', () {
    final cmd = BleCmd.receiveMap({
      'uuid': 'device-1',
      'psType': 2,
      'data': 'AQID',
      'isSuccess': true,
    });

    expect(cmd.uuid, 'device-1');
    expect(cmd.psType, 2);
    expect(cmd.data, [1, 2, 3]);
    expect(cmd.isSuccess, isTrue);
  });

  test('BleCmd.receiveMap does not throw on malformed receiveData payloads',
      () {
    final cmd = BleCmd.receiveMap({'unexpected': null});

    expect(cmd.uuid, isEmpty);
    expect(cmd.psType, 0);
    expect(cmd.data, isNull);
    expect(cmd.isSuccess, isFalse);
  });

  // test('getPlatformVersion', () async {
  //   EzwBle ezwBlePlugin = EzwBle();
  //   MockFlutterEzwBlePlatform fakePlatform = MockFlutterEzwBlePlatform();
  //   FlutterEzwBlePlatform.instance = fakePlatform;

  //   expect(await ezwBlePlugin.getPlatformVersion(), '42');
  // });
}
