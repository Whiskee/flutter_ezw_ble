import CoreBluetooth
import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

/// Platform-only spies around the extracted, unchanged escrow terminal flow.
final class EscrowCentralFixture {
    var cancellations = 0
    func cancelPeripheralConnection(_ peripheral: CBPeripheral) { cancellations += 1 }
}
final class EscrowManagerFixture {
    let restorationCoordinator = BleStateRestorationCoordinator()
    let centralManager = EscrowCentralFixture()
    var rearms = 0
    func rearmStateRestorationEscrow(_ peripheral: CBPeripheral, reason: String) { rearms += 1 }
    func loggerD(msg: String) {}
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

        // An ownerless restoration Code 1 must not immediately rearm forever.
        let escrow = BleStateRestorationCoordinator()
        let failed = CBPeripheral(identifier: UUID(), name: "EVEN R1_FAILED", state: .disconnected)
        expect(escrow.enqueue(failed) == .rearm, "initial restoration should retain ordinary pending policy")
        expect(escrow.didTerminate(failed, systemIsReconnecting: false, invalidParameters: true, now: 100) == .deferUntilClaim, "Code 1 escrow spun instead of deferring")
        expect(!escrow.canRearm(failed), "power-on debt bypassed Code 1 escrow latch")
        expect(escrow.enqueue(failed) == .deferUntilClaim, "repeated restoration bypassed Code 1 escrow latch")
        expect(escrow.didTerminate(failed, systemIsReconnecting: false) == .deferUntilClaim, "late terminal bypassed Code 1 latch")
        let sameUuidNewObject = CBPeripheral(identifier: failed.identifier, name: failed.name, state: .disconnected)
        _ = escrow.enqueue(sameUuidNewObject)
        expect(escrow.didTerminate(failed, systemIsReconnecting: false, invalidParameters: true) == .ignore, "old object terminal poisoned replacement escrow")
        let claim = escrow.claimPendingPeripheral(uuid: failed.identifier.uuidString, name: "")
        expect(claim?.state == .idle && claim?.peripheral === sameUuidNewObject, "deferred escrow not claimable by exact current owner")
        expect(claim?.invalidParametersBackoff.failureCount == 1, "escrow claim lost or duplicated exact Code 1 episode")
        expect(claim?.invalidParametersBackoff.remaining(now: 100) == 1, "claim erased escrow retry deadline")
        var claimedOwnerDebt = BleInvalidParametersBackoff()
        claimedOwnerDebt.absorb(claim!.invalidParametersBackoff)
        expect(claimedOwnerDebt.remaining(now: 100.5) == 0.5, "claim bypassed shared monotonic backoff")
        expect(!escrow.contains(uuid: failed.identifier.uuidString), "claim left old escrow rearm reachable")
        expect(escrow.enqueue(failed) == .rearm, "claim did not retire old latch")
        _ = escrow.didTerminate(failed, systemIsReconnecting: false, invalidParameters: true)
        _ = escrow.removePendingPeripherals(uuid: failed.identifier.uuidString, name: "")
        expect(escrow.enqueue(failed) == .rearm, "cancel did not retire Code 1 escrow latch")

        let escrowManager = EscrowManagerFixture()
        _ = escrowManager.restorationCoordinator.enqueue(failed)
        expect(escrowManager.handleStateRestorationEscrowTerminal(failed, systemIsReconnecting: true, invalidParameters: true, reason: "modern Code1"), "actual escrow terminal flow failed to consume Code1")
        expect(escrowManager.centralManager.cancellations == 1 && escrowManager.rearms == 0, "actual Code1 flow kept system pending or rearmed")
        _ = escrowManager.handleStateRestorationEscrowTerminal(failed, systemIsReconnecting: true, invalidParameters: true, reason: "duplicate Code1")
        _ = escrowManager.handleStateRestorationEscrowTerminal(failed, systemIsReconnecting: false, reason: "cancel terminal")
        expect(escrowManager.centralManager.cancellations == 1 && escrowManager.rearms == 0, "parked escrow duplicated cancel/rearm")
        let flowClaim = escrowManager.restorationCoordinator.claimPendingPeripheral(uuid: failed.identifier.uuidString, name: "")
        expect(flowClaim?.invalidParametersBackoff.failureCount == 1, "actual terminal duplicated escrow episode")
        let ordinaryManager = EscrowManagerFixture()
        _ = ordinaryManager.restorationCoordinator.enqueue(failed)
        _ = ordinaryManager.handleStateRestorationEscrowTerminal(failed, systemIsReconnecting: false, reason: "ordinary terminal")
        expect(ordinaryManager.rearms == 1 && ordinaryManager.centralManager.cancellations == 0, "ordinary escrow policy changed")

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
