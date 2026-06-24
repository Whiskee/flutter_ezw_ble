import 'dart:typed_data';

import 'package:flutter_ezw_utils/extension/string_ext.dart';
import 'package:flutter_ezw_utils/json/unit8list_converter.dart';
import 'package:json_annotation/json_annotation.dart';

part 'ble_cmd.g.dart';

@JsonSerializable()
class BleCmd {
  final String uuid;
  final int psType;
  @Uint8ListConverter()
  final Uint8List? data;
  final bool isSuccess;

  BleCmd(this.uuid, this.psType, {this.data, this.isSuccess = false});

  factory BleCmd.fromJson(Map<String, dynamic> json) => _$BleCmdFromJson(json);

  Map<String, dynamic> toJson() => _$BleCmdToJson(this);

  static BleCmd receiveMap(Map data) {
    final rawData = data["data"] ?? data["c"] ?? data["g"];
    Uint8List? bytes;
    if (rawData is String && rawData.isNotEmpty) {
      try {
        bytes = rawData.encodeBase64();
      } catch (_) {
        bytes = null;
      }
    } else if (rawData is Uint8List) {
      bytes = rawData;
    } else if (rawData is List) {
      bytes = Uint8List.fromList(
        rawData.whereType<num>().map((item) => item.toInt()).toList(),
      );
    }
    final psType = data["psType"] ?? data["b"] ?? data["f"];
    final isSuccess = data["isSuccess"] ?? data["d"] ?? data["h"];
    final uuid = data["uuid"] ?? data["a"] ?? data["e"];
    return BleCmd(
      uuid is String ? uuid : uuid?.toString() ?? "",
      psType is num ? psType.toInt() : 0,
      data: bytes,
      isSuccess: isSuccess is bool ? isSuccess : false,
    );
  }
}
