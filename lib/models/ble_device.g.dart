// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'ble_device.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

BleDevice _$BleDeviceFromJson(Map<String, dynamic> json) => BleDevice(
      json['belongConfig'] as String,
      json['name'] as String,
      json['uuid'] as String,
      json['sn'] as String,
      (json['rssi'] as num).toInt(),
      mac: json['mac'] as String? ?? '',
      connectState: json['connectState'] == null
          ? BleConnectState.none
          : const ConnectStateListConverter()
              .fromJson(json['connectState'] as String),
    );

Map<String, dynamic> _$BleDeviceToJson(BleDevice instance) => <String, dynamic>{
      'belongConfig': instance.belongConfig,
      'name': instance.name,
      'uuid': instance.uuid,
      'sn': instance.sn,
      'rssi': instance.rssi,
      'mac': instance.mac,
      'connectState':
          const ConnectStateListConverter().toJson(instance.connectState),
    };
