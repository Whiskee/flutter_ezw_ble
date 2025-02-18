import 'package:flutter_ezw_ble/models/ble_connect_state.dart';
import 'package:flutter_ezw_ble/models/ble_device.dart';
import 'package:json_annotation/json_annotation.dart';

part 'ble_match_device.g.dart';

@JsonSerializable()
class BleMatchDevice {
  final String sn;
  final String belongConfig;
  final List<BleDevice> devices;

  ///========== Get
  //  - 是否正在连接
  bool get isConnecting =>
      devices.where((device) => device.connectState.isConnecting).isNotEmpty;
  //  - 是否已经连接上
  bool get isConnected =>
      devices.where((device) => device.connectState.isConnected).length ==
      devices.length;

  BleMatchDevice(
    this.sn,
    this.belongConfig, {
    this.devices = const [],
  });

  factory BleMatchDevice.fromJson(Map<String, dynamic> json) =>
      _$BleMatchDeviceFromJson(json);

  Map<String, dynamic> toJson() => _$BleMatchDeviceToJson(this);

  BleMatchDevice copy() => BleMatchDevice(sn, belongConfig,
      devices: devices.map((match) => match.copy()).toList());
}
