import 'package:flutter_ezw_ble/core/tools/connect_state_converter.dart';
import 'package:flutter_ezw_ble/models/ble_connect_state.dart';
import 'package:json_annotation/json_annotation.dart';

part 'ble_device.g.dart';

@JsonSerializable()
class BleDevice {
  final String name;
  //  iOS为UUID，Android为MAC地址
  final String uuid;
  final String sn;
  final int rssi;
  @ConnectStateListConverter()
  BleConnectState connectState;

  BleDevice(
    this.name,
    this.uuid,
    this.sn,
    this.rssi, {
    this.connectState = BleConnectState.none,
  });

  factory BleDevice.fromJson(Map<String, dynamic> json) =>
      _$BleDeviceFromJson(json);

  Map<String, dynamic> toJson() => _$BleDeviceToJson(this);

  BleDevice copy() => BleDevice(name, uuid, sn, rssi, connectState: connectState);
}
