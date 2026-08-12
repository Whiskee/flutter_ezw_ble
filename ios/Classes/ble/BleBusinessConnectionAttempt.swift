import Foundation

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
