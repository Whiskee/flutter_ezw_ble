//
//  BleConfig.swift
//  flutter_ezw_ble
//
//  Created by Whiskee on 2025/1/3.
//

struct BleConfig: Codable {
    //  配置名称
    let name: String
    //  搜索条件
    let scan: BleScan
    //  设备特性
    let privateServices: [BlePrivateService]
    //  是否主动发起设备绑定
    let initiateBinding: Bool
    //  连接超时时间(ms)
    let connectTimeout: TimeInterval
    //  设备升级后启动新固件之前需要的时间，用于重连时
    let upgradeSwapTime: TimeInterval
    //  是否启用原生自动回连
    let autoReconnect: Bool
    //  自动回连退避计数兼容字段；当前实现不把次数作为停止条件
    let autoReconnectMaxAttempts: Int
    //  是否允许平台被动回连能力
    let autoReconnectUseNativePassive: Bool
    
    init(
        name: String,
        scan: BleScan,
        privateServices: [BlePrivateService],
        initiateBinding: Bool = false,
        connectTimeout: TimeInterval = 15000,
        upgradeSwapTime: TimeInterval = 60000,
        autoReconnect: Bool = false,
        autoReconnectMaxAttempts: Int = 0,
        autoReconnectUseNativePassive: Bool = true
    ) {
        self.name = name
        self.scan = scan
        self.privateServices = privateServices
        assert(privateServices.contains { $0.type == 0 }, "Configuration must contain at least one UUID of common type")
        self.initiateBinding = initiateBinding
        self.connectTimeout = connectTimeout
        self.upgradeSwapTime = upgradeSwapTime
        self.autoReconnect = autoReconnect
        self.autoReconnectMaxAttempts = autoReconnectMaxAttempts
        self.autoReconnectUseNativePassive = autoReconnectUseNativePassive
        assert(connectTimeout > 10000, "The timeout period must be greater than 10000ms")
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case scan
        case privateServices
        case initiateBinding
        case connectTimeout
        case upgradeSwapTime
        case autoReconnect
        case autoReconnectMaxAttempts
        case autoReconnectUseNativePassive
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            name: try container.decode(String.self, forKey: .name),
            scan: try container.decode(BleScan.self, forKey: .scan),
            privateServices: try container.decode([BlePrivateService].self, forKey: .privateServices),
            initiateBinding: try container.decodeIfPresent(Bool.self, forKey: .initiateBinding) ?? false,
            connectTimeout: try container.decodeIfPresent(TimeInterval.self, forKey: .connectTimeout) ?? 15000,
            upgradeSwapTime: try container.decodeIfPresent(TimeInterval.self, forKey: .upgradeSwapTime) ?? 60000,
            autoReconnect: try container.decodeIfPresent(Bool.self, forKey: .autoReconnect) ?? false,
            autoReconnectMaxAttempts: try container.decodeIfPresent(Int.self, forKey: .autoReconnectMaxAttempts) ?? 0,
            autoReconnectUseNativePassive: try container.decodeIfPresent(Bool.self, forKey: .autoReconnectUseNativePassive) ?? true
        )
    }
    
    static func empty() -> BleConfig {
        return BleConfig(name: "", scan: BleScan.empty(), privateServices: [])
    }
    
    /**
     *  不能为空对象：配置名称，ServiceUUID，SN 长度
     */
    func isEmpty() -> Bool {
        return name.isEmpty || privateServices.isEmpty
    }
}
