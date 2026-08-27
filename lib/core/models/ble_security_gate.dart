import 'package:json_annotation/json_annotation.dart';

part 'ble_security_gate.g.dart';

@JsonSerializable()
class BleSecurityGate {
  final String service;
  final String writeChars;

  const BleSecurityGate({required this.service, required this.writeChars});

  factory BleSecurityGate.fromJson(Map<String, dynamic> json) =>
      _$BleSecurityGateFromJson(json);

  Map<String, dynamic> toJson() => _$BleSecurityGateToJson(this);
}
