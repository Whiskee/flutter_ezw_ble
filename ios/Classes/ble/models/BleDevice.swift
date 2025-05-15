//
//  BleDevice.swift
//  EvenConnect
//
//  Created by Whiskee on 2025/1/3.
//

/// 设备信息
struct BleDevice: Codable {
    let belongConfig: String
    let name: String
    let uuid: String
    let sn: String
    let rssi: Int
    let mac: String
}

