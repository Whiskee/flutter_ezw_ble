import 'dart:convert';

import 'package:flutter_ezw_ble/models/ble_mac_rule.dart';
import 'package:flutter_ezw_ble/models/ble_sn_rule.dart';
import 'package:flutter_ezw_ble/models/ble_uuid.dart';
import 'package:json_annotation/json_annotation.dart';

part 'ble_config.g.dart';

@JsonSerializable()
class BleConfig {
  final String name;
  //  可用UUID
  final List<BleUuid> uuids;
  //  如果设置了匹配规则
  final BleSnRule snRule;
  //  毫秒
  final double connectTimeout;
  //  设备升级后启动新固件之前需要的时间，用于重连时
  final double upgradeSwapTime;
  //  仅iOS使用，解析MAC地址
  final BleMacRule? macRule;
  //  仅Android使用
  final int mtu;

  BleConfig(
    this.name,
    this.uuids,
    this.snRule, {
    this.connectTimeout = 15000,
    this.upgradeSwapTime = 60000,
    this.macRule,
    this.mtu = 512,
  });

  factory BleConfig.fromJson(Map<String, dynamic> json) =>
      _$BleConfigFromJson(json);

  Map<String, dynamic> toJson() => _$BleConfigToJson(this);

  Map<String, dynamic> customToJson() {
    final map = toJson();
    map["uuids"] = uuids.map((e) => e.toJson()).toList();
    map["snRule"] = snRule.toJson();
    map["macRule"] = macRule?.toJson();
    return map;
  }

  String toJsonString() => jsonEncode(toJson());
}
