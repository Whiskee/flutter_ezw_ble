//
//  BleMatchDevice.swift
//  flutter_ezw_ble
//
//  Created by Whiskee on 2025/1/13.
//

struct BleMatchDevice: Codable {
    let sn: String
    let devices: [BleDevice]
    
    var belongConfig: String? {
        get {
            return devices.first?.belongConfig
        }
    }
}
