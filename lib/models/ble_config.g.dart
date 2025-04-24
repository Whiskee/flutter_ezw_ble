// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'ble_config.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

BleConfig _$BleConfigFromJson(Map<String, dynamic> json) => BleConfig(
      json['name'] as String,
      (json['uuids'] as List<dynamic>)
          .map((e) => BleUuid.fromJson(e as Map<String, dynamic>))
          .toList(),
      BleSnRule.fromJson(json['snRule'] as Map<String, dynamic>),
      connectTimeout: (json['connectTimeout'] as num?)?.toDouble() ?? 15000,
      upgradeSwapTime: (json['upgradeSwapTime'] as num?)?.toDouble() ?? 60000,
      mtu: (json['mtu'] as num?)?.toInt() ?? 255,
    );

Map<String, dynamic> _$BleConfigToJson(BleConfig instance) => <String, dynamic>{
      'name': instance.name,
      'uuids': instance.uuids,
      'snRule': instance.snRule,
      'connectTimeout': instance.connectTimeout,
      'upgradeSwapTime': instance.upgradeSwapTime,
      'mtu': instance.mtu,
    };
