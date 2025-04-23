import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_ezw_ble/flutter_ezw_ble.dart';
import 'package:flutter_ezw_ble/models/ble_config.dart';

import 'flutter_ezw_ble_platform_interface.dart';

/// An implementation of [EvenConnectPlatform] that uses method channels.
class MethodChannelEzwBle extends FlutterEzwBlePlatform {
  /// The method channel used to interact with the native platform.
  @visibleForTesting
  final methodChannel = const MethodChannel(ezwBleTag);

  @override
  Future<String?> getPlatformVersion() async =>
      await methodChannel.invokeMethod<String>('getPlatformVersion');

  @override
  Future<int> bleState() async => await methodChannel.invokeMethod("bleState");

  @override
  Future<void> enableConfig(BleConfig config) async =>
      methodChannel.invokeMethod("enableConfig", config.customToJson());

  @override
  Future<void> startScan() async => methodChannel.invokeMethod("startScan");

  @override
  Future<void> stopScan() async => methodChannel.invokeMethod("stopScan");

  /// 参数 sn 仅在 Android 平台有效
  @override
  Future<void> connectDevice(String uuid,
          {String? sn, bool? afterUpgrade}) async =>
      methodChannel.invokeMethod("connectDevice",
          {"uuid": uuid, "sn": sn, "afterUpgrade": afterUpgrade});

  @override
  Future<void> disconnectDevice(String uuid) async =>
      methodChannel.invokeMethod("disconnectDevice", uuid);

  @override
  Future<void> deviceConnected(String uuid) async =>
      methodChannel.invokeMethod("deviceConnected", uuid);

  @override
  Future<void> sendCmd(String uuid, Uint8List data, {bool? isOtaCmd}) async =>
      methodChannel.invokeMethod("sendCmd", {"uuid": uuid, "data": data, "isOtaCmd": isOtaCmd});

  @override
  Future<void> enterUpgradeState(String uuid) =>
      methodChannel.invokeMethod("enterUpgradeState", uuid);

  @override
  Future<void> quiteUpgradeState(String uuid) =>
      methodChannel.invokeMethod("quiteUpgradeState", uuid);

  @override
  Future<void> openBleSettings() async =>
      methodChannel.invokeMethod("openBleSettings");

  @override
  Future<void> openAppSettings() async =>
      methodChannel.invokeMethod("openAppSettings");
}
