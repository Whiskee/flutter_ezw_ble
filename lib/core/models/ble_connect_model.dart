import 'package:flutter_ezw_ble/core/models/ble_connect_state.dart';
import 'package:flutter_ezw_ble/core/tools/connect_state_converter.dart';
import 'package:json_annotation/json_annotation.dart';

part 'ble_connect_model.g.dart';

@JsonSerializable()
class BleConnectModel {
  final String uuid;
  @ConnectStateListConverter()
  final BleConnectState connectState;
  final int mtu;

  BleConnectModel(
    this.uuid,
    this.connectState, {
    this.mtu = 512,
  });

  factory BleConnectModel.fromJson(Map<String, dynamic> json) =>
      _$BleConnectModelFromJson(json);

  Map<String, dynamic> toJson() => _$BleConnectModelToJson(this);
}
