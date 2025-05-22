import 'package:flutter_ezw_utils/flutter_ezw_index.dart';

part 'ble_mac_rule.g.dart';

/// 蓝牙MAC地址获取规则
/// - 仅iOS使用，iOS不提供MAC地址，可以通过广播内容获取MAC地址
@JsonSerializable()
class BleMacRule {
  final int startIndex;
  final int endIndex;
  //  - 是否反转
  final bool isReverse;
  BleMacRule(
    this.startIndex,
    this.endIndex, {
    this.isReverse = false,
  });

  factory BleMacRule.fromJson(Map<String, dynamic> json) =>
      _$BleMacRuleFromJson(json);

  Map<String, dynamic> toJson() => _$BleMacRuleToJson(this);
}
