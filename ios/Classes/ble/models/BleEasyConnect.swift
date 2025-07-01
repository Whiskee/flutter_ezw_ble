//
//  BleEasyConnect.swift
//  flutter_ezw_ble
//
//  Created by Whiskee on 2025/6/30.
//

/// 简单连接参数
struct BleEasyConnect: Codable {
    let belongConfig: String
    let uuid: String
    let name: String
    var afterUpgrade: Bool = false
    var time: TimeInterval?
    
    /// 非JSON数据
    var bleConfig: BleConfig?
    
    init(configName: String, uuid: String, name: String, afterUpgrade: Bool = false, time: TimeInterval? = nil) {
        self.belongConfig = configName
        self.uuid = uuid
        self.name = name
        self.afterUpgrade = afterUpgrade
        self.time = time
    }
}
