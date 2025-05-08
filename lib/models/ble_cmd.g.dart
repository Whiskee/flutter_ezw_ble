// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'ble_cmd.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

BleCmd _$BleCmdFromJson(Map<String, dynamic> json) => BleCmd(
      json['uuid'] as String,
      const UuidTypeConverter().fromJson(json['type'] as String),
      data: _$JsonConverterFromJson<String, Uint8List>(
          json['data'], const Uint8ListConverter().fromJson),
      isSuccess: json['isSuccess'] as bool? ?? false,
    );

Map<String, dynamic> _$BleCmdToJson(BleCmd instance) => <String, dynamic>{
      'uuid': instance.uuid,
      'type': const UuidTypeConverter().toJson(instance.type),
      'data': _$JsonConverterToJson<String, Uint8List>(
          instance.data, const Uint8ListConverter().toJson),
      'isSuccess': instance.isSuccess,
    };

Value? _$JsonConverterFromJson<Json, Value>(
  Object? json,
  Value? Function(Json json) fromJson,
) =>
    json == null ? null : fromJson(json as Json);

Json? _$JsonConverterToJson<Json, Value>(
  Value? value,
  Json? Function(Value value) toJson,
) =>
    value == null ? null : toJson(value);
