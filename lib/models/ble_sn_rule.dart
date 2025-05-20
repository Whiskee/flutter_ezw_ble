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
  //  筛选SN是否符合，避免非Even设备使用Even设备命名规则
  final List<String> filters;

  BleSnRule({
    this.byteLength = 0,
    this.startSubIndex = 0,
    this.replaceRex = "[\\x{00}-\\x{1F}\\x{7F}]",
    this.filters = const [],
  }) {
    assert(byteLength == 0 || (byteLength > 0 && byteLength > startSubIndex),
        "ByteLength must be greater than startSubIndex");
  }

  factory BleSnRule.fromJson(Map<String, dynamic> json) =>
      _$BleSnRuleFromJson(json);

  Map<String, dynamic> toJson() => _$BleSnRuleToJson(this);
}
