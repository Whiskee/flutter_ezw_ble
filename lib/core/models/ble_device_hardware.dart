import 'dart:typed_data';

class BleDeviceHardware {
  //  master电量状态，0~100
  int batteryStatus0 = 0;
  //  slave电量状态，0~100
  int batteryStatus1 = 0;
  //  充电电压，实际电压 = (V + 200) / 100
  double chargingVBat = 0;
  //  充电电流，充电 < 128， 放电 > 128
  int chargingCurrent = 0;
  //  充电温度，0~100（摄氏度）
  int chargingTemp = 0;
  //  dev_ver0~5 设备软件版本号
  int devVer0 = 0;
  int devVer1 = 0;
  int devVer2 = 0;
  int devVer3 = 0;
  int devVer4 = 0;
  int devVer5 = 0;
  //  flash_ver0~1 flash 版本号
  int flashVer0 = 0;
  int flashVer1 = 0;
  //  master/slave硬件版本号
  int mHwVer = 0;
  int sHwVer = 0;
  //  ble_ver0~1 ble 软件版本号(未启用)
  int bleVer0 = 0;
  int bleVer1 = 0;
  //  ble_ver0~1 ble 硬件版本号(未启用)
  int bleHwVer = 0;

  /// 非眼镜信息数据
  //  - 启动时间
  int bootSeconds = 0;
  //  - 是否是主设备
  bool isMaster = false;
  //  - 是否获取眼镜信息成功
  bool isSuccess = false;

  //  系统版本号:（跟devVer0～5字段能力一致，区别是不用拼装， 当前主要给G2使用）
  String version = "";

  //* ============== Get ============== *//
  //  - 获取设备版本
  String get deviceVer =>
      isMaster ? "$devVer0.$devVer1.$devVer2" : "$devVer3.$devVer4.$devVer5";
  //  - 版本号是否正确
  bool get versionCorrect => deviceVer != "0.0.0";

  BleDeviceHardware();

  /// 自定义构建函数： 从字节数组中解析数据
  ///
  /// - data 字节数组
  /// - isMaster 是否是主设备(右腿为主设备
  ///
  BleDeviceHardware.fromByte(Uint8List data, bool isMaster) {
    isMaster = isMaster;
    batteryStatus0 = data[2].toInt();
    batteryStatus1 = data[3].toInt();
    chargingVBat = (data[4].toDouble() + 200) / 100;
    chargingCurrent = data[5].toInt() - 128; //mA
    chargingTemp = data[6].toInt(); //0~100（摄氏度）
    devVer0 = data[7].toInt();
    devVer1 = data[8].toInt();
    devVer2 = data[9].toInt();
    devVer3 = data[10].toInt();
    devVer4 = data[11].toInt();
    devVer5 = data[12].toInt();
    flashVer0 = data[13].toInt();
    flashVer1 = data[14].toInt();
    mHwVer = data[15].toInt();
    sHwVer = data[16].toInt();
    bleVer0 = data[17].toInt();
    bleVer1 = data[18].toInt();
    bleHwVer = data[19].toInt();
    isSuccess = true;
  }

  /// 复制硬件信息
  BleDeviceHardware copy() => BleDeviceHardware()
    ..isMaster = isMaster
    ..batteryStatus0 = batteryStatus0
    ..batteryStatus1 = batteryStatus1
    ..chargingVBat = chargingVBat
    ..chargingCurrent = chargingCurrent
    ..chargingTemp = chargingTemp
    ..devVer0 = devVer0
    ..devVer1 = devVer1
    ..devVer2 = devVer2
    ..devVer3 = devVer3
    ..devVer4 = devVer4
    ..devVer5 = devVer5
    ..flashVer0 = flashVer0
    ..flashVer1 = flashVer1
    ..mHwVer = mHwVer
    ..sHwVer = sHwVer
    ..bleVer0 = bleVer0
    ..bleVer1 = bleVer1
    ..bleHwVer = bleHwVer
    ..isSuccess = isSuccess;
}
