import 'package:flutter_ezw_ble/flutter_ezw_ble_event_channel.dart';
import 'package:flutter_ezw_ble/flutter_ezw_ble_method_channel.dart';
import 'package:flutter_ezw_ble/core/models/ble_cmd.dart';
import 'package:flutter_ezw_ble/core/models/ble_connect_model.dart';
import 'package:flutter_ezw_ble/core/models/ble_match_device.dart';
import 'package:flutter_ezw_ble/core/models/ble_status.dart';
import 'package:flutter_ezw_utils/extension/string_ext.dart';

const String ezwBleTag = "flutter_ezw_ble";

class EzwBle {
  static final EzwBle to = EzwBle._init();

  /// 原生方法回调
  MethodChannelEzwBle bleMC = MethodChannelEzwBle();

  /// 原生监听事件
  //  - 蓝牙状态
  Stream<BleState> bleStateEC =
      BleEventChannel.bleState.ec.map((data) => BleStateExt.from(data));
  //  - iOS日志
  Stream<String> blePrintEC = BleEventChannel.logger.ec.map((data) => data as String);
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

  /// 构造函数
  EzwBle._init();
}
