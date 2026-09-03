// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'ble_security_gate.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

BleSecurityGate _$BleSecurityGateFromJson(Map<String, dynamic> json) =>
    BleSecurityGate(
      service: json['service'] as String,
      writeChars: json['writeChars'] as String,
    );

Map<String, dynamic> _$BleSecurityGateToJson(BleSecurityGate instance) =>
    <String, dynamic>{
      'service': instance.service,
      'writeChars': instance.writeChars,
    };
