import 'dart:convert';

import 'package:flutter_ezw_ble/models/ble_sn_rule.dart';
import 'package:flutter_ezw_ble/models/ble_uuid.dart';
import 'package:json_annotation/json_annotation.dart';

part 'ble_config.g.dart';

@JsonSerializable()
class BleConfig {
  final String name;
  final BleUUID uuid;
  //  如果设置了匹配规则
  final BleSnRule snRule;
  //  毫秒
  final double connectTimeout;
  //  设备升级后启动新固件之前需要的时间，用于重连时
  final double upgradeSwapTime;
  //  仅Android使用
  final int mtu;

  BleConfig(
    this.name,
    this.uuid,
    this.snRule, {
    this.connectTimeout = 15000,
    this.upgradeSwapTime = 60000,
    this.mtu = 255,
  });

  factory BleConfig.fromJson(Map<String, dynamic> json) =>
      _$BleConfigFromJson(json);

  Map<String, dynamic> toJson() => _$BleConfigToJson(this);

  Map<String, dynamic> customToJson() {
    final map = toJson();
    map["uuid"] = uuid.toJson();
    map["snRule"] = snRule.toJson();
    return map;
  }

  String toJsonString() => jsonEncode(toJson());
}
