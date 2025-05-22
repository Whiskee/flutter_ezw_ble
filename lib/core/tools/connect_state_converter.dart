import 'package:flutter_ezw_ble/core/models/ble_connect_state.dart';
import 'package:json_annotation/json_annotation.dart';

class ConnectStateListConverter
    implements JsonConverter<BleConnectState, String> {
  const ConnectStateListConverter();

  @override
  BleConnectState fromJson(String json) => BleConnectStateExt.label(json);

  @override
  String toJson(BleConnectState object) => object.name;
}
