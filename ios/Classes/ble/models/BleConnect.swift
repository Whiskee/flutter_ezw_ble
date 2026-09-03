//
//  BleConnectState.swift
//  flutter_ezw_ble
//
//  特别说明：
//  1、本连接流程是系统蓝牙连接的标准流程，如有业务上的连接需求，请在Connected完成后自行处理
//  2、iOS没有主动发起配对的方法，配对过程是系统自动处理（如果支持）
//
//  Created by Whiskee on 2025/1/4.
//

struct BleConnectModel: Codable {
    var uuid: String
    var name: String
    var connectState: BleConnectState
    var mtu: Int = 247
    var source: BleConnectSource = .unknown
    var sessionGeneration: Int64 = 0
    var attemptGeneration: Int64 = 0
    var nativeTrace: BleNativeConnectionTrace?

    /// Backward-compatible alias for older Dart consumers.
    var generation: Int64 { sessionGeneration }

    init(
        uuid: String,
        name: String,
        connectState: BleConnectState,
        mtu: Int = 247,
        source: BleConnectSource = .unknown,
        generation: Int64 = 0,
        sessionGeneration: Int64? = nil,
        attemptGeneration: Int64 = 0,
        nativeTrace: BleNativeConnectionTrace? = nil
    ) {
        self.uuid = uuid
        self.name = name
        self.connectState = connectState
        self.mtu = mtu
        self.source = source
        self.sessionGeneration = sessionGeneration ?? generation
        self.attemptGeneration = attemptGeneration
        self.nativeTrace = nativeTrace
    }

    enum CodingKeys: String, CodingKey {
        case uuid
        case name
        case connectState
        case mtu
        case source
        case generation
        case sessionGeneration
        case attemptGeneration
        case nativeTrace
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try container.decode(String.self, forKey: .uuid)
        name = try container.decode(String.self, forKey: .name)
        connectState = try container.decode(BleConnectState.self, forKey: .connectState)
        mtu = try container.decodeIfPresent(Int.self, forKey: .mtu) ?? 247
        source = try container.decodeIfPresent(BleConnectSource.self, forKey: .source) ?? .unknown
        sessionGeneration = try container.decodeIfPresent(Int64.self, forKey: .sessionGeneration)
            ?? container.decodeIfPresent(Int64.self, forKey: .generation)
            ?? 0
        attemptGeneration = try container.decodeIfPresent(Int64.self, forKey: .attemptGeneration) ?? 0
        nativeTrace = try container.decodeIfPresent(BleNativeConnectionTrace.self, forKey: .nativeTrace)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(uuid, forKey: .uuid)
        try container.encode(name, forKey: .name)
        try container.encode(connectState, forKey: .connectState)
        try container.encode(mtu, forKey: .mtu)
        try container.encode(source, forKey: .source)
        try container.encode(sessionGeneration, forKey: .generation)
        try container.encode(sessionGeneration, forKey: .sessionGeneration)
        try container.encode(attemptGeneration, forKey: .attemptGeneration)
        try container.encodeIfPresent(nativeTrace, forKey: .nativeTrace)
    }
}

/// 与 Dart `BleConnectSource` raw value 一致；未知未来值解码时回退 unknown。
enum BleConnectSource: String, Codable {
    case unknown
    case autoReconnect
    case manualReconnect
    case foreground

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self = BleConnectSource(rawValue: (try? container.decode(String.self)) ?? "") ?? .unknown
    }
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
    //  错误：蓝牙异常
    case bleError
    //  错误：系统错误
    case systemError
    // iOS 自动安全恢复耗尽。它是 native 资源终态，但不是 App 可见错误；
    // Dart/even_connect 会显式消费该状态并保持 UI 静默。
    case securityRecoveryExhausted
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
     *  是否纯连接成功
     */
    func isPureConnected() -> Bool {
        return self == .connected
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
        self == .timeout ||
        self == .bleError ||
        self == .systemError
    }
}
