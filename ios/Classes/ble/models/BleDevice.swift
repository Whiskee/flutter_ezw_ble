//
//  BleDevice.swift
//  flutter_ezw_ble
//
//  Created by Whiskee on 2025/1/3.
//

/**
 * iOS 扫描结果中的 BLE 设备信息。
 *
 * 该模型只描述扫描展示身份，不持有 CBPeripheral；原生内部使用 `(BleDevice, CBPeripheral)`
 * 组合缓存，Flutter 侧只接收这个可序列化模型。
 */
struct BleDevice: Codable {
    /// 设备命中的 BleConfig 名称。
    let belongConfig: String
    /// CoreBluetooth 广播名。
    let name: String
    /// CoreBluetooth peripheral identifier。
    let uuid: String
    /// 业务序列号，用于左右腿/多设备聚合。
    let sn: String
    /// 按业务广播规则解析出的 MAC，iOS 无法直接读取真实 BLE MAC。
    let mac: String
    /// 最近一次扫描回调中的 RSSI。
    let rssi: Int
}
