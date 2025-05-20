//
//  BleScan.swift
//  flutter_ezw_ble
//
//  Created by Whiskee on 2025/5/16.
//

class BleScan: Codable {
    //  设备名称过滤条件
    let nameFilters: Array<String>
    //  设备SN解析规则
    let snRule: BleSnRule
    //  MAC解析规则
    let macRule: BleMacRule?
    //  组合设备数:总数，如果为1不执行匹配，返回单个设备，如果大于2则默认开启匹配模式
    let matchCount: Int
    
    init(nameFilters: Array<String>, snRule: BleSnRule, macRule: BleMacRule?, matchCount: Int) {
        self.nameFilters = nameFilters
        self.snRule = snRule
        self.macRule = macRule
        self.matchCount = matchCount
    }
    
    static func empty() -> BleScan {
        return BleScan(nameFilters: [], snRule: BleSnRule.empty(), macRule: nil, matchCount: 0)
    }
}
