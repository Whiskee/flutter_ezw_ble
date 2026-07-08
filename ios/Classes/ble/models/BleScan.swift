//
//  BleScan.swift
//  flutter_ezw_ble
//
//  Created by Whiskee on 2025/5/16.
//

/**
 * iOS 扫描匹配规则。
 *
 * 该模型由 Dart `BleConfig.scan` 下发，原生侧按名称过滤、SN 解析、MAC 解析和 matchCount
 * 聚合规则决定是否向 Flutter 上报扫描结果。
 */
class BleScan: Codable {
    /// 设备名称过滤条件。
    let nameFilters: Array<String>
    /// 设备 SN 解析规则。
    let snRule: BleSnRule?
    /// iOS 通过广播 manufacturer data 解析 MAC 的规则。
    let macRule: BleMacRule?
    /// 组合设备数；1 表示单设备立即上报，大于 1 表示按 SN 聚合后上报。
    let matchCount: Int
    
    /**
     * 创建扫描规则。
     *
     * 初始化器保持字段直传，不在模型层执行默认值修正；默认值由 Dart 或 MethodChannel 解析层保证。
     */
    init(nameFilters: Array<String>, snRule: BleSnRule?, macRule: BleMacRule?, matchCount: Int) {
        // 1. 保留 Dart 下发的过滤器顺序，便于日志和配置排查。
        self.nameFilters = nameFilters
        // 2. SN/MAC 规则允许为空，表示该配置不启用对应解析。
        self.snRule = snRule
        self.macRule = macRule
        // 3. matchCount 直接保存，扫描 pipeline 决定何时聚合上报。
        self.matchCount = matchCount
    }
    
    /**
     * 构造空扫描规则。
     *
     * 空规则只用于占位，不应该参与真实扫描匹配。
     */
    static func empty() -> BleScan {
        // 1. 空过滤器和 matchCount=0 让扫描 pipeline 自然无法命中。
        return BleScan(nameFilters: [], snRule: nil, macRule: nil, matchCount: 0)
    }
}
