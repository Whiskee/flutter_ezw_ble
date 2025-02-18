//
//  CBPeripheral+.swift
//  EvenConnect
//
//  Created by Whiskee on 2025/1/3.
//

import CoreBluetooth

extension CBPeripheral {
    
    /**
     * 转化可识别蓝牙数据
     */
    func toBleDevice(sn: String, belongConfig: String, rssi: Int) -> BleDevice {
        return BleDevice(
            name: name ?? "",
            uuid: identifier.uuidString,
            sn: sn,
            belongConfig: belongConfig,
            rssi: rssi
        )
    }
    
}
