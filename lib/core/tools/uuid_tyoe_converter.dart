import 'package:flutter_ezw_ble/models/ble_uuid_type.dart';
import 'package:json_annotation/json_annotation.dart';

class UuidTypeConverter implements JsonConverter<BleUuidType, String> {
  const UuidTypeConverter();

  @override
  BleUuidType fromJson(String json) => BleUuidTypeExt.label(json);

  @override
  String toJson(BleUuidType object) => object.name;
}
