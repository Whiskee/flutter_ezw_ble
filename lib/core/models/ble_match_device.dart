import 'dart:convert';

import 'package:flutter_ezw_ble/core/models/ble_connect_state.dart';
import 'package:flutter_ezw_ble/core/models/ble_device.dart';
import 'package:json_annotation/json_annotation.dart';

part 'ble_match_device.g.dart';

@JsonSerializable()
class BleMatchDevice {
  final String sn;
  final String remark;
  final List<BleDevice> devices;

  ///========== Get
  //  - 获取配置名称
  String get belongConfig => devices.first.belongConfig;
  //  - 是否正在连接
  bool get isConnecting =>
      devices.where((device) => device.connectState.isConnecting).isNotEmpty;
  //  - 是否连接流程完成
  bool get isConnectFinish =>
      devices.where((device) => device.connectState.isConnectFinish).length ==
      devices.length;
  //  - 是否已经连接上
  bool get isConnected =>
      devices.where((device) => device.connectState.isConnected).length ==
      devices.length;
  //  - 是否连接出错
  bool get isConnectError =>
      devices.where((device) => device.connectState.isError).isNotEmpty;
  //  - 是否断连
  bool get isDisconnected =>
      devices.where((device) => device.connectState.isDisconnected).isNotEmpty;

  BleMatchDevice(
    this.sn, {
    this.remark = "",
    this.devices = const [],
  });

  factory BleMatchDevice.fromJson(Map<String, dynamic> json) =>
      _$BleMatchDeviceFromJson(json);

  Map<String, dynamic> toJson() => _$BleMatchDeviceToJson(this);

  BleMatchDevice copy() => BleMatchDevice(sn,
      devices: devices.map((match) => match.copy()).toList());

  @override
  String toString() => jsonEncode(toJson());

  /// 是否是同一个设备
  bool isSameDevice(BleMatchDevice other) {
    return sn == other.sn &&
        devices.length == other.devices.length &&
        devices.every((device) => other.devices
            .any((otherDevice) => otherDevice.uuid == device.uuid));
  }
}
