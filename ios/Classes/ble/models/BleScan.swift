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
    
    static func empty() -> BleScan {
        return BleScan(nameFilters: [], snRule: BleSnRule.empty(), macRule: nil)
    }
}
