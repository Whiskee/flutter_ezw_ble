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
  @JsonKey(name: 'generation', defaultValue: 0)
  final int sessionGeneration;
  @JsonKey(defaultValue: 0)
  final int attemptGeneration;

  /// Backward-compatible alias for payloads that used one generation field.
  @JsonKey(includeFromJson: false, includeToJson: false)
  int get generation => sessionGeneration;

  BleConnectModel(
    this.uuid,
    this.name,
    this.connectState, {
    this.mtu = 512,
    this.source = BleConnectSource.unknown,
    int sessionGeneration = 0,
    int? generation,
    this.attemptGeneration = 0,
  }) : sessionGeneration = generation ?? sessionGeneration;

  factory BleConnectModel.fromJson(Map<String, dynamic> json) {
    // Native now emits both sessionGeneration and attemptGeneration; legacy
    // payloads only had generation. Normalize before generated decoding so the
    // public model keeps one compatibility source of truth.
    final compatibleJson = Map<String, dynamic>.from(json);
    compatibleJson['generation'] =
        compatibleJson['sessionGeneration'] ?? compatibleJson['generation'];
    return _$BleConnectModelFromJson(compatibleJson);
  }

  Map<String, dynamic> toJson() {
    final json = _$BleConnectModelToJson(this);
    json['sessionGeneration'] = sessionGeneration;
    return json;
  }
}
