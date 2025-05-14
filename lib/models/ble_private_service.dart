import 'package:json_annotation/json_annotation.dart';

part 'ble_private_service.g.dart';

@JsonSerializable()
class BlePrivateService {
  final String service;
  final String writeChars;
  final String readChars;
  //  服务所属类型：0 = 基础服务，1 = OTA，其他由用户自定义
  final int type;

  BlePrivateService(
    this.service, {
    required this.writeChars,
    required this.readChars,
    this.type = 0,
  });

  factory BlePrivateService.fromJson(Map<String, dynamic> json) =>
      _$BlePrivateServiceFromJson(json);

  Map<String, dynamic> toJson() => _$BlePrivateServiceToJson(this);
}
