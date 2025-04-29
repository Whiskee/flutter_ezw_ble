//
//  BleUuidType.swift
//  flutter_ezw_ble
//
//  Created by Whiskee on 2025/4/23.
//

enum BleUuidType: String, Codable {
    case common
    case largeData
    case streaming
    case ota
    
    var isCommon: Bool {
        get {
            return self == .common
        }
    }
    
    var isLargeData: Bool {
        get {
            return self == .largeData
        }
    }
    
    var isStreaming: Bool {
        get {
            return self == .streaming
        }
    }
    
    var isOta: Bool {
        get {
            return self == .ota
        }
    }
}

