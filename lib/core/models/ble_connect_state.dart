enum BleConnectState {
  //  步骤1：执行连接
  connecting,
  //  步骤2: 获取连接设备回复
  contactDevice,
  //  步骤3: 搜索设备服务特征
  searchService,
  //  步骤4: 获取服务读写特征
  searchChars,
  //  步骤5: 发起绑定
  startBinding,
  //  步骤5: 特征获取完毕，连接流程完成
  connectFinish,
  //  错误码：
  //  主动断连
  disconnectByUser,
  //  系统断连
  disconnectFromSys,
  //  未发现相应的蓝牙配置
  noBleConfigFound,
  //  空的UUID
  emptyUuid,
  //  未发现设备
  noDeviceFound,
  //  已经被绑定
  alreadyBound,
  //  绑定失败
  boundFail,
  //  获取服务发现失败
  serviceFail,
  //  获取读写特征失败
  charsFail,
  //  连接超时
  timeout,
  //  已连接
  connected,
  //  升级状态
  upgrade,
  //  无状态
  none,
}

extension BleConnectStateExt on BleConnectState {
  static BleConnectState label(String label) {
    switch (label) {
      case "connecting":
        return BleConnectState.connecting;
      case "contactDevice":
        return BleConnectState.contactDevice;
      case "searchService":
        return BleConnectState.searchService;
      case "searchChars":
        return BleConnectState.searchChars;
      case "startBinding":
        return BleConnectState.startBinding;
      case "connectFinish":
        return BleConnectState.connectFinish;
      case "disconnectByUser":
        return BleConnectState.disconnectByUser;
      case "disconnectFromSys":
        return BleConnectState.disconnectFromSys;
      case "emptyUuid":
        return BleConnectState.emptyUuid;
      case "noDeviceFound":
        return BleConnectState.noDeviceFound;
      case "alreadyBound":
        return BleConnectState.alreadyBound;
      case "boundFail":
        return BleConnectState.boundFail;
      case "serviceFail":
        return BleConnectState.serviceFail;
      case "charsFail":
        return BleConnectState.charsFail;
      case "timeout":
        return BleConnectState.timeout;
      case "connected":
        return BleConnectState.connected;
      case "upgrade":
        return BleConnectState.upgrade;
      default:
        return BleConnectState.none;
    }
  }

  //  空状态
  bool get isNone => this == BleConnectState.none;

  //  连接流程：连接中
  bool get isConnecting =>
      this == BleConnectState.connecting ||
      this == BleConnectState.contactDevice ||
      this == BleConnectState.searchService ||
      this == BleConnectState.searchChars ||
      this == BleConnectState.startBinding ||
      this == BleConnectState.connectFinish;

  //  连接流程：连接最后一步
  bool get isConnectFinish => this == BleConnectState.connectFinish;

  //  连接流程：连接成功(ota升级也是连接成功的状态)
  bool get isConnected =>
      this == BleConnectState.connected || this == BleConnectState.upgrade;

  //  连接流程：纯连接状态
  bool get isPureConnected => this == BleConnectState.connected;

  //  是否断连
  bool get isDisconnected =>
      this == BleConnectState.none ||
      this == BleConnectState.disconnectByUser ||
      this == BleConnectState.disconnectFromSys;

  //  是否系统断连
  bool get isDisconnectFromSys => this == BleConnectState.disconnectFromSys;

  //  是否连接错误
  bool get isConnectError =>
      this == BleConnectState.serviceFail ||
      this == BleConnectState.charsFail ||
      this == BleConnectState.timeout;

  //  连接异常状态
  bool get isError =>
      this == BleConnectState.emptyUuid ||
      this == BleConnectState.noDeviceFound ||
      this == BleConnectState.alreadyBound ||
      this == BleConnectState.boundFail ||
      this == BleConnectState.serviceFail ||
      this == BleConnectState.charsFail ||
      this == BleConnectState.timeout;

  //  是否在升级模式
  bool get isUpgrade => this == BleConnectState.upgrade;
}
