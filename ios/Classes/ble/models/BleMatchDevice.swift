//
//  BleMatchDevice.swift
//  flutter_ezw_ble
//
//  Created by Whiskee on 2025/1/13.
//

struct BleMatchDevice: Codable {
    let sn: String
    let devices: [BleDevice]
    // Optional for backward-compatible decoding of persisted ordinary results.
    let isPureScanResult: Bool?

    init(sn: String, devices: [BleDevice], isPureScanResult: Bool? = nil) {
        self.sn = sn
        self.devices = devices
        self.isPureScanResult = isPureScanResult
    }
    
    var belongConfig: String? {
        get {
            return devices.first?.belongConfig
        }
    }
}
