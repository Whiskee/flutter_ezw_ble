enum BleUuidType {
  // 通用
  common,
  // 大数据
  largeData,
  // OTA
  ota,
}

extension BleUuidTypeExt on BleUuidType {
  static BleUuidType label(String label) {
    switch (label) {
      case "largeData":
        return BleUuidType.largeData;
      case "ota":
        return BleUuidType.ota;
      default:
        return BleUuidType.common;
    }
  }
}
