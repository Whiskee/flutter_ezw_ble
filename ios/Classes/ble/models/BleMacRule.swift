//
//  BleMacRule.swift
//  flutter_ezw_ble
//
//  Created by Whiskee on 2025/4/28.
//

/**
 * iOS 广播 MAC 解析规则。
 *
 * iOS CoreBluetooth 不暴露真实 BLE MAC，因此业务需要从 manufacturer data 中按范围截取并
 * 可选反转字节序得到展示/匹配用 MAC。
 */
struct BleMacRule: Codable {
    /// 截取起点，包含该下标。
    let startIndex: Int
    /// 截取终点，不包含该下标。
    let endIndex: Int
    /// 是否反转截取后的字节序。
    var isReverse: Bool = false
}
