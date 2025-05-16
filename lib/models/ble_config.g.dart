// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'ble_config.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

BleConfig _$BleConfigFromJson(Map<String, dynamic> json) => BleConfig(
      json['name'] as String,
      (json['privateServices'] as List<dynamic>)
          .map((e) => BlePrivateService.fromJson(e as Map<String, dynamic>))
          .toList(),
      BleScan.fromJson(json['scan'] as Map<String, dynamic>),
      initiateBinding: json['initiateBinding'] as bool? ?? false,
      connectTimeout: (json['connectTimeout'] as num?)?.toDouble() ?? 15000,
      upgradeSwapTime: (json['upgradeSwapTime'] as num?)?.toDouble() ?? 60000,
      mtu: (json['mtu'] as num?)?.toInt() ?? 512,
    );

Map<String, dynamic> _$BleConfigToJson(BleConfig instance) => <String, dynamic>{
      'name': instance.name,
      'privateServices': instance.privateServices,
      'scan': instance.scan,
      'initiateBinding': instance.initiateBinding,
      'connectTimeout': instance.connectTimeout,
      'upgradeSwapTime': instance.upgradeSwapTime,
      'mtu': instance.mtu,
    };
