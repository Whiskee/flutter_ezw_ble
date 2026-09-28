import 'dart:typed_data';
import 'ble_receive_identity.dart';

import 'package:flutter_ezw_utils/extension/string_ext.dart';
import 'package:flutter_ezw_utils/json/unit8list_converter.dart';
import 'package:json_annotation/json_annotation.dart';

part 'ble_cmd.g.dart';

@JsonSerializable(explicitToJson: true)
class BleCmd {
  final String uuid;
  final int psType;
  @Uint8ListConverter()
  final Uint8List? data;
  final bool isSuccess;
  final int sessionGeneration;
  final int attemptGeneration;
  final String otaTransactionId;
  final int otaGeneration;
  final String otaInstanceId;

  /// Original native source, never inferred from the current UUID at delivery.
  @JsonKey(fromJson: BleReceiveIdentity.fromJson)
  final BleReceiveIdentity? receiveIdentity;

  BleCmd(
    this.uuid,
    this.psType, {
    this.receiveIdentity,
    this.data,
    this.isSuccess = false,
    this.sessionGeneration = 0,
    this.attemptGeneration = 0,
    this.otaTransactionId = '',
    this.otaGeneration = 0,
    this.otaInstanceId = '',
  });

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
    final sessionGeneration = data["sessionGeneration"];
    final attemptGeneration = data["attemptGeneration"];
    final otaTransactionId = data["otaTransactionId"];
    final otaGeneration = data["otaGeneration"];
    final otaInstanceId = data["otaInstanceId"];
    final receiveIdentity = data["receiveIdentity"];
    return BleCmd(
      uuid is String ? uuid : uuid?.toString() ?? "",
      psType is num ? psType.toInt() : 0,
      data: bytes,
      isSuccess: isSuccess is bool ? isSuccess : false,
      sessionGeneration:
          sessionGeneration is num ? sessionGeneration.toInt() : 0,
      attemptGeneration:
          attemptGeneration is num ? attemptGeneration.toInt() : 0,
      otaTransactionId: otaTransactionId is String ? otaTransactionId : '',
      otaGeneration: otaGeneration is num ? otaGeneration.toInt() : 0,
      otaInstanceId: otaInstanceId is String ? otaInstanceId : '',
      // Native receive admission is an independently nullable proof. Never
      // infer it from the legacy/OTA command pair on the outer event map.
      receiveIdentity: BleReceiveIdentity.fromJson(receiveIdentity),
    );
  }
}
