// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'ble_match_device.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

BleMatchDevice _$BleMatchDeviceFromJson(Map<String, dynamic> json) =>
    BleMatchDevice(
      json['sn'] as String,
      devices: (json['devices'] as List<dynamic>?)
              ?.map((e) => BleDevice.fromJson(e as Map<String, dynamic>))
              .toList() ??
          const [],
    );

Map<String, dynamic> _$BleMatchDeviceToJson(BleMatchDevice instance) =>
    <String, dynamic>{
      'sn': instance.sn,
      'devices': instance.devices,
    };
