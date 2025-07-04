//
//  BleConnectedDevice.swift
//  flutter_ezw_ble
//
//  Created by Whiskee on 2025/1/13.
//

import CoreBluetooth

/// 连接成功后缓存的设备信息
struct BleConnectedDevice {
    var belongConfig: BleConfig
    //  连接后缓存的对象
    var peripheral: CBPeripheral
    var writeCharsDic: [Int: CBCharacteristic] = [:]
    var readCharsDic: [Int: CBCharacteristic] = [:]
    var isConnected: Bool = false
    var readCharsNotify: Int = 0
    
    var isReadCharsNotifySuccess: Bool {
        get {
            return readCharsNotify == readCharsDic.count
        }
    }
    
    /**
     *  更新连接设备信息
     */
    func update(belongConfig: BleConfig, writeChars: [Int: CBCharacteristic], readChars: [Int: CBCharacteristic]) -> BleConnectedDevice {
        return BleConnectedDevice(belongConfig: belongConfig, peripheral: peripheral, writeCharsDic: writeChars, readCharsDic: readChars, isConnected: isConnected)
   }
   
    /**
     *  输出Json字符
     */
   func toString() -> String {
       let writeCharsStr = writeCharsDic.map { (key, value) in
           "\"\(key)\":\"\(value)\""
       }.joined(separator: ",")
       let readCharsStr = readCharsDic.map { (key, value) in
           "\"\(key)\":\"\(value)\""
       }.joined(separator: ",")
       return "[\"belongConfig\":  \(belongConfig.name), \"uuid\": \(peripheral.identifier.uuidString), \"writeChars\": {\(writeCharsStr)}, \"readChars\": {\(readCharsStr)}, \"isConnected\": \(isConnected)]"
   }
}
