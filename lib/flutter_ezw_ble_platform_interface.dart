import 'dart:typed_data';

import 'package:flutter_ezw_ble/models/ble_config.dart';
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

  Future<String?> getPlatformVersion() {
    throw UnimplementedError('platformVersion() has not been implemented.');
  }

  Future<int> bleState() {
    throw UnimplementedError('bleState() has not been implemented.');
  }

  Future<void> initConfigs(List<BleConfig> configs) {
    throw UnimplementedError('initConfig() has not been implemented.');
  }

  Future<void> startScan() {
    throw UnimplementedError('startScan() has not been implemented.');
  }

  Future<void> stopScan() {
    throw UnimplementedError('stopScan() has not been implemented.');
  }

  ///
  /// - param sn only for Android
  ///
  Future<void> connectDevice(
    String belongConfig,
    String uuid, {
    String? sn,
    bool? afterUpgrade,
  }) {
    throw UnimplementedError('connectDevice() has not been implemented.');
  }

  Future<void> disconnectDevice(String uuid) {
    throw UnimplementedError('disconnectDevice() has not been implemented.');
  }

  Future<void> deviceConnected(String uuid) {
    throw UnimplementedError('deviceConnected() has not been implemented.');
  }

  Future<void> sendCmd(
    String uuid,
    Uint8List data, {
    int psType = 0,
  }) {
    throw UnimplementedError('sendCmd() has not been implemented.');
  }

  Future<void> enterUpgradeState(String uuid) {
    throw UnimplementedError('enterUpgradeState() has not been implemented.');
  }

  Future<void> quiteUpgradeState(String uuid) {
    throw UnimplementedError('quiteUpgradeState() has not been implemented.');
  }

  Future<void> openBleSettings() {
    throw UnimplementedError('openBleSettings() has not been implemented.');
  }

  Future<void> openAppSettings() {
    throw UnimplementedError('openAppSettings() has not been implemented.');
  }
}
