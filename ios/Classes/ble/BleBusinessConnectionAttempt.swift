import Foundation
import CoreFoundation

/// Exact Dart business-auth token derived from one connectStatus event.
struct BleBusinessConnectionAttempt: Equatable {
    let uuid: String
    let sessionGeneration: Int64
    let attemptGeneration: Int64

    init(uuid: String, sessionGeneration: Int64, attemptGeneration: Int64) {
        self.uuid = uuid
        self.sessionGeneration = sessionGeneration
        self.attemptGeneration = attemptGeneration
    }

    init(data: [String: Any]) {
        uuid = data["uuid"] as? String ?? ""
        sessionGeneration = (data["sessionGeneration"] as? NSNumber)?.int64Value ?? 0
        attemptGeneration = (data["attemptGeneration"] as? NSNumber)?.int64Value ?? 0
    }
}

/// Decode the optional common-write intent before constructing the BLE manager.
/// Presence is significant: a malformed token must never use legacy dispatch.
enum BleOwnedCommonWriteIntent {
    case legacy
    case owned(BleBusinessConnectionAttempt)
    case rejected(String)

    static func decode(_ arguments: [String: Any]) -> BleOwnedCommonWriteIntent {
        guard arguments.keys.contains("expectedAttempt") else { return .legacy }
        guard let uuid = arguments["uuid"] as? String,
              !uuid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let raw = arguments["expectedAttempt"] as? [String: Any],
              raw["uuid"] as? String == uuid,
              let session = positiveInteger(raw["sessionGeneration"]),
              let attempt = positiveInteger(raw["attemptGeneration"]) else {
            return .rejected("owned_write_invalid_arguments")
        }
        // Only the existing synchronous common path is owned on iOS. OTA/FILE
        // retain their independent transactions and cannot inherit this token.
        if let rawType = arguments["psType"], integer(rawType) == nil {
            return .rejected("owned_write_invalid_arguments")
        }
        guard (arguments["psType"].flatMap(integer) ?? 0) == 0 else {
            return .rejected("owned_write_unsupported")
        }
        return .owned(BleBusinessConnectionAttempt(uuid: uuid,
            sessionGeneration: session, attemptGeneration: attempt))
    }

    /// Flutter's integer codec produces NSNumber integer types; bool, float,
    /// string and overflow values must not be truncated into another owner.
    private static func integer(_ raw: Any) -> Int64? {
        guard let number = raw as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              !["f", "d"].contains(String(cString: number.objCType)),
              number.stringValue == String(number.int64Value) else { return nil }
        return number.int64Value
    }

    private static func positiveInteger(_ raw: Any?) -> Int64? {
        guard let raw, let value = integer(raw), value > 0 else { return nil }
        return value
    }
}

/// MethodChannel status shared by prepare/commit business connection APIs.
enum BleBusinessConnectionStatus: String {
    case accepted
    case invalidArguments
    case missingAdmission
    case attemptMismatch
    case missingPrepare
    case deviceDisconnected
    case gattNotReady
}

/// In-memory lease proving Dart is completing the current exact GATT attempt.
struct BleBusinessConnectionLease {
    let attempt: BleBusinessConnectionAttempt
    let preparedAt: Date
}

/// Exact-token lease registry used by production code and executable native tests.
final class BleBusinessConnectionLeaseRegistry {
    private var leases: [String: BleBusinessConnectionLease] = [:]

    func prepare(endpointKey: String, attempt: BleBusinessConnectionAttempt, at date: Date) {
        leases[endpointKey] = BleBusinessConnectionLease(attempt: attempt, preparedAt: date)
    }

    func attempt(for endpointKey: String) -> BleBusinessConnectionAttempt? {
        leases[endpointKey]?.attempt
    }

    func abort(endpointKey: String, attempt: BleBusinessConnectionAttempt) -> Bool {
        guard matches(leases[endpointKey]?.attempt, attempt) else {
            return false
        }
        leases.removeValue(forKey: endpointKey)
        return true
    }

    func remove(endpointKey: String) {
        leases.removeValue(forKey: endpointKey)
    }

    func clear() {
        leases.removeAll()
    }

    private func matches(
        _ current: BleBusinessConnectionAttempt?,
        _ expected: BleBusinessConnectionAttempt
    ) -> Bool {
        guard let current else { return false }
        return current.uuid.caseInsensitiveCompare(expected.uuid) == .orderedSame &&
            current.sessionGeneration == expected.sessionGeneration &&
            current.attemptGeneration == expected.attemptGeneration
    }
}

/// Pure commit decision used by BleManager and RunnerTests.
enum BleBusinessConnectionCommitPolicy {
    static func evaluate(
        attempt: BleBusinessConnectionAttempt,
        admissionAttempt: BleBusinessConnectionAttempt?,
        preparedAttempt: BleBusinessConnectionAttempt?,
        requirePrepare: Bool,
        hasSession: Bool,
        hasDevice: Bool,
        isSamePeripheral: Bool,
        isPeripheralConnected: Bool,
        isGattReady: Bool
    ) -> BleBusinessConnectionStatus {
        guard !attempt.uuid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              attempt.sessionGeneration > 0,
              attempt.attemptGeneration > 0 else {
            return .invalidArguments
        }
        guard let admissionAttempt, hasSession else {
            return .missingAdmission
        }
        guard admissionAttempt.uuid.caseInsensitiveCompare(attempt.uuid) == .orderedSame,
              admissionAttempt.sessionGeneration == attempt.sessionGeneration,
              admissionAttempt.attemptGeneration == attempt.attemptGeneration else {
            return .attemptMismatch
        }
        if requirePrepare {
            guard let preparedAttempt,
                  preparedAttempt.uuid.caseInsensitiveCompare(attempt.uuid) == .orderedSame,
                  preparedAttempt.sessionGeneration == attempt.sessionGeneration,
                  preparedAttempt.attemptGeneration == attempt.attemptGeneration else {
                return .missingPrepare
            }
        }
        guard hasDevice, isSamePeripheral, isPeripheralConnected else {
            return .deviceDisconnected
        }
        guard isGattReady else {
            return .gattNotReady
        }
        return .accepted
    }
}

/// Immutable inputs for heartbeat-driven invalidation of an already committed
/// business owner. Keeping this decision pure makes the production MethodChannel
/// bridge testable without constructing CoreBluetooth objects.
struct BleBusinessConnectionInvalidationSnapshot {
    let attempt: BleBusinessConnectionAttempt
    let hasCommittedDevice: Bool
    let isSamePeripheral: Bool
    let isPeripheralConnected: Bool
    let isG2Config: Bool
    let autoReconnectEnabled: Bool
    let hasReconnectIntent: Bool
    let reconnectIntentMatchesAttempt: Bool
    let hasNewerAdmission: Bool
    let isOtaBusy: Bool
    let alreadyInvalidated: Bool
}

/// Fail-closed policy for the iOS G2 heartbeat stale-connection breaker.
enum BleBusinessConnectionInvalidationPolicy {
    static func accepts(_ snapshot: BleBusinessConnectionInvalidationSnapshot) -> Bool {
        let attempt = snapshot.attempt
        guard !attempt.uuid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              attempt.sessionGeneration > 0,
              attempt.attemptGeneration > 0 else {
            return false
        }
        guard snapshot.hasCommittedDevice,
              snapshot.isSamePeripheral,
              snapshot.isPeripheralConnected,
              snapshot.isG2Config,
              snapshot.autoReconnectEnabled,
              snapshot.hasReconnectIntent,
              snapshot.reconnectIntentMatchesAttempt,
              !snapshot.hasNewerAdmission,
              !snapshot.isOtaBusy,
              !snapshot.alreadyInvalidated else {
            return false
        }
        return true
    }
}
