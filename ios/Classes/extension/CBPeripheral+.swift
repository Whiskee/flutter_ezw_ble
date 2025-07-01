//
//  CBPeripheral+.swift
//  flutter_ezw_ble
//
//  Created by Whiskee on 2025/1/3.
//

import CoreBluetooth

extension CBPeripheral {
    
    /**
     * 转化可识别蓝牙数据
     */
    func toBleDevice(belongConfig: String, sn: String, rssi: Int, mac: String = "") -> BleDevice {
        return BleDevice(
            belongConfig: belongConfig,
            name: name ?? "",
            uuid: identifier.uuidString,
            sn: sn,
            mac: mac,
            rssi: rssi,
        )
    }
    
}
