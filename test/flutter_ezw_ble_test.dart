import 'dart:typed_data';

import 'package:flutter_ezw_ble/core/models/ble_config.dart';
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
  Future<void> connectDevice(
    String belongConfig,
    String uuid,
    String name, {
    String? sn,
    bool? afterUpgrade,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<void> disconnectDevice(String uuid, String name,
      {bool removeBond = false}) {
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
  Future<void> sendCmd(
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
}

void main() {
  final FlutterEzwBlePlatform initialPlatform = FlutterEzwBlePlatform.instance;

  test('$MethodChannelEzwBle is the default instance', () {
    expect(initialPlatform, isInstanceOf<MethodChannelEzwBle>());
  });

  // test('getPlatformVersion', () async {
  //   EzwBle ezwBlePlugin = EzwBle();
  //   MockFlutterEzwBlePlatform fakePlatform = MockFlutterEzwBlePlatform();
  //   FlutterEzwBlePlatform.instance = fakePlatform;

  //   expect(await ezwBlePlugin.getPlatformVersion(), '42');
  // });
}
