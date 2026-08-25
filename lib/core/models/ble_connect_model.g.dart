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
      source: $enumDecodeNullable(_$BleConnectSourceEnumMap, json['source'],
              unknownValue: BleConnectSource.unknown) ??
          BleConnectSource.unknown,
      sessionGeneration: (json['generation'] as num?)?.toInt() ?? 0,
      attemptGeneration: (json['attemptGeneration'] as num?)?.toInt() ?? 0,
      nativeTrace: json['nativeTrace'] == null
          ? null
          : BleNativeConnectionTrace.fromJson(
              json['nativeTrace'] as Map<String, dynamic>),
    );

Map<String, dynamic> _$BleConnectModelToJson(BleConnectModel instance) =>
    <String, dynamic>{
      'uuid': instance.uuid,
      'name': instance.name,
      'connectState':
          const ConnectStateListConverter().toJson(instance.connectState),
      'mtu': instance.mtu,
      'source': _$BleConnectSourceEnumMap[instance.source]!,
      'generation': instance.sessionGeneration,
      'attemptGeneration': instance.attemptGeneration,
      'nativeTrace': instance.nativeTrace?.toJson(),
    };

const _$BleConnectSourceEnumMap = {
  BleConnectSource.unknown: 'unknown',
  BleConnectSource.autoReconnect: 'autoReconnect',
  BleConnectSource.manualReconnect: 'manualReconnect',
  BleConnectSource.foreground: 'foreground',
};
