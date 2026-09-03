import Foundation

struct BleSecurityGateAttempt: Equatable {
    let admission: BleConnectionAdmission
    let characteristicUUID: String
}

/// Observable producer of one consumed Security Gate failure. The trigger is
/// diagnostic only; both cases enter the same exact-attempt recovery policy.
enum BleSecurityGateFailureTrigger: String {
    case callbackFailure
    case timeout
}

/// Tracks the single protected write that gates connectFinish for one exact
/// physical attempt. CoreBluetooth write callbacks do not carry our session
/// token, so every consume path must compare generation and session.
final class BleSecurityGateAttemptRegistry {
    private var attempts: [String: BleSecurityGateAttempt] = [:]
    private var passedAttempts: [String: BleConnectionAdmission] = [:]

    func start(admission: BleConnectionAdmission, characteristicUUID: String) {
        let key = endpointKey(admission.endpointId)
        passedAttempts.removeValue(forKey: key)
        attempts[key] = BleSecurityGateAttempt(
            admission: admission,
            characteristicUUID: characteristicUUID
        )
    }

    func isStarted(for admission: BleConnectionAdmission) -> Bool {
        guard let pending = attempts[endpointKey(admission.endpointId)] else { return false }
        return isSameAttempt(pending.admission, admission)
    }

    func hasPassed(_ admission: BleConnectionAdmission) -> Bool {
        guard let passed = passedAttempts[endpointKey(admission.endpointId)] else { return false }
        return isSameAttempt(passed, admission)
    }

    func complete(
        endpointId: String,
        characteristicUUID: String,
        currentAdmission: BleConnectionAdmission?
    ) -> BleSecurityGateAttempt? {
        let key = endpointKey(endpointId)
        guard let attempt = attempts[key],
              let currentAdmission,
              isSameAttempt(attempt.admission, currentAdmission),
              attempt.characteristicUUID.caseInsensitiveCompare(characteristicUUID) == .orderedSame else {
            return nil
        }
        attempts.removeValue(forKey: key)
        return attempt
    }

    /// Atomically consumes the protected write when the connection deadline
    /// expires while that exact attempt is still waiting for CoreBluetooth.
    /// The callback and timeout paths share this single take point so a late
    /// `didWriteValueFor` can never charge the replacement generation again.
    func consumeTimeout(
        characteristicUUID: String?,
        currentAdmission: BleConnectionAdmission?
    ) -> BleSecurityGateAttempt? {
        guard let currentAdmission,
              let characteristicUUID else { return nil }
        let key = endpointKey(currentAdmission.endpointId)
        guard let attempt = attempts[key],
              isSameAttempt(attempt.admission, currentAdmission),
              attempt.characteristicUUID.caseInsensitiveCompare(characteristicUUID) == .orderedSame else {
            return nil
        }
        attempts.removeValue(forKey: key)
        return attempt
    }

    func markPassed(_ admission: BleConnectionAdmission) {
        passedAttempts[endpointKey(admission.endpointId)] = admission
    }

    func cancel(admission: BleConnectionAdmission) {
        let key = endpointKey(admission.endpointId)
        if let pending = attempts[key], isSameAttempt(pending.admission, admission) {
            attempts.removeValue(forKey: key)
        }
        if let passed = passedAttempts[key], isSameAttempt(passed, admission) {
            passedAttempts.removeValue(forKey: key)
        }
    }

    func cancel(endpointIds: Set<String>) {
        endpointIds.map(endpointKey).forEach { key in
            attempts.removeValue(forKey: key)
            passedAttempts.removeValue(forKey: key)
        }
    }

    func removeAll() {
        attempts.removeAll()
        passedAttempts.removeAll()
    }

    private func endpointKey(_ endpointId: String) -> String {
        endpointId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Source may be promoted from auto to manual while the system pairing UI is
    /// visible. Physical ownership is the endpoint/session/attempt tuple, not source.
    private func isSameAttempt(
        _ lhs: BleConnectionAdmission,
        _ rhs: BleConnectionAdmission
    ) -> Bool {
        lhs.endpointId.caseInsensitiveCompare(rhs.endpointId) == .orderedSame &&
            lhs.sessionId == rhs.sessionId &&
            lhs.generation == rhs.generation &&
            lhs.sessionGeneration == rhs.sessionGeneration
    }
}
