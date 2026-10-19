import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
struct ReceiveIdentityPolicyTest {
    static func main() {
        let uuid = "R1-AUTH"

        let current = BleReceiveIdentityPolicy.currentAdmissionIdentity(
            uuid: uuid,
            sessionGeneration: 7,
            attemptGeneration: 11,
            isCurrentPipeline: true,
            isPeripheralConnected: true,
            isCachedReadCharacteristic: true
        )
        expect(current == BleReceiveIdentity(uuid: uuid, sessionGeneration: 7, attemptGeneration: 11), "current admission identity did not freeze exact pair")

        let currentAdmissionRejects: [(label: String, session: Int64, attempt: Int64, isCurrentPipeline: Bool, isPeripheralConnected: Bool, isCachedReadCharacteristic: Bool)] = [
            ("missing session", 0, 11, true, true, true),
            ("negative session", -1, 11, true, true, true),
            ("missing attempt", 7, 0, true, true, true),
            ("negative attempt", 7, -1, true, true, true),
            ("stale peripheral/session pipeline", 7, 11, false, true, true),
            ("disconnected peripheral", 7, 11, true, false, true),
            ("stale read characteristic", 7, 11, true, true, false),
        ]
        for rejected in currentAdmissionRejects {
            expect(BleReceiveIdentityPolicy.currentAdmissionIdentity(
                uuid: uuid,
                sessionGeneration: rejected.session,
                attemptGeneration: rejected.attempt,
                isCurrentPipeline: rejected.isCurrentPipeline,
                isPeripheralConnected: rejected.isPeripheralConnected,
                isCachedReadCharacteristic: rejected.isCachedReadCharacteristic
            ) == nil, "current admission \(rejected.label) must fail closed")
        }

        let accepted = BleReceiveIdentityPolicy.acceptedConnectionIdentity(
            uuid: uuid,
            sessionGeneration: 17,
            attemptGeneration: 21,
            isPeripheralConnected: true,
            isBusinessConnected: true,
            isUpgradeActive: false,
            isCachedReadCharacteristic: true
        )
        expect(accepted == BleReceiveIdentity(uuid: uuid, sessionGeneration: 17, attemptGeneration: 21), "business connected identity did not preserve accepted pair")

        let acceptedConnectionRejects: [(label: String, session: Int64, attempt: Int64, isPeripheralConnected: Bool, isBusinessConnected: Bool, isUpgradeActive: Bool, isCachedReadCharacteristic: Bool)] = [
            ("missing session", 0, 21, true, true, false, true),
            ("negative session", -1, 21, true, true, false, true),
            ("missing attempt", 17, 0, true, true, false, true),
            ("negative attempt", 17, -1, true, true, false, true),
            ("pre-AUTH non-upgrade notify", 17, 21, true, false, false, true),
            ("disconnected peripheral", 17, 21, false, true, false, true),
            ("stale read characteristic", 17, 21, true, true, false, false),
            ("upgrade disconnected peripheral", 17, 21, false, false, true, true),
            ("upgrade stale read characteristic", 17, 21, true, false, true, false),
        ]
        for rejected in acceptedConnectionRejects {
            expect(BleReceiveIdentityPolicy.acceptedConnectionIdentity(
                uuid: uuid,
                sessionGeneration: rejected.session,
                attemptGeneration: rejected.attempt,
                isPeripheralConnected: rejected.isPeripheralConnected,
                isBusinessConnected: rejected.isBusinessConnected,
                isUpgradeActive: rejected.isUpgradeActive,
                isCachedReadCharacteristic: rejected.isCachedReadCharacteristic
            ) == nil, "accepted connection \(rejected.label) must fail closed")
        }

        let upgrade = BleReceiveIdentityPolicy.acceptedConnectionIdentity(
            uuid: uuid,
            sessionGeneration: 17,
            attemptGeneration: 21,
            isPeripheralConnected: true,
            isBusinessConnected: false,
            isUpgradeActive: true,
            isCachedReadCharacteristic: true
        )
        expect(upgrade != nil, "upgrade notify should keep accepted transport identity")

        let command = BleCmd(
            uuid: uuid,
            psType: 0,
            data: Data([1, 2, 3]),
            isSuccess: true,
            receiveIdentity: current
        ).toMap()
        let nested = command["receiveIdentity"] as? [String: Any]
        expect(nested?["uuid"] as? String == uuid, "BleCmd did not serialize nested receiveIdentity uuid")
        expect(nested?["sessionGeneration"] as? Int64 == 7, "BleCmd did not serialize nested receiveIdentity session")
        expect(nested?["attemptGeneration"] as? Int64 == 11, "BleCmd did not serialize nested receiveIdentity attempt")

        print("PASS: iOS receive identity policy freezes exact notify provenance and fails closed")
    }
}
