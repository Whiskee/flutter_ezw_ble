import 'dart:convert';

import 'package:flutter_ezw_ble/core/models/ble_connect_state.dart';
import 'package:flutter_ezw_ble/core/models/ble_device.dart';
import 'package:json_annotation/json_annotation.dart';

part 'ble_match_device.g.dart';

@JsonSerializable(explicitToJson: true)
class BleMatchDevice {
  final String sn;
  final List<BleDevice> devices;

  //  设备备注
  @JsonKey(includeToJson: false, includeFromJson: false)
  String remark = "";

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
  //  - 是否纯连接
  bool get isPureConnected =>
      devices.where((device) => device.connectState.isPureConnected).length ==
      devices.length;
  //  - 是否连接出错(任意一遍出错就是出现连接错误)
  bool get isConnectError =>
      devices.where((device) => device.connectState.isError).isNotEmpty;
  //  - 是否连接失败(两边都失败才算失败)
  bool get isConnectFailed =>
      devices.where((device) => device.connectState.isError).length ==
      devices.length;
  //  - 是否断连(任意一边断连就算断开
  bool get isDisconnected =>
      devices.where((device) => device.connectState.isDisconnected).isNotEmpty;
  //  - 是否完全断连
  bool get isAllDisconnected =>
      devices.where((device) => device.connectState.isDisconnected).length ==
      devices.length;
  //  - 是否系统断连
  bool get isDisconnectFromSys => devices
      .where((device) => device.connectState.isDisconnectFromSys)
      .isNotEmpty;
  //  - 是否已经绑定的设备
  bool get isBound =>
      devices.where((device) => device.connectState.isBound).isNotEmpty;
  //  - 是否有升级中
  bool get isOtaUpgrading =>
      devices.where((device) => device.connectState.isUpgrade).isNotEmpty;

  BleMatchDevice(
    this.sn, {
    this.devices = const [],
  });

  factory BleMatchDevice.fromJson(Map<String, dynamic> json) =>
      _$BleMatchDeviceFromJson(json)..remark = json['remark'] as String? ?? "";

  Map<String, dynamic> toJson() =>
      _$BleMatchDeviceToJson(this)..[remark] = remark;

  BleMatchDevice copy() =>
      BleMatchDevice(sn, devices: devices.map((match) => match.copy()).toList())
        ..remark = remark;

  @override
  String toString() => jsonEncode(toJson());

  /// 是否是同一个设备
  bool isSameDevice(BleMatchDevice other) =>
      sn == other.sn &&
      devices.length == other.devices.length &&
      devices.every((device) =>
          other.devices.any((otherDevice) => otherDevice.uuid == device.uuid));
}
