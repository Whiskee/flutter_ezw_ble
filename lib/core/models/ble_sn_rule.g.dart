// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'ble_sn_rule.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

BleSnRule _$BleSnRuleFromJson(Map<String, dynamic> json) => BleSnRule(
      byteLength: (json['byteLength'] as num?)?.toInt() ?? 0,
      startSubIndex: (json['startSubIndex'] as num?)?.toInt() ?? 0,
      replaceRex: json['replaceRex'] as String? ?? "[\\x{00}-\\x{1F}\\x{7F}]",
      filters: (json['filters'] as List<dynamic>?)
              ?.map((e) => e as String)
              .toList() ??
          const [],
    );

Map<String, dynamic> _$BleSnRuleToJson(BleSnRule instance) => <String, dynamic>{
      'byteLength': instance.byteLength,
      'startSubIndex': instance.startSubIndex,
      'replaceRex': instance.replaceRex,
      'filters': instance.filters,
    };
