import 'package:flutter_ezw_ble/flutter_ezw_index.dart';

extension BleDeviceExt on BleDevice {}

extension RxMatchDeviceExt on Rx<BleMatchDevice?> {
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
