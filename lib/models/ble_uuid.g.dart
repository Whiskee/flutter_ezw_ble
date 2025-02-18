// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'ble_uuid.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

BleUUID _$BleUUIDFromJson(Map<String, dynamic> json) => BleUUID(
      json['service'] as String,
      writeChars: json['writeChars'] as String?,
      readChars: json['readChars'] as String?,
    );

Map<String, dynamic> _$BleUUIDToJson(BleUUID instance) => <String, dynamic>{
      'service': instance.service,
      'writeChars': instance.writeChars,
      'readChars': instance.readChars,
    };
