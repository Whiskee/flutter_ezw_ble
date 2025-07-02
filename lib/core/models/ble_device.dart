import 'dart:io';

import 'package:flutter_ezw_ble/core/tools/connect_state_converter.dart';
import 'package:flutter_ezw_ble/core/models/ble_connect_state.dart';
import 'package:flutter_ezw_ble/core/models/ble_device_hardware.dart';
import 'package:json_annotation/json_annotation.dart';

part 'ble_device.g.dart';

@JsonSerializable()
class BleDevice {
  final String belongConfig;
  //  iOS为UUID，Android为MAC地址
  String uuid;
  String name;
  String sn;
  int rssi;
  //  MAC地址，Android MAC地址等于UUID
  String mac;

  //  连接状态
  @ConnectStateListConverter()
  BleConnectState connectState;
  //  硬件信息
  @JsonKey(includeFromJson: false, includeToJson: false)
  BleDeviceHardware hardware = BleDeviceHardware();

  BleDevice(
    this.belongConfig,
    this.uuid,
    this.name,
    this.sn,
    this.rssi, {
    this.mac = '',
    this.connectState = BleConnectState.none,
  }) {
    if (mac.isEmpty && Platform.isAndroid) {
      mac = uuid;
    }
  }

  factory BleDevice.fromJson(Map<String, dynamic> json) =>
      _$BleDeviceFromJson(json);

  Map<String, dynamic> toJson() => _$BleDeviceToJson(this);

  BleDevice copy() => BleDevice(
        belongConfig,
        uuid,
        name,
        sn,
        rssi,
        mac: mac,
        connectState: connectState,
      )..hardware = hardware.copy();
}
