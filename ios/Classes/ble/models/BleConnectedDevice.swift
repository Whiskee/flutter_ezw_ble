//
//  BleConnectedDevice.swift
//  EvenConnect
//
//  Created by Whiskee on 2025/1/13.
//

import CoreBluetooth

/// 连接成功后缓存的设备信息
struct BleConnectedDevice {
    //  连接后缓存的对象
    var peripheral: CBPeripheral
    var writeChars: CBCharacteristic?
    var readChars: CBCharacteristic?
    var isConnected: Bool = false
    
    /**
     *  更新连接设备信息
     */
    func update(writeChars: CBCharacteristic?, readChars: CBCharacteristic) -> BleConnectedDevice {
        return BleConnectedDevice(peripheral: peripheral, writeChars: writeChars, readChars: readChars)
    }
    
    func toString() -> String {
        return "[\"uuid\": \(peripheral.identifier.uuidString),\"writeChars\":\(String(describing: writeChars)),\"readChras\":\(String(describing: readChars)),\"isConnected\":\(isConnected)]"
    }
}
