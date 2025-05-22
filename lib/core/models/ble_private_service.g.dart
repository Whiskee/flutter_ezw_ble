// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'ble_private_service.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

BlePrivateService _$BlePrivateServiceFromJson(Map<String, dynamic> json) =>
    BlePrivateService(
      json['service'] as String,
      writeChars: json['writeChars'] as String,
      readChars: json['readChars'] as String,
      type: (json['type'] as num?)?.toInt() ?? 0,
    );

Map<String, dynamic> _$BlePrivateServiceToJson(BlePrivateService instance) =>
    <String, dynamic>{
      'service': instance.service,
      'writeChars': instance.writeChars,
      'readChars': instance.readChars,
      'type': instance.type,
    };
