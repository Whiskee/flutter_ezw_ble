enum BleUuidType {
  // 通用
  common,
  // 大数据
  largeData,
  // 流式数据
  streaming,
  // OTA
  ota,
}

extension BleUuidTypeExt on BleUuidType {
  static BleUuidType label(String label) {
    switch (label) {
      case "largeData":
        return BleUuidType.largeData;
      case "streaming":
        return BleUuidType.streaming;
      case "ota":
        return BleUuidType.ota;
      default:
        return BleUuidType.common;
    }
  }

  bool get isCommon => this == BleUuidType.common;
  bool get isLargeData => this == BleUuidType.largeData;
  bool get isStreaming => this == BleUuidType.streaming;
  bool get isOta => this == BleUuidType.ota;
}
