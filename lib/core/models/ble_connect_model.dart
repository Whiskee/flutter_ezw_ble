import 'package:flutter_ezw_ble/core/tools/connect_state_converter.dart';
import 'package:flutter_ezw_ble/core/models/ble_connect_state.dart';
import 'package:json_annotation/json_annotation.dart';

part 'ble_connect_model.g.dart';

@JsonSerializable()
class BleConnectModel {
  final String uuid;
  @ConnectStateListConverter()
  final BleConnectState connectState;

  BleConnectModel(this.uuid, this.connectState);

  factory BleConnectModel.fromJson(Map<String, dynamic> json) =>
      _$BleConnectModelFromJson(json);

  Map<String, dynamic> toJson() => _$BleConnectModelToJson(this);
}
