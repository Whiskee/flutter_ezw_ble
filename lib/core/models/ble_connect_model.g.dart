// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'ble_connect_model.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

BleConnectModel _$BleConnectModelFromJson(Map<String, dynamic> json) =>
    BleConnectModel(
      json['uuid'] as String,
      const ConnectStateListConverter()
          .fromJson(json['connectState'] as String),
    );

Map<String, dynamic> _$BleConnectModelToJson(BleConnectModel instance) =>
    <String, dynamic>{
      'uuid': instance.uuid,
      'connectState':
          const ConnectStateListConverter().toJson(instance.connectState),
    };
