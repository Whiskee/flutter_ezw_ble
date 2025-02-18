import 'package:json_annotation/json_annotation.dart';

part 'ble_sn_rule.g.dart';

@JsonSerializable()
class BleSnRule {
  //  总长度识别，如果为0，则表示适配所有长度
  final int byteLength;
  //  开始截断位置
  final int startSubIndex;
  //  自定义正则去除无效字符
  final String replaceRex;
  //  扫描设备时，只返回SN含有过滤标识的对象
  final List<String> scanFilterMarks;
  //  是否开启SN匹配
  final bool isMatchBySn;
  //  组合设备数:总数
  final int matchCount;

  BleSnRule({
    this.byteLength = 0,
    this.startSubIndex = 0,
    this.replaceRex = "",
    this.scanFilterMarks = const [],
    this.isMatchBySn = false,
    this.matchCount = 1,
  }) {
    assert(isMatchBySn && matchCount >= 1, "When matching mode is enabled, the number of matches must be greater than or equal to 1");
  }

  factory BleSnRule.fromJson(Map<String, dynamic> json) =>
      _$BleSnRuleFromJson(json);

  Map<String, dynamic> toJson() => _$BleSnRuleToJson(this);
}
