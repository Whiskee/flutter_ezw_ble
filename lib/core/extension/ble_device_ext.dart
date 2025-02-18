import 'package:flutter_ezw_ble/models/ble_connect_model.dart';
import 'package:flutter_ezw_ble/models/ble_connect_state.dart';
import 'package:flutter_ezw_ble/models/ble_device.dart';
import 'package:flutter_ezw_ble/models/ble_match_device.dart';
import 'package:flutter_ezw_utils/extension/list_ext.dart';
import 'package:flutter_ezw_utils/extension/rxdart_ext.dart';

extension BleDeviceExt on BleDevice {}

extension RxMatchDevice on Rx<BleMatchDevice?> {
  void update(BleConnectModel connectModel) {
    //  1、如果没有匹配的对象，直接返回
    final oldDevice = value?.copy();
    if (oldDevice == null) {
      return;
    }
    //  2、更新当前连接状态
    final device = oldDevice.devices
        .firstWhereOrNull((device) => device.uuid == connectModel.uuid);
    device?.connectState = connectModel.connectState;
    value = oldDevice;
  }

  void otaUpgrading(String uuid) =>
      update(BleConnectModel(uuid, BleConnectState.upgrade));
}
