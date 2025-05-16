import 'package:flutter_ezw_ble/models/ble_mac_rule.dart';
import 'package:flutter_ezw_ble/models/ble_sn_rule.dart';
import 'package:flutter_ezw_utils/flutter_ezw_index.dart';

part 'ble_scan.g.dart';

@JsonSerializable()
class BleScan {
  //  名字过滤条件
  final List<String> nameFilters;
  //  SN设置了匹配规则
  final BleSnRule snRule;
  //  仅iOS使用，解析MAC地址
  final BleMacRule? macRule;

  BleScan(
    this.nameFilters,
    this.snRule, {
    this.macRule,
  }) : assert(nameFilters.isNotEmpty, "nameFilters is empty");

  factory BleScan.fromJson(Map<String, dynamic> json) =>
      _$BleScanFromJson(json);

  Map<String, dynamic> toJson() => _$BleScanToJson(this);
}
