//
//  BleUUID.swift
//  EvenConnect
//
//  Created by Whiskee on 2025/1/6.
//

import CoreBluetooth

struct BleUuid: Codable {
    let service: String
    var writeChars: String?
    var readChars: String?
    var type: BleUuidType = BleUuidType.common
 
    // 计算属性，允许访问 CBUUID 对象
    var serviceUUID: CBUUID {
        get { return CBUUID(string: service) }
    }
    var writeCharUUID: CBUUID? {
        get { return writeChars.map(CBUUID.init(string:)) }
    }
    var readCharUUID: CBUUID? {
        get { return readChars.map(CBUUID.init(string:)) }
    }
    
}
