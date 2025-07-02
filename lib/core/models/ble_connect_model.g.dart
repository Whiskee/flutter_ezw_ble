// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'ble_connect_model.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

BleConnectModel _$BleConnectModelFromJson(Map<String, dynamic> json) =>
    BleConnectModel(
      json['uuid'] as String,
      json['name'] as String,
      const ConnectStateListConverter()
          .fromJson(json['connectState'] as String),
      mtu: (json['mtu'] as num?)?.toInt() ?? 512,
    );

Map<String, dynamic> _$BleConnectModelToJson(BleConnectModel instance) =>
    <String, dynamic>{
      'uuid': instance.uuid,
      'name': instance.name,
      'connectState':
          const ConnectStateListConverter().toJson(instance.connectState),
      'mtu': instance.mtu,
    };
