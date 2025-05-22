import 'package:flutter_ezw_ble/core/models/ble_mac_rule.dart';
import 'package:flutter_ezw_ble/core/models/ble_sn_rule.dart';
import 'package:flutter_ezw_utils/flutter_ezw_index.dart';

part 'ble_scan.g.dart';

@JsonSerializable()
class BleScan {
  //  设备名称过滤条件
  final List<String> nameFilters;
  //  SN设置了匹配规则
  final BleSnRule snRule;
  //  仅iOS使用，解析MAC地址
  final BleMacRule? macRule;
  //  组合设备数:总数, 如果为1，则不开启匹配模式，返回单个设备，如果大于2，则表示默认开启匹配模式，组成一个设备
  final int matchCount;

  BleScan(
    this.nameFilters,
    this.snRule, {
    this.macRule,
    this.matchCount = 1,
  })  : assert(nameFilters.isNotEmpty, "nameFilters is empty"),
        assert(matchCount > 0,
            "When matching mode is enabled, the number of matches must be greater than or equal to 1");

  factory BleScan.fromJson(Map<String, dynamic> json) =>
      _$BleScanFromJson(json);

  Map<String, dynamic> toJson() => _$BleScanToJson(this);

  Map<String, dynamic> customToJson() {
    final map = toJson();
    map["snRule"] = snRule.toJson();
    map["macRule"] = macRule?.toJson() ?? {};
    return map;
  }
}
