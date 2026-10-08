import Foundation

/// The final Dart recovery activation is the only operation allowed to consume
/// a transport-reset barrier, for both UUID tasks and name-only identities.
enum BleRecoveryActivationGateDecision: Equatable {
    case notRequired
    case consume
    case reject
}

/// Pure admission policy; BleManager still owns atomic owner mutations on its
/// main queue. Both native XCTest and the portable regression execute this policy.
enum BleRecoveryActivationGatePolicy {
    /// Decide before arm/claim side effects: a frozen owner needs the exact
    /// current epoch and a higher final Dart session, not a repeated old batch.
    static func evaluate(
        awaitingRecoveryActivation: Bool,
        pausedByBluetoothOff: Bool,
        isBluetoothPoweredOn: Bool,
        currentRecoveryEpoch: Int64,
        incomingRecoveryEpoch: Int64,
        currentSessionGeneration: Int64,
        incomingSessionGeneration: Int64
    ) -> BleRecoveryActivationGateDecision {
        guard awaitingRecoveryActivation || pausedByBluetoothOff else {
            return .notRequired
        }
        guard isBluetoothPoweredOn,
              currentRecoveryEpoch > 0,
              incomingRecoveryEpoch == currentRecoveryEpoch,
              incomingSessionGeneration > 0,
              incomingSessionGeneration > currentSessionGeneration else {
            return .reject
        }
        return .consume
    }
}

/// Name-only owners have no UUID task yet. Retain their reset barrier separately
/// so a late advertisement or foreground identity probe cannot arm the old session.
struct BlePendingIdentityRecoveryGate {
    let recoveryEpoch: Int64
    let awaitingRecoveryActivation: Bool

    /// A ready cold-start owner can resolve immediately. A frozen owner can only
    /// be replaced by an explicitly accepted final recovery activation.
    func canResolveIdentity(currentRecoveryEpoch: Int64) -> Bool {
        !awaitingRecoveryActivation && recoveryEpoch == currentRecoveryEpoch
    }

    /// Compare both the owner epoch and the process epoch before identity lookup
    /// can claim or install any peripheral for this activation.
    func activationDecision(
        isBluetoothPoweredOn: Bool,
        currentRecoveryEpoch: Int64,
        incomingRecoveryEpoch: Int64,
        currentSessionGeneration: Int64,
        incomingSessionGeneration: Int64
    ) -> BleRecoveryActivationGateDecision {
        guard incomingSessionGeneration == 0 || incomingSessionGeneration >= currentSessionGeneration else {
            return .reject
        }
        // Another UUID begin can observe transport loss and advance the global
        // epoch before the delegate has frozen this pending identity. An epoch
        // mismatch therefore requires the same final activation as an explicit
        // awaiting flag; neither an old reconcile nor a late scan may bypass it.
        let requiresRecovery = awaitingRecoveryActivation || recoveryEpoch != currentRecoveryEpoch
        return BleRecoveryActivationGatePolicy.evaluate(
            awaitingRecoveryActivation: requiresRecovery,
            pausedByBluetoothOff: false,
            isBluetoothPoweredOn: isBluetoothPoweredOn,
            currentRecoveryEpoch: currentRecoveryEpoch,
            incomingRecoveryEpoch: incomingRecoveryEpoch,
            currentSessionGeneration: currentSessionGeneration,
            incomingSessionGeneration: incomingSessionGeneration
        )
    }

    /// Preserve a waiting identity after a successful explicit activation misses
    /// in the system query. This is the only way to release its reset barrier;
    /// implicit scan/lifecycle callbacks only call canResolveIdentity.
    func acceptingActivation(
        isBluetoothPoweredOn: Bool,
        currentRecoveryEpoch: Int64,
        incomingRecoveryEpoch: Int64,
        currentSessionGeneration: Int64,
        incomingSessionGeneration: Int64
    ) -> BlePendingIdentityRecoveryGate? {
        guard activationDecision(
            isBluetoothPoweredOn: isBluetoothPoweredOn,
            currentRecoveryEpoch: currentRecoveryEpoch,
            incomingRecoveryEpoch: incomingRecoveryEpoch,
            currentSessionGeneration: currentSessionGeneration,
            incomingSessionGeneration: incomingSessionGeneration
        ) != .reject else { return nil }
        return BlePendingIdentityRecoveryGate(
            recoveryEpoch: currentRecoveryEpoch,
            awaitingRecoveryActivation: !isBluetoothPoweredOn
        )
    }
}
