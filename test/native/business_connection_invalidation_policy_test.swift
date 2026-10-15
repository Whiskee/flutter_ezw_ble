import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
struct BusinessConnectionInvalidationPolicyTest {
    static func snapshot(
        attempt: BleBusinessConnectionAttempt = BleBusinessConnectionAttempt(
            uuid: "G2-L",
            sessionGeneration: 31,
            attemptGeneration: 7
        ),
        hasCommittedDevice: Bool = true,
        isSamePeripheral: Bool = true,
        isPeripheralConnected: Bool = true,
        isG2Config: Bool = true,
        autoReconnectEnabled: Bool = true,
        hasReconnectIntent: Bool = true,
        reconnectIntentMatchesAttempt: Bool = true,
        hasNewerAdmission: Bool = false,
        isOtaBusy: Bool = false,
        alreadyInvalidated: Bool = false
    ) -> BleBusinessConnectionInvalidationSnapshot {
        BleBusinessConnectionInvalidationSnapshot(
            attempt: attempt,
            hasCommittedDevice: hasCommittedDevice,
            isSamePeripheral: isSamePeripheral,
            isPeripheralConnected: isPeripheralConnected,
            isG2Config: isG2Config,
            autoReconnectEnabled: autoReconnectEnabled,
            hasReconnectIntent: hasReconnectIntent,
            reconnectIntentMatchesAttempt: reconnectIntentMatchesAttempt,
            hasNewerAdmission: hasNewerAdmission,
            isOtaBusy: isOtaBusy,
            alreadyInvalidated: alreadyInvalidated
        )
    }

    static func main() {
        expect(
            BleBusinessConnectionInvalidationPolicy.accepts(snapshot()),
            "current committed auto-reconnect owner should be invalidated"
        )

        let rejected: [(String, BleBusinessConnectionInvalidationSnapshot)] = [
            ("blank uuid", snapshot(attempt: BleBusinessConnectionAttempt(uuid: "", sessionGeneration: 31, attemptGeneration: 7))),
            ("zero session", snapshot(attempt: BleBusinessConnectionAttempt(uuid: "G2-L", sessionGeneration: 0, attemptGeneration: 7))),
            ("zero attempt", snapshot(attempt: BleBusinessConnectionAttempt(uuid: "G2-L", sessionGeneration: 31, attemptGeneration: 0))),
            ("missing committed device", snapshot(hasCommittedDevice: false)),
            ("old peripheral object", snapshot(isSamePeripheral: false)),
            ("physical disconnected", snapshot(isPeripheralConnected: false)),
            ("non G2 config", snapshot(isG2Config: false)),
            ("autoReconnect disabled", snapshot(autoReconnectEnabled: false)),
            ("missing reconnect intent", snapshot(hasReconnectIntent: false)),
            ("stale attempt", snapshot(reconnectIntentMatchesAttempt: false)),
            ("superseded admission", snapshot(hasNewerAdmission: true)),
            ("ota busy", snapshot(isOtaBusy: true)),
            ("duplicate invalidation", snapshot(alreadyInvalidated: true)),
        ]
        for (label, snapshot) in rejected {
            expect(
                !BleBusinessConnectionInvalidationPolicy.accepts(snapshot),
                "\(label) must fail closed"
            )
        }

        print("PASS: iOS business invalidation policy accepts only current committed owners")
    }
}
