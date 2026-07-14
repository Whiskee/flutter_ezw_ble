import 'package:flutter_ezw_ble/core/models/ble_connect_source.dart';
import 'package:flutter_ezw_ble/core/models/ble_connect_state.dart';
import 'package:flutter_ezw_ble/core/tools/connect_state_converter.dart';
import 'package:json_annotation/json_annotation.dart';

part 'ble_connect_model.g.dart';

@JsonSerializable()
class BleConnectModel {
  final String uuid;
  final String name;
  @ConnectStateListConverter()
  final BleConnectState connectState;
  final int mtu;
  @JsonKey(
    defaultValue: BleConnectSource.unknown,
    unknownEnumValue: BleConnectSource.unknown,
  )
  final BleConnectSource source;
  @JsonKey(defaultValue: 0)
  final int generation;

  BleConnectModel(
    this.uuid,
    this.name,
    this.connectState, {
    this.mtu = 512,
    this.source = BleConnectSource.unknown,
    this.generation = 0,
  });

  factory BleConnectModel.fromJson(Map<String, dynamic> json) =>
      _$BleConnectModelFromJson(json);

  Map<String, dynamic> toJson() => _$BleConnectModelToJson(this);
}
