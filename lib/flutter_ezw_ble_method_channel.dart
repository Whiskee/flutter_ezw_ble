import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_ezw_ble/core/models/ble_config.dart';
import 'package:flutter_ezw_ble/flutter_ezw_ble.dart';

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
  Future<void> initConfigs(List<BleConfig> configs) async =>
      methodChannel.invokeMethod("initConfigs",
          configs.map((config) => config.customToJson()).toList());

  @override
  Future<void> startScan({
    bool turnOnPureModel = false,
  }) async =>
      methodChannel.invokeMethod("startScan", {
        "turnOnPureModel": turnOnPureModel,
      });

  @override
  Future<void> stopScan() async => methodChannel.invokeMethod("stopScan");

  /// 连接设备
  /// - name 仅在 iOS 平台有效
  /// - sn 仅在 Android 平台有效
  @override
  Future<void> connectDevice(
    String belongConfig,
    String uuid,
    String name, {
    String? sn,
    bool? afterUpgrade,
  }) async =>
      methodChannel.invokeMethod("connectDevice", {
        "belongConfig": belongConfig,
        "uuid": uuid,
        "name": name,
        "sn": sn,
        "afterUpgrade": afterUpgrade
      });

  @override
  Future<void> disconnectDevice(
    String uuid,
    String name, {
    bool removeBond = false,
  }) async =>
      methodChannel.invokeMethod("disconnectDevice", {
        "uuid": uuid,
        "name": name,
        "removeBond": removeBond,
      });

  @override
  Future<void> devicePreConnected(String uuid) async =>
      methodChannel.invokeMethod("devicePreConnected", uuid);

  @override
  Future<void> deviceConnected(String uuid) async =>
      methodChannel.invokeMethod("deviceConnected", uuid);

  @override
  Future<void> sendCmd(
    String uuid,
    Uint8List data, {
    int psType = 0,
  }) async =>
      methodChannel.invokeMethod<void>("sendCmd", {
        "uuid": uuid,
        "data": data,
        "psType": psType,
      });

  /// 发送数据 - 原始数据 - 不等待响应(Android 平台使用)
  @override
  Future<void> sendCmdNoWait(
    String uuid,
    Uint8List data, {
    int psType = 0,
  }) async =>
      Platform.isAndroid
          ? methodChannel.invokeMethod<void>("sendCmdNoWait", {
              "uuid": uuid,
              "data": data,
              "psType": psType,
            })
          : sendCmd(uuid, data, psType: psType);

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

  @override
  Future<void> resetBle() async => methodChannel.invokeMethod("resetBle");

  @override
  Future<void> cleanConnectCache() async =>
      methodChannel.invokeMethod("cleanConnectCache");
}
