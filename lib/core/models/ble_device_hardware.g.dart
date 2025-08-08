// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'ble_device_hardware.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

BleDeviceHardware _$BleDeviceHardwareFromJson(Map<String, dynamic> json) =>
    BleDeviceHardware()
      ..batteryStatus0 = (json['batteryStatus0'] as num).toInt()
      ..batteryStatus1 = (json['batteryStatus1'] as num).toInt()
      ..chargingVBat = (json['chargingVBat'] as num).toDouble()
      ..chargingCurrent = (json['chargingCurrent'] as num).toInt()
      ..chargingTemp = (json['chargingTemp'] as num).toInt()
      ..devVer0 = (json['devVer0'] as num).toInt()
      ..devVer1 = (json['devVer1'] as num).toInt()
      ..devVer2 = (json['devVer2'] as num).toInt()
      ..devVer3 = (json['devVer3'] as num).toInt()
      ..devVer4 = (json['devVer4'] as num).toInt()
      ..devVer5 = (json['devVer5'] as num).toInt()
      ..flashVer0 = (json['flashVer0'] as num).toInt()
      ..flashVer1 = (json['flashVer1'] as num).toInt()
      ..mHwVer = (json['mHwVer'] as num).toInt()
      ..sHwVer = (json['sHwVer'] as num).toInt()
      ..bleVer0 = (json['bleVer0'] as num).toInt()
      ..bleVer1 = (json['bleVer1'] as num).toInt()
      ..bleHwVer = (json['bleHwVer'] as num).toInt()
      ..bootSeconds = (json['bootSeconds'] as num).toInt()
      ..isMaster = json['isMaster'] as bool
      ..isSuccess = json['isSuccess'] as bool
      ..version = json['version'] as String;

Map<String, dynamic> _$BleDeviceHardwareToJson(BleDeviceHardware instance) =>
    <String, dynamic>{
      'batteryStatus0': instance.batteryStatus0,
      'batteryStatus1': instance.batteryStatus1,
      'chargingVBat': instance.chargingVBat,
      'chargingCurrent': instance.chargingCurrent,
      'chargingTemp': instance.chargingTemp,
      'devVer0': instance.devVer0,
      'devVer1': instance.devVer1,
      'devVer2': instance.devVer2,
      'devVer3': instance.devVer3,
      'devVer4': instance.devVer4,
      'devVer5': instance.devVer5,
      'flashVer0': instance.flashVer0,
      'flashVer1': instance.flashVer1,
      'mHwVer': instance.mHwVer,
      'sHwVer': instance.sHwVer,
      'bleVer0': instance.bleVer0,
      'bleVer1': instance.bleVer1,
      'bleHwVer': instance.bleHwVer,
      'bootSeconds': instance.bootSeconds,
      'isMaster': instance.isMaster,
      'isSuccess': instance.isSuccess,
      'version': instance.version,
    };
