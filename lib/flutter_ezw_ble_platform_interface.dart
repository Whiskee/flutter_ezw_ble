import 'dart:typed_data';

import 'package:flutter_ezw_ble/core/models/ble_config.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'flutter_ezw_ble_method_channel.dart';

abstract class FlutterEzwBlePlatform extends PlatformInterface {
  /// Constructs a EvenConnectPlatform.
  FlutterEzwBlePlatform() : super(token: _token);

  static final Object _token = Object();

  static FlutterEzwBlePlatform _instance = MethodChannelEzwBle();

  /// The default instance of [EvenConnectPlatform] to use.
  ///
  /// Defaults to [MethodChannelEvenConnect].
  static FlutterEzwBlePlatform get instance => _instance;

  /// Platform-specific implementations should set this with their own
  /// platform-specific class that extends [EvenConnectPlatform] when
  /// they register themselves.
  static set instance(FlutterEzwBlePlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  /// 获取平台版本
  ///
  /// - return 平台版本
  ///
  Future<String?> getPlatformVersion() {
    throw UnimplementedError('platformVersion() has not been implemented.');
  }

  /// 获取蓝牙状态
  /// 
  /// - return 蓝牙状态
  ///
  Future<int> bleState() {
    throw UnimplementedError('bleState() has not been implemented.');
  }

  /// 设置蓝牙配置
  ///
  /// - param configs 蓝牙配置
  ///
  Future<void> initConfigs(List<BleConfig> configs) {
    throw UnimplementedError('initConfig() has not been implemented.');
  }

  /// 开始扫描设备
  ///
  /// - param turnOnPureModel 是否开启纯模式
  ///
  Future<void> startScan({
    bool turnOnPureModel = false,
  }) {
    throw UnimplementedError(
        'startScan(turnOnPureModel: $turnOnPureModel) has not been implemented.');
  }

  /// 停止扫描设备
  Future<void> stopScan() {
    throw UnimplementedError('stopScan() has not been implemented.');
  }

  /// 连接设备
  /// 
  /// - param belongConfig 配置名称
  /// - param uuid 设备唯一标识
  /// - param name 设备名称
  /// - param sn only for Android
  /// - param afterUpgrade 是否在升级模式下连接
  ///
  Future<void> connectDevice(
    String belongConfig,
    String uuid,
    String name, {
    String? sn,
    bool? afterUpgrade,
  }) {
    throw UnimplementedError('connectDevice() has not been implemented.');
  }

  /// 断连设备
  /// - param uuid 设备唯一标识
  /// - param name 设备名称
  /// - param removeBond only for Android
  ///
  Future<void> disconnectDevice(
    String uuid,
    String name, {
    bool removeBond = false,
  }) {
    throw UnimplementedError(
        'disconnectDevice(uuid: $uuid, name: $name, removeBond: $removeBond) has not been implemented.');
  }

  /// 设备连接成功
  /// 
  /// - param uuid 设备唯一标识
  ///
  Future<void> deviceConnected(String uuid) {
    throw UnimplementedError('deviceConnected(uuid: $uuid) has not been implemented.');
  }

  /// 发送指令
  /// 
  /// - param uuid 设备唯一标识
  /// - param data 指令数据
  /// - param psType 指令类型
  ///
  Future<void> sendCmd(
    String uuid,
    Uint8List data, {
    int psType = 0,
  }) {
    throw UnimplementedError('sendCmd() has not been implemented.');
  }

  /// 进入升级模式
  /// 
  /// - param uuid 设备唯一标识
  ///
  Future<void> enterUpgradeState(String uuid) {
    throw UnimplementedError('enterUpgradeState() has not been implemented.');
  }

  /// 退出升级模式
  /// 
  /// - param uuid 设备唯一标识
  ///
  Future<void> quiteUpgradeState(String uuid) {
    throw UnimplementedError('quiteUpgradeState() has not been implemented.');
  }

  /// 打开蓝牙设置页面
  Future<void> openBleSettings() {
    throw UnimplementedError('openBleSettings() has not been implemented.');
  }

  /// 打开App设置页面
  Future<void> openAppSettings() {
    throw UnimplementedError('openAppSettings() has not been implemented.');
  }

  /// 重置蓝牙
  Future<void> resetBle() {
    throw UnimplementedError('resetBle() has not been implemented.');
  }

  /// 清除连接缓存
  Future<void> cleanConnectCache() {
    throw UnimplementedError('cleanConnectCache() has not been implemented.');
  }
}
