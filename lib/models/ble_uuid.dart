import 'package:flutter_ezw_ble/core/tools/uuid_tyoe_converter.dart';
import 'package:flutter_ezw_ble/models/ble_uuid_type.dart';
import 'package:json_annotation/json_annotation.dart';

part 'ble_uuid.g.dart';

@JsonSerializable()
class BleUuid {
  final String service;
  final String writeChars;
  final String readChars;
  @UuidTypeConverter()
  final BleUuidType type;

  BleUuid(
    this.service, {
    required this.writeChars,
    required this.readChars,
    this.type = BleUuidType.common,
  });

  factory BleUuid.fromJson(Map<String, dynamic> json) =>
      _$BleUuidFromJson(json);

  Map<String, dynamic> toJson() => _$BleUuidToJson(this);
}
