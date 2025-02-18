//
//  CBManagerState+.swift
//  EvenConnect
//
//  Created by Whiskee on 2025/1/8.
//

import CoreBluetooth

extension CBManagerState {
        
    var label: String {
        get {
            switch self {
            case .resetting:
                return "resetting"
            case .unsupported:
                return "unsupported"
            case .unauthorized:
                return "unauthorized"
            case .poweredOff:
                return "poweredOff"
            case .poweredOn:
                return "poweredOn"
            default:
                return "unknown"
            }
        }
    }
}
