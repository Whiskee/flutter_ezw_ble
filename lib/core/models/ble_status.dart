enum BleState {
  available,
  powerOff,
  unauthorized,
  noLocation,

  /// iOS CoreBluetooth transport 正在重置；保持 unknown 兼容语义，但允许诊断层观测。
  resetting,
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
      case 1:
        return BleState.resetting;
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

  /// resetting 仍是瞬时不可判定态，业务门禁必须沿用历史 unknown 行为。
  bool get isBleUnknown =>
      this == BleState.unknown || this == BleState.resetting;
}
