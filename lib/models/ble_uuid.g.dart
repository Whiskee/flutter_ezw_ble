// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'ble_uuid.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

BleUuid _$BleUuidFromJson(Map<String, dynamic> json) => BleUuid(
      json['service'] as String,
      writeChars: json['writeChars'] as String,
      readChars: json['readChars'] as String,
      type: json['type'] == null
          ? BleUuidType.common
          : const UuidTypeConverter().fromJson(json['type'] as String),
    );

Map<String, dynamic> _$BleUuidToJson(BleUuid instance) => <String, dynamic>{
      'service': instance.service,
      'writeChars': instance.writeChars,
      'readChars': instance.readChars,
      'type': const UuidTypeConverter().toJson(instance.type),
    };
