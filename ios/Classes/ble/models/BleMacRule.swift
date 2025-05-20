//
//  BleMacRule.swift
//  flutter_ezw_ble
//
//  Created by Whiskee on 2025/4/28.
//

/// 获取蓝牙MAC地址解析规则
struct BleMacRule: Codable {
    let startIndex: Int
    let endIndex: Int
    //  是否反转
    var isReverse: Bool = false
}
