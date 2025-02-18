import 'package:mcumgr_flutter/mcumgr_flutter.dart';

class DfuUpdate {
  final String deviceId;
  //  更新工具
  final FirmwareUpdateManager updateManger;

  double _startTime = 0;
  double get startTime => _startTime;

  DfuUpdate(this.deviceId, this.updateManger) {
    _startTime = DateTime.now().millisecondsSinceEpoch.toDouble();
  }
}
