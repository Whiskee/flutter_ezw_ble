import 'package:json_annotation/json_annotation.dart';

part 'ble_uuid.g.dart';

@JsonSerializable()
class BleUUID {
  final String service;
  final String? writeChars;
  final String? readChars;

  BleUUID(
    this.service, {
    this.writeChars,
    this.readChars,
  });

  factory BleUUID.fromJson(Map<String, dynamic> json) => _$BleUUIDFromJson(json);
  
  Map<String, dynamic> toJson() => _$BleUUIDToJson(this);
  
}
