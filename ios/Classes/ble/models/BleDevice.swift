//
//  BleDevice.swift
//  flutter_ezw_ble
//
//  Created by Whiskee on 2025/1/3.
//

/// 设备信息
struct BleDevice: Codable {
    //  蓝牙配置
    let belongConfig: String
    //  设备名车
    let name: String
    //  唯一识别码
    let uuid: String
    //  机器码
    let sn: String
    //  MAC地址
    let mac: String
    //  信号
    let rssi: Int
}

