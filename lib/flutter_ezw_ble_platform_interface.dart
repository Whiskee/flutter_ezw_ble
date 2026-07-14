import 'dart:typed_data';

import 'package:flutter_ezw_ble/core/models/ble_config.dart';
import 'package:flutter_ezw_ble/core/models/ble_connect_source.dart';
import 'package:flutter_ezw_ble/core/models/ble_device.dart';
import 'package:flutter_ezw_ble/core/models/ble_reconnect_activation_result.dart';
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

  /// 检查目标外设是否已被系统/CoreBluetooth 持有连接。
  ///
  /// iOS G2 右腿申请 ANCS 后可能停止广播，普通扫描无法发现；此方法用于
  /// scan-first 流程中的目标化探测，不能替代真正的 connectDevice。
  Future<bool> isSystemConnectedPeripheral(
    String belongConfig,
    String uuid,
    String name,
  ) {
    throw UnimplementedError(
        'isSystemConnectedPeripheral() has not been implemented.');
  }

  /// 连接设备
  ///
  /// - param belongConfig 配置名称
  /// - param uuid 设备唯一标识
  /// - param name 设备名称
  /// - param sn only for Android
  /// - param afterUpgrade 是否在升级模式下连接
  /// - param directConnect 为 true 时不走任何扫描，仅使用已有缓存/peripheral 直连
  ///
  Future<void> connectDevice(
    String belongConfig,
    String uuid,
    String name, {
    String? sn,
    bool? afterUpgrade,
    bool directConnect = false,
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

  /// 设备预连接：告知原生设备即将连接，允许在连接成功前做一些准备工作，避免超时退出
  ///
  /// - param uuid 设备唯一标识
  ///
  Future<void> devicePreConnected(String uuid) {
    throw UnimplementedError(
        'devicePreConnected(uuid: $uuid) has not been implemented.');
  }

  /// 设备连接成功
  ///
  /// - param uuid 设备唯一标识
  ///
  Future<void> deviceConnected(String uuid) {
    throw UnimplementedError(
        'deviceConnected(uuid: $uuid) has not been implemented.');
  }

  /// 只补种 native 自动回连目标，不发起前台连接。
  ///
  /// 用于旧缓存/进程恢复场景：Dart 已知道用户允许 autoReconnect，但 native
  /// 当前进程尚未经历 `deviceConnected`，需要先建立长期回连 owner。
  Future<void> armAutoReconnectTargets(List<BleDevice> devices) {
    throw UnimplementedError(
        'armAutoReconnectTargets(devices: $devices) has not been implemented.');
  }

  /// 建立并立即激活长期自动回连目标。
  ///
  /// 与 arm-only 兼容入口不同，本方法会马上把所有目标交给系统 pending connect；
  /// [source] 会随真实物理连接回调上报，用于上层区分自动/手动恢复展示。
  Future<List<BleReconnectActivationResult>> activateAutoReconnectTargets(
    List<BleDevice> devices, {
    BleConnectSource source = BleConnectSource.autoReconnect,
  }) {
    throw UnimplementedError(
      'activateAutoReconnectTargets(devices: $devices, source: $source) has not been implemented.',
    );
  }

  /// 通知原生：辅助扫描已经重新看到某个自动回连目标。
  ///
  /// Android 只会唤醒该 UUID 当前尚未物理连接的 passive GATT/重建定时器；
  /// 已进入 Gate、已连接、已取消或蓝牙关闭时返回 false。iOS 不依赖扫描
  /// 唤醒 CoreBluetooth pending connect，因此安全返回 false。
  Future<bool> notifyAutoReconnectTargetVisible({
    required String uuid,
    String name = '',
  }) {
    throw UnimplementedError(
      'notifyAutoReconnectTargetVisible(uuid: $uuid, name: $name) has not been implemented.',
    );
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

  /// 发送指令(不等待写入结果)
  ///
  /// - param uuid 设备唯一标识
  /// - param data 指令数据
  /// - param psType 指令类型
  ///
  Future<void> sendCmdNoWait(
    String uuid,
    Uint8List data, {
    int psType = 0,
  }) {
    throw UnimplementedError('sendCmdNoWait() has not been implemented.');
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

  /// 读取并清空原生自动回连/后台恢复期间持久化的事件。
  ///
  /// 用于 iOS State Restoration 或 Android 原生回连先于 Dart 监听器发生时，
  /// 让业务层在启动后补齐 native 侧证据并决定是否继续业务鉴权流程。
  Future<List<Map<String, dynamic>>> drainAutoReconnectEvents() {
    throw UnimplementedError(
        'drainAutoReconnectEvents() has not been implemented.');
  }
}
