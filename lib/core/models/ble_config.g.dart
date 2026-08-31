// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'ble_config.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

BleConfig _$BleConfigFromJson(Map<String, dynamic> json) => BleConfig(
      json['name'] as String,
      BleScan.fromJson(json['scan'] as Map<String, dynamic>),
      (json['privateServices'] as List<dynamic>)
          .map((e) => BlePrivateService.fromJson(e as Map<String, dynamic>))
          .toList(),
      initiateBinding: json['initiateBinding'] as bool? ?? false,
      connectTimeout: (json['connectTimeout'] as num?)?.toDouble() ?? 15000,
      upgradeSwapTime: (json['upgradeSwapTime'] as num?)?.toDouble() ?? 60000,
      mtu: (json['mtu'] as num?)?.toInt() ?? 247,
      autoReconnect: json['autoReconnect'] as bool? ?? false,
      autoReconnectMaxAttempts:
          (json['autoReconnectMaxAttempts'] as num?)?.toInt() ?? 0,
      autoReconnectUseNativePassive:
          json['autoReconnectUseNativePassive'] as bool? ?? true,
      androidHighReliabilityMode:
          json['androidHighReliabilityMode'] as bool? ?? false,
    );

Map<String, dynamic> _$BleConfigToJson(BleConfig instance) => <String, dynamic>{
      'name': instance.name,
      'scan': instance.scan,
      'privateServices': instance.privateServices,
      'initiateBinding': instance.initiateBinding,
      'connectTimeout': instance.connectTimeout,
      'upgradeSwapTime': instance.upgradeSwapTime,
      'mtu': instance.mtu,
      'autoReconnect': instance.autoReconnect,
      'autoReconnectMaxAttempts': instance.autoReconnectMaxAttempts,
      'autoReconnectUseNativePassive': instance.autoReconnectUseNativePassive,
      'androidHighReliabilityMode': instance.androidHighReliabilityMode,
    };
