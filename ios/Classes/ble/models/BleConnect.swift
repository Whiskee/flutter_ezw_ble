//
//  BleConnectState.swift
//  EvenConnect
//
//  特别说明：
//  1、本连接流程是系统蓝牙连接的标准流程，如有业务上的连接需求，请在Connected完成后自行处理
//  2、iOS没有主动发起配对的方法，配对过程是系统自动处理（如果支持）
//
//  Created by Whiskee on 2025/1/4.
//

struct BleConnectModel: Codable {
    var uuid: String
    var connectState: BleConnectState
}

enum BleConnectState: String, Codable {
    //  步骤1：执行连接
    case connecting
    //  步骤2: 获取连接设备回复
    case contactDevice
    //  步骤3: 搜索设备服务特征
    case searchService
    //  步骤4: 获取服务读写特征
    case searchChars
    //  步骤5: 开始绑定
    case startBinding
    //  步骤6: 特征获取完毕，连接流程完成
    case connectFinish
    //  错误：用户主动断连
    case disconnectByUser
    //  错误：系统断连
    case disconnectFromSys
    //  错误：空的UUID
    case emptyUuid
    //  错误：找不到蓝牙配置
    case noBleConfigFound
    //  错误：设备没被发现
    case noDeviceFound
    //  错误：已经被绑定
    case alreadyBound
    //  错误：绑定失败
    case boundFail
    //  错误：获取服务发现失败
    case serviceFail
    //  错误：获取读写特征失败
    case charsFail
    //  错误：连接超时
    case timeout
    //  连接成功：
    //  - 由于不同设备连接成功标准不通，所以不主动返回连接成功
    //  - 提供了setConnected，由用户告知是否连接成功
    case connected
    //  升级模式
    case upgrade
    
    /**
     *  是否正在连接中
     */
    func isConnecting() -> Bool {
        return self == .connecting ||
        self == .contactDevice ||
        self == .searchService ||
        self == .searchChars ||
        self == .startBinding ||
        self == .connectFinish
    }
    
    /**
     *  是否连接成功
     */
    func isConnected() -> Bool {
        return self == .connected || self == .upgrade
    }
    
    /**
     *  是否断连
     */
    func isDisconnected() -> Bool {
        return self == .disconnectByUser ||
        self == .disconnectFromSys
    }

    /**
     *  是否错误请求
     */
    func isError() -> Bool {
        return self == .emptyUuid ||
        self == .noDeviceFound ||
        self == .alreadyBound ||
        self == .boundFail ||
        self == .serviceFail ||
        self == .charsFail ||
        self == .timeout
    }
}
