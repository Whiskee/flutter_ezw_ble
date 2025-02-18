//
//  BleDevice.swift
//  EvenConnect
//
//  Created by Whiskee on 2025/1/3.
//

/// 设备信息
struct BleDevice: Codable {
    let name: String
    let uuid: String
    let sn: String
    let belongConfig: String
    let rssi: Int
}

