//
//  BleSecurityGate.swift
//  flutter_ezw_ble
//

import CoreBluetooth

/// Optional protected write used to let CoreBluetooth establish the security
/// level before Dart sends business AUTH.
struct BleSecurityGate: Codable {
    let service: String
    let writeChars: String

    var serviceUUID: CBUUID {
        CBUUID(string: service)
    }

    var writeCharUUID: CBUUID {
        CBUUID(string: writeChars)
    }
}
