//
//  BleMatchDevice.swift
//  EvenConnect
//
//  Created by Whiskee on 2025/1/13.
//

struct BleMatchDevice: Codable {
    let sn: String
    let belongConfig: String
    let devices: [BleDevice]
}
