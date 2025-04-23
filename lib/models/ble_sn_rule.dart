import 'package:json_annotation/json_annotation.dart';

part 'ble_sn_rule.g.dart';

@JsonSerializable()
class BleSnRule {
  //  总长度识别，如果为0，则表示适配所有长度, 不为0，则一定要比startSubIndex大
  final int byteLength;
  //  开始截断位置
  final int startSubIndex;
  //  自定义正则去除无效字符
  final String replaceRex;
  //  扫描设备时，只返回SN含有过滤标识的对象
  final List<String> scanFilterMarks;
  //  组合设备数:总数, 如果为1，则不开启匹配模式，返回单个设备，如果大于2，则表示默认开启匹配模式，组成一个设备
  final int matchCount;

  BleSnRule({
    this.byteLength = 0,
    this.startSubIndex = 0,
    this.replaceRex = "",
    this.scanFilterMarks = const [],
    this.matchCount = 1,
  }) {
    assert(byteLength == 0 || (byteLength > 0 && byteLength > startSubIndex), "ByteLength must be greater than startSubIndex");
    assert(matchCount > 0,
        "When matching mode is enabled, the number of matches must be greater than or equal to 1");
  }

  factory BleSnRule.fromJson(Map<String, dynamic> json) =>
      _$BleSnRuleFromJson(json);

  Map<String, dynamic> toJson() => _$BleSnRuleToJson(this);
}
