// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'ble_mac_rule.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

BleMacRule _$BleMacRuleFromJson(Map<String, dynamic> json) => BleMacRule(
      (json['startIndex'] as num).toInt(),
      (json['endIndex'] as num).toInt(),
      isReverse: json['isReverse'] as bool? ?? false,
    );

Map<String, dynamic> _$BleMacRuleToJson(BleMacRule instance) =>
    <String, dynamic>{
      'startIndex': instance.startIndex,
      'endIndex': instance.endIndex,
      'isReverse': instance.isReverse,
    };
