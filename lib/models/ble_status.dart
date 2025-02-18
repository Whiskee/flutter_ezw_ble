enum BleState {
  available,
  powerOff,
  unauthorized,
  noLocation,
  unknown,
}

extension BleStateExt on BleState {
  ///
  /// 引用iOS蓝牙状态值：
  /// - unknown = 0
  /// - resetting = 1
  /// - unsupported = 2
  /// - unauthorized = 3
  /// - poweredOff = 4
  /// - poweredOn = 5
  /// - noLocation = 6 （仅Android使用，Android蓝牙搜索需要位置信息权限）
  ///
  static BleState from(int status) {
    switch (status) {
      case 3:
        return BleState.unauthorized;
      case 4:
        return BleState.powerOff;
      case 5:
        return BleState.available;
      case 6:
        return BleState.noLocation;
      default:
        return BleState.unknown;
    }
  }

  bool get isBleAvailable => this == BleState.available;
  bool get isBleOff => this == BleState.powerOff;
  bool get isBleUnauthorized => this == BleState.unauthorized;
  bool get isBleNoLocation => this == BleState.noLocation;
  bool get isBleUnknown => this == BleState.unknown;
}
