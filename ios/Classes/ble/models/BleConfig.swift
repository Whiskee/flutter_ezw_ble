//
//  BleConfig.swift
//  EvenConnect
//
//  Created by Whiskee on 2025/1/3.
//

struct BleConfig: Codable {
    //  配置名称
    let name: String
    //  设备特性
    let uuid: BleUUID
    //  SN解析规则
    let snRule: BleSnRule
    //  连接超时时间(ms)
    let connectTimeout: TimeInterval
    //  设备升级后启动新固件之前需要的时间，用于重连时
    let upgradeSwapTime: TimeInterval
    
    init(name: String, uuid: BleUUID, snRule: BleSnRule, isScanByServiceUUID: Bool = false, connectTimeout: TimeInterval = 15000, upgradeSwapTime: TimeInterval = 60000) {
        self.name = name
        self.uuid = uuid
        self.snRule = snRule
        self.connectTimeout = connectTimeout
        self.upgradeSwapTime = upgradeSwapTime
        assert(connectTimeout > 10000, "The timeout period must be greater than 10000ms")
    }
    
    static func empty() -> BleConfig {
        return BleConfig(name: "", uuid: BleUUID(service: ""), snRule: BleSnRule.empty())
    }
    
    /**
     *  不能为空对象：配置名称，ServiceUUID，SN 长度
     */
    func isEmpty() -> Bool {
        return name.isEmpty || uuid.service.isEmpty
    }
}
