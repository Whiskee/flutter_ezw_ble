//
//  BleConnectionEventOwnershipPolicy.swift
//  flutter_ezw_ble
//

/// Owner selected for a CoreBluetooth connection event before SR escrow is allowed.
/// The priority mirrors the only production path in `connectionEventDidOccur`:
/// current exact owners win, and only ownerless physical links may enter escrow.
enum BleConnectionEventOwner: Equatable {
    case activeRequest
    case currentAdmission
    case committedBusinessOwner
    case stateRestorationEscrow
}

enum BleConnectionEventOwnershipPolicy {
    static func resolve(
        hasActiveRequest: Bool,
        hasCurrentAdmissionForPeripheral: Bool,
        hasCommittedBusinessOwner: Bool
    ) -> BleConnectionEventOwner {
        if hasActiveRequest { return .activeRequest }
        if hasCurrentAdmissionForPeripheral { return .currentAdmission }
        if hasCommittedBusinessOwner { return .committedBusinessOwner }
        return .stateRestorationEscrow
    }
}
