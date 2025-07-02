import 'dart:convert';

import 'package:flutter_ezw_ble/core/models/ble_private_service.dart';
import 'package:flutter_ezw_ble/core/models/ble_scan.dart';
import 'package:json_annotation/json_annotation.dart';

part 'ble_config.g.dart';

@JsonSerializable()
class BleConfig {
  final String name;
  //  如果设置了匹配规则
  final BleScan scan;
  //  可用私有服务
  final List<BlePrivateService> privateServices;
  //  是否要主动发送绑定
  final bool initiateBinding;
  //  毫秒
  final double connectTimeout;
  //  设备升级后启动新固件之前需要的时间，用于重连时
  final double upgradeSwapTime;
  //  仅Android使用
  final int mtu;

  BleConfig(
    this.name,
    this.scan,
    this.privateServices, {
    this.initiateBinding = false,
    this.connectTimeout = 15000,
    this.upgradeSwapTime = 60000,
    this.mtu = 247,
  });

  factory BleConfig.fromJson(Map<String, dynamic> json) =>
      _$BleConfigFromJson(json);

  Map<String, dynamic> toJson() => _$BleConfigToJson(this);

  Map<String, dynamic> customToJson() {
    final map = toJson();
    map["privateServices"] = privateServices.map((e) => e.toJson()).toList();
    map["scan"] = scan.customToJson();
    return map;
  }

  String toJsonString() => jsonEncode(toJson());
}
