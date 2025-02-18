part of '../flutter_ezw_ble.dart';


const String ezwBleTag = "flutter_ezw_ble";

class EzwBle {
  static final EzwBle to = EzwBle._init();

  /// 原生方法回调
  MethodChannelEzwBle bleMC = MethodChannelEzwBle();

  /// 原生监听事件
  //  - 蓝牙状态
  Stream<BleState> bleStateEC =
      BleEventChannel.bleState.ec.map((data) => BleStateExt.from(data));
  //  - 蓝牙搜索结果
  Stream<BleMatchDevice> scanResultEC =
      BleEventChannel.scanResult.ec.map((data) {
    final jsonMap = (data as String? ?? "").toMap();
    return BleMatchDevice.fromJson(jsonMap);
  });
  //  - 开启连接后的流程
  Stream<BleConnectModel> connectStatusEC =
      BleEventChannel.connectStatus.ec.map((data) {
    //  1、获取设备连接状态
    final jsonMap = (data as String? ?? "").toMap();
    return BleConnectModel.fromJson(jsonMap);
  });
  //  - 蓝牙数据: 返回BleCmd中的data数据为 base64处理过的，需要自行解析成Uint8List
  Stream<BleCmd> receiveDataEC =
      BleEventChannel.receiveData.ec.map((data) => BleCmd.receiveMap(data));

  EzwBle._init() {
    //  1、监听蓝牙状态，如果蓝牙状态为不可用，则停止所有OTA升级
    bleStateEC.listen((state) {
      if (state != BleState.available) {
        DfuService.to.stopAllOTAUpdate();
      }
    });
    //  2、监听蓝牙数据: 如果是异常状态且正在OTA升级，则停止OTA升级
    connectStatusEC.listen((status) async {
      final isUpdating =
          await DfuService.to.checkDeviceIsOTAUpdating(status.uuid);
      if (status.connectState.isError && isUpdating) {
        DfuService.to.stopOTAUpdate(status.uuid);
      }
    });
  }
}
