// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'ble_scan.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

BleScan _$BleScanFromJson(Map<String, dynamic> json) => BleScan(
      (json['nameFilters'] as List<dynamic>).map((e) => e as String).toList(),
      snRule: json['snRule'] == null
          ? null
          : BleSnRule.fromJson(json['snRule'] as Map<String, dynamic>),
      macRule: json['macRule'] == null
          ? null
          : BleMacRule.fromJson(json['macRule'] as Map<String, dynamic>),
      matchCount: (json['matchCount'] as num?)?.toInt() ?? 1,
    );

Map<String, dynamic> _$BleScanToJson(BleScan instance) => <String, dynamic>{
      'nameFilters': instance.nameFilters,
      'snRule': instance.snRule,
      'macRule': instance.macRule,
      'matchCount': instance.matchCount,
    };
