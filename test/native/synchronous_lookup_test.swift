import Foundation

/// Exercises the production executor with a query spy; no CoreBluetooth daemon
/// or synthetic CBPeripheral is needed to prove the XPC closure is not invoked.
@main
struct SynchronousLookupTests {
    static func main() {
        var failures: [String] = []
        var queryCalls = 0
        for state in ["unknown", "resetting", "unsupported", "unauthorized", "poweredOff", "poweredOn"] {
            for active in [false, true] {
                let before = queryCalls
                let result = BleSynchronousCoreBluetoothLookup.retrieve(
                    isAppActive: active,
                    isBluetoothPoweredOn: state == "poweredOn"
                ) {
                    queryCalls += 1
                    return ["exact-peripheral"]
                }
                let ready = active && state == "poweredOn"
                if queryCalls - before != (ready ? 1 : 0) || result != (ready ? ["exact-peripheral"] : []) {
                    failures.append("state=\(state), active=\(active): queryCalls=\(queryCalls - before), result=\(result)")
                }
            }
        }
        // Denial retains the same identity owner; a later ready activation can
        // resolve it through the same executor rather than recording a miss.
        var identity = "g2|exact-endpoint|session-12"
        let frozenIdentity = identity
        let unavailable: [String] = BleSynchronousCoreBluetoothLookup.retrieve(
            isAppActive: true,
            isBluetoothPoweredOn: false
        ) {
            identity = "unexpected-old-query"
            return ["uuid"]
        }
        if !unavailable.isEmpty || identity != frozenIdentity {
            failures.append("unavailable lookup mutated the pending identity")
        }
        let recovered = BleSynchronousCoreBluetoothLookup.retrieve(
            isAppActive: true,
            isBluetoothPoweredOn: true
        ) { [identity] }
        if recovered != [frozenIdentity] {
            failures.append("ready lookup did not return the retained exact identity")
        }

        // These calls exercise the production pending-owner barrier, separate
        // from the lookup spy above. They cover policy/session behavior, not a
        // real CBPeripheral, Gate admission, or hardware connection.
        let frozen = BlePendingIdentityRecoveryGate(
            recoveryEpoch: 4,
            awaitingRecoveryActivation: true
        )
        if frozen.canResolveIdentity(currentRecoveryEpoch: 4) {
            failures.append("implicit identity callback released reset session S1")
        }
        for (poweredOn, currentEpoch, incomingEpoch, session) in [
            (false, Int64(4), Int64(4), Int64(13)),
            (true, 4, 4, 12),
            (true, 4, 4, 11),
            (true, 4, 4, 0),
            (true, 4, 0, 13),
            (true, 4, 3, 13),
            (true, 5, 4, 13)
        ] {
            if frozen.acceptingActivation(
                isBluetoothPoweredOn: poweredOn,
                currentRecoveryEpoch: currentEpoch,
                incomingRecoveryEpoch: incomingEpoch,
                currentSessionGeneration: 12,
                incomingSessionGeneration: session
            ) != nil {
                failures.append("invalid pending activation accepted: on=\(poweredOn), currentEpoch=\(currentEpoch), incomingEpoch=\(incomingEpoch), session=\(session)")
            }
        }
        guard let readyIdentity = frozen.acceptingActivation(
            isBluetoothPoweredOn: true,
            currentRecoveryEpoch: 4,
            incomingRecoveryEpoch: 4,
            currentSessionGeneration: 12,
            incomingSessionGeneration: 13
        ) else {
            print("FAIL: current epoch / higher S2 activation rejected")
            exit(1)
        }
        if !readyIdentity.canResolveIdentity(currentRecoveryEpoch: 4) ||
            readyIdentity.canResolveIdentity(currentRecoveryEpoch: 5) {
            failures.append("ready S2 identity did not preserve the exact epoch")
        }
        if readyIdentity.activationDecision(
            isBluetoothPoweredOn: true,
            currentRecoveryEpoch: 4,
            incomingRecoveryEpoch: 4,
            currentSessionGeneration: 13,
            incomingSessionGeneration: 12
        ) != .reject {
            failures.append("late S1 activation replaced ready S2 identity")
        }
        let secondReset = BlePendingIdentityRecoveryGate(
            recoveryEpoch: 5,
            awaitingRecoveryActivation: true
        )
        if secondReset.acceptingActivation(
            isBluetoothPoweredOn: true,
            currentRecoveryEpoch: 5,
            incomingRecoveryEpoch: 4,
            currentSessionGeneration: 13,
            incomingSessionGeneration: 14
        ) != nil || secondReset.canResolveIdentity(currentRecoveryEpoch: 5) {
            failures.append("second reset accepted stale epoch or implicit recovery")
        }
        let coldStart = BlePendingIdentityRecoveryGate(
            recoveryEpoch: 0,
            awaitingRecoveryActivation: false
        )
        if !coldStart.canResolveIdentity(currentRecoveryEpoch: 0) {
            failures.append("ready cold-start identity unnecessarily blocked")
        }
        // A UUID begin may advance the process epoch before the non-on delegate
        // freezes other pending identities. The stored ready flag cannot let a
        // same-session reconcile refresh an old identity across that window.
        if readyIdentity.acceptingActivation(
            isBluetoothPoweredOn: true,
            currentRecoveryEpoch: 5,
            incomingRecoveryEpoch: 4,
            currentSessionGeneration: 13,
            incomingSessionGeneration: 13
        ) != nil {
            failures.append("old ready flag bypassed an advanced transport epoch")
        }
        if readyIdentity.acceptingActivation(
            isBluetoothPoweredOn: true,
            currentRecoveryEpoch: 5,
            incomingRecoveryEpoch: 5,
            currentSessionGeneration: 13,
            incomingSessionGeneration: 14
        )?.canResolveIdentity(currentRecoveryEpoch: 5) != true {
            failures.append("new final activation failed to recover an implicitly frozen identity")
        }
        if failures.isEmpty {
            print("PASS: 12 lifecycle/transport states; denied query closures untouched; ready query returns identity")
            print("PASS: pending identity blocks implicit S1 recovery, accepts exact epoch/higher S2, rejects stale session and consecutive-reset epoch")
        } else {
            failures.forEach { print("FAIL: \($0)") }
            exit(1)
        }
    }
}
