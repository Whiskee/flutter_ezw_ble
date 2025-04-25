import 'package:flutter/services.dart';
import 'package:flutter_ezw_ble/flutter_ezw_index.dart';
import 'package:flutter_ezw_utils/flutter_ezw_index.dart';

/// 蓝牙EventChannel
enum BleEventChannel {
  bleState,
  scanResult,
  connectStatus,
  receiveData,
}

extension BleEventChannelExt on BleEventChannel {
  static final List<(BleEventChannel, Stream<dynamic>)> _bleECs = [];

  Stream<dynamic> get ec {
    final myEc = _bleECs.firstWhereOrNull((config) => config.$1 == this);
    if (myEc != null) {
      return myEc.$2;
    }
    final tag = "${ezwBleTag}_$name";
    final newEc = EventChannel(tag).receiveBroadcastStream(tag);
    _bleECs.add((this, newEc));
    return newEc;
  }
}
