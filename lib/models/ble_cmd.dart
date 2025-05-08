import 'dart:typed_data';

import 'package:flutter_ezw_ble/core/tools/uuid_tyoe_converter.dart';
import 'package:flutter_ezw_ble/models/ble_uuid_type.dart';
import 'package:flutter_ezw_utils/extension/string_ext.dart';
import 'package:flutter_ezw_utils/json/unit8list_converter.dart';
import 'package:json_annotation/json_annotation.dart';

part 'ble_cmd.g.dart';

@JsonSerializable()
class BleCmd {
  final String uuid;
  @UuidTypeConverter()
  final BleUuidType type;
  @Uint8ListConverter()
  final Uint8List? data;
  final bool isSuccess;

  BleCmd(this.uuid, this.type, {this.data, this.isSuccess = false});

  factory BleCmd.fromJson(Map<String, dynamic> json) => _$BleCmdFromJson(json);

  Map<String, dynamic> toJson() => _$BleCmdToJson(this);

  static BleCmd receiveMap(Map data) {
    final base64 = data["data"] as String?;
    return BleCmd(
      data["uuid"],
      BleUuidTypeExt.label(data["type"]),
      data: base64?.encodeBase64(),
      isSuccess: data["isSuccess"],
    );
  }
}
