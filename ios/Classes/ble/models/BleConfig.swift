//
//  BleConfig.swift
//  flutter_ezw_ble
//
//  Created by Whiskee on 2025/1/3.
//

struct BleConfig: Codable {
    //  配置名称
    let name: String
    //  设备特性
    let privateServices: [BlePrivateService]
    //  SN解析规则
    let snRule: BleSnRule
    //  是否主动发起设备绑定
    let initiateBinding: Bool
    //  连接超时时间(ms)
    let connectTimeout: TimeInterval
    //  设备升级后启动新固件之前需要的时间，用于重连时
    let upgradeSwapTime: TimeInterval
    //  MAC地址解析规则
    let macRule: BleMacRule?
    
    init(name: String, privateServices: [BlePrivateService], snRule: BleSnRule, initiateBinding: Bool = false, connectTimeout: TimeInterval = 15000, upgradeSwapTime: TimeInterval = 60000, macRule: BleMacRule?) {
        self.name = name
        self.privateServices = privateServices
        assert(privateServices.contains { $0.type == 0 }, "Configuration must contain at least one UUID of common type")
        self.snRule = snRule
        self.initiateBinding = initiateBinding
        self.connectTimeout = connectTimeout
        self.upgradeSwapTime = upgradeSwapTime
        assert(connectTimeout > 10000, "The timeout period must be greater than 10000ms")
        self.macRule = macRule
    }
    
    static func empty() -> BleConfig {
        return BleConfig(name: "", privateServices: [], snRule: BleSnRule.empty(), macRule: nil)
    }
    
    /**
     *  不能为空对象：配置名称，ServiceUUID，SN 长度
     */
    func isEmpty() -> Bool {
        return name.isEmpty || privateServices.isEmpty
    }
}
