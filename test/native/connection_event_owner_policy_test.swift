import CoreBluetooth
import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
struct ConnectionEventOwnerPolicyTest {
    static func main() {
        expect(
            BleConnectionEventOwnershipPolicy.resolve(
                hasActiveRequest: true,
                hasCurrentAdmissionForPeripheral: true,
                hasCommittedBusinessOwner: true
            ) == .activeRequest,
            "active request must outrank admission and committed owner"
        )
        expect(
            BleConnectionEventOwnershipPolicy.resolve(
                hasActiveRequest: false,
                hasCurrentAdmissionForPeripheral: true,
                hasCommittedBusinessOwner: true
            ) == .currentAdmission,
            "current GATT/AUTH admission must outrank committed owner"
        )
        expect(
            BleConnectionEventOwnershipPolicy.resolve(
                hasActiveRequest: false,
                hasCurrentAdmissionForPeripheral: false,
                hasCommittedBusinessOwner: true
            ) == .committedBusinessOwner,
            "committed business owner must outrank SR escrow"
        )
        expect(
            BleConnectionEventOwnershipPolicy.resolve(
                hasActiveRequest: false,
                hasCurrentAdmissionForPeripheral: false,
                hasCommittedBusinessOwner: false
            ) == .stateRestorationEscrow,
            "only ownerless connection events may enter escrow"
        )

        let coordinator = BleStateRestorationCoordinator()
        let g2Id = UUID()
        let r1Id = UUID()
        let g2 = CBPeripheral(identifier: g2Id, name: "Even G2_L", state: .connected)
        let r1 = CBPeripheral(identifier: r1Id, name: "EVEN R1_123456", state: .connecting)
        expect(coordinator.enqueue(g2) == .holdConnected, "G2 connected event should stage as connected escrow")
        expect(coordinator.enqueue(r1) == .keepPending, "R1 registering/pending event should stage as pending escrow")
        let removed = coordinator.removePendingPeripherals(uuid: g2Id.uuidString, name: "")
        expect(removed.count == 1 && removed.first?.identifier == g2Id, "exact UUID escrow removal should remove only G2")
        expect(!coordinator.contains(uuid: g2Id.uuidString), "removed G2 escrow must not remain pending")
        expect(coordinator.contains(uuid: r1Id.uuidString), "R1 escrow must remain isolated")
        expect(coordinator.didTerminate(g2, systemIsReconnecting: false) == .ignore, "removed G2 escrow must not swallow later terminal")
        expect(coordinator.didTerminate(r1, systemIsReconnecting: false) == .rearm, "unowned R1 terminal still follows SR rearm path")

        let gate = BlePeripheralCancellationBarrierGate()
        let first = gate.begin(endpointId: g2Id.uuidString)!
        expect(first.isNew && gate.isBlocking(endpointId: g2Id.uuidString), "first cancellation barrier should block endpoint")
        expect(!gate.timeout(endpointId: g2Id.uuidString, token: first.token + 1), "old watchdog token must not release barrier")
        expect(gate.timeout(endpointId: g2Id.uuidString, token: first.token), "exact watchdog token should release barrier")
        expect(!gate.isBlocking(endpointId: g2Id.uuidString), "timeout release should unblock endpoint")
        expect(gate.consumeCallback(endpointId: g2Id.uuidString) == .timedOutBarrier, "late callback should consume timeout debt")
        let second = gate.begin(endpointId: g2Id.uuidString)!
        expect(gate.consumeCallback(endpointId: g2Id.uuidString) == .activeBarrier(second.token), "real terminal should release active barrier")
        expect(gate.consumeCallback(endpointId: g2Id.uuidString) == .none, "barrier release should be one-shot")

        print("PASS: connection-event owner priority, exact escrow removal and barrier release use production policies")
    }
}
