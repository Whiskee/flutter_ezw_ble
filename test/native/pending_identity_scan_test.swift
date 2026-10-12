import CoreBluetooth
import Foundation

/// Executes production parsing, deduplication and resolver mutations. GATT and
/// platform calls are spies; reset/activation policy uses the production gate.
@main
struct PendingIdentityScanTests {
    static var failures: [String] = []
    static let name = "EVEN R1_A1B2C3"
    static let configName = "ring"
    static let config = BleConfig(
        name: configName,
        scan: BleScan(
            nameFilters: ["EVEN R1"],
            snRule: BleSnRule(byteLength: 12, startSubIndex: 6, replaceRex: "", filters: ["R1"]),
            macRule: BleMacRule(startIndex: 0, endIndex: 6),
            matchCount: 1
        ),
        autoReconnect: true
    )
    static let manufacturer = Data([0xA1, 0xB2, 0xC3, 0x11, 0x22, 0x33]) + Data("R1TEST".utf8)

    static func expect(_ condition: @autoclosure () -> Bool, _ reason: String) {
        if !condition() { failures.append(reason) }
    }

    static func fixture(awaiting: Bool = true) -> (BleManager, CBPeripheral, BlePendingReconnectIdentity) {
        BleEC.scanResult.events.removeAll()
        let manager = BleManager()
        manager.bleConfigs = [config]
        let pending = BlePendingReconnectIdentity(
            belongConfig: configName, name: name, expectedMacSuffix: "A1B2C3",
            source: .autoReconnect, sessionGeneration: 12,
            recoveryGate: BlePendingIdentityRecoveryGate(recoveryEpoch: 4, awaitingRecoveryActivation: awaiting)
        )
        manager.pendingReconnectIdentities[pending.key] = pending
        return (manager, CBPeripheral(identifier: UUID(), name: nil), pending)
    }

    static func discover(_ manager: BleManager, _ peripheral: CBPeripheral, manufacturer data: Data? = manufacturer, name advertisedName: String = name) {
        var advertisement: [String: Any] = [CBAdvertisementDataLocalNameKey: advertisedName]
        if let data { advertisement["kCBAdvDataManufacturerData"] = data }
        manager.handleDiscoveredPeripheral(peripheral, advertisementData: advertisement, rssi: -55)
    }

    static func main() throws {
        // A real pending owner stays frozen while valid ordinary scan data is
        // parsed and emitted, without arm, activation or physical attempt calls.
        let (frozen, peripheral, owner) = fixture()
        discover(frozen, peripheral)
        expect(BleEC.scanResult.events.count == 1, "frozen pending swallowed valid manufacturer scan")
        if let json = BleEC.scanResult.events.first {
            let event = try JSONDecoder().decode(BleMatchDevice.self, from: Data(json.utf8))
            expect(event.sn == "R1TEST" && event.devices.first?.mac == "A1:B2:C3:11:22:33", "ordinary MAC/SN parsing was bypassed")
        }
        expect(frozen.pendingReconnectIdentities[owner.key]?.sessionGeneration == 12, "frozen owner/session changed")
        expect(frozen.pendingReconnectIdentities[owner.key]?.recoveryGate.awaitingRecoveryActivation == true, "scan implicitly thawed barrier")
        expect(frozen.armCalls == 0 && frozen.activateCalls == 0 && frozen.physicalConnectCalls == 0 && frozen.tasks.isEmpty, "frozen scan allocated an owner or attempt")
        discover(frozen, peripheral)
        expect(BleEC.scanResult.events.count == 1, "ordinary duplicate broadcast emitted twice")
        // startScan clears its scan cache, not the pending identity. Repeat the
        // external scan-window boundary and execute the same production pipeline.
        frozen.scanResultTemp.removeAll()
        discover(frozen, peripheral)
        expect(BleEC.scanResult.events.count == 2 && frozen.armCalls == 0, "new scan window swallowed scan or armed old S1")

        // S1 cannot consume the owner; current-epoch/higher S2 can. The normal
        // scan cache already contains this UUID when that activation is accepted.
        let gate = frozen.pendingReconnectIdentities[owner.key]!.recoveryGate
        expect(gate.acceptingActivation(isBluetoothPoweredOn: true, currentRecoveryEpoch: 4, incomingRecoveryEpoch: 4, currentSessionGeneration: 12, incomingSessionGeneration: 12) == nil, "late S1 thawed owner")
        let accepted = gate.acceptingActivation(isBluetoothPoweredOn: true, currentRecoveryEpoch: 4, incomingRecoveryEpoch: 4, currentSessionGeneration: 12, incomingSessionGeneration: 13)!
        // Model only the accepted activation boundary. The policy above, actual
        // resolver removal/cache/arm below and scan parsing are production code.
        frozen.pendingReconnectIdentities[owner.key] = BlePendingReconnectIdentity(
            belongConfig: owner.belongConfig, name: owner.name, expectedMacSuffix: owner.expectedMacSuffix,
            source: owner.source, sessionGeneration: 13, recoveryGate: accepted
        )
        discover(frozen, peripheral)
        expect(frozen.pendingReconnectIdentities.isEmpty && frozen.tasks.count == 1 && frozen.tasks[peripheral.identifier.uuidString]?.sessionGeneration == 13, "valid S2 did not resolve unique owner through existing scan cache")
        expect(frozen.armCalls == 1 && frozen.activateCalls == 1 && frozen.physicalConnectCalls == 0, "ready resolution allocated duplicate physical work")
        discover(frozen, peripheral)
        expect(frozen.armCalls == 1 && BleEC.scanResult.events.count == 2, "resolved owner or ordinary result duplicated")

        // Empty manufacturer packets never become normal scan events while the
        // owner is frozen, and cannot clear or arm the pending identity.
        for invalidData: Data? in [nil, Data()] {
            let (invalid, device, pending) = fixture()
            discover(invalid, device, manufacturer: invalidData)
            expect(BleEC.scanResult.events.isEmpty && invalid.scanResultTemp.isEmpty && invalid.pendingReconnectIdentities[pending.key] != nil && invalid.armCalls == 0, "mfr0 leaked or consumed frozen owner")
        }
        let (ready, readyPeripheral, _) = fixture(awaiting: false)
        discover(ready, readyPeripheral, manufacturer: nil)
        expect(ready.pendingReconnectIdentities.isEmpty && ready.armCalls == 1 && ready.activateCalls == 1 && BleEC.scanResult.events.isEmpty, "ready exact identity no longer resolves mfr0 privately")

        let (snRejected, snPeripheral, snOwner) = fixture()
        snRejected.bleConfigs = [BleConfig(
            name: configName,
            scan: BleScan(nameFilters: ["EVEN R1"], snRule: BleSnRule(byteLength: 12, startSubIndex: 6, replaceRex: "", filters: ["EXPECTED_SN"]), macRule: config.scan.macRule, matchCount: 1),
            autoReconnect: true
        )]
        discover(snRejected, snPeripheral)
        expect(BleEC.scanResult.events.isEmpty && snRejected.pendingReconnectIdentities[snOwner.key] != nil && snRejected.armCalls == 0, "frozen advertisement bypassed configured SN filter")

        for state in [CBManagerState.unknown, .resetting, .poweredOff] {
            let (unavailable, unavailablePeripheral, unavailableOwner) = fixture(awaiting: false)
            unavailable.centralManager.state = state
            discover(unavailable, unavailablePeripheral)
            expect(unavailable.pendingReconnectIdentities[unavailableOwner.key] != nil && unavailable.armCalls == 0 && BleEC.scanResult.events.count == 1, "late non-poweredOn advertisement armed an identity or swallowed valid scan")
        }

        let (pure, purePeripheral, pureOwner) = fixture()
        pure.scanPureModel = true
        discover(pure, purePeripheral, manufacturer: nil)
        discover(pure, purePeripheral, manufacturer: nil)
        expect(BleEC.scanResult.events.count == 1 && pure.pendingReconnectIdentities[pureOwner.key] != nil && pure.armCalls == 0, "pure mode duplicate behavior or frozen ownership changed")

        // Identity boundaries are real model matching: prefixes/config mismatch
        // are ordinary advertisements, never authorization for this exact owner.
        let (mismatch, other, pending) = fixture(awaiting: false)
        discover(mismatch, other, name: "EVEN R1_FFFFFF")
        expect(mismatch.pendingReconnectIdentities[pending.key] != nil && mismatch.armCalls == 0 && BleEC.scanResult.events.count == 1, "same product prefix claimed another exact owner")

        // Cancellation/config teardown themselves are outside this fixture.
        // Start after their existing removal boundary; scans cannot recreate an
        // absent owner, including another scan window or a late advertisement.
        let (cancelled, cancelledPeripheral, _) = fixture()
        cancelled.pendingReconnectIdentities.removeAll()
        discover(cancelled, cancelledPeripheral)
        cancelled.scanResultTemp.removeAll()
        discover(cancelled, cancelledPeripheral)
        expect(cancelled.pendingReconnectIdentities.isEmpty && cancelled.tasks.isEmpty && cancelled.armCalls == 0 && BleEC.scanResult.events.count == 2, "late scan resurrected cancelled owner")
        let (revoked, revokedPeripheral, _) = fixture()
        revoked.pendingReconnectIdentities.removeAll()
        revoked.bleConfigs = [BleConfig(name: configName, scan: config.scan, autoReconnect: false)]
        discover(revoked, revokedPeripheral)
        expect(revoked.pendingReconnectIdentities.isEmpty && revoked.armCalls == 0 && BleEC.scanResult.events.count == 1, "revoked config recreated owner or lost ordinary scan")

        // An advanced transport epoch still defers identity resolution while
        // allowing its valid advertisement through the unchanged normal parser.
        let (reset, resetPeripheral, resetOwner) = fixture(awaiting: false)
        reset.currentTransportRecoveryEpoch = 5
        discover(reset, resetPeripheral)
        expect(reset.pendingReconnectIdentities[resetOwner.key] != nil && reset.armCalls == 0 && BleEC.scanResult.events.count == 1, "epoch mismatch consumed stale owner or swallowed normal scan")

        if failures.isEmpty {
            print("PASS: production scan/resolver preserves frozen owner, emits validated MAC/SN once per scan window, blocks mfr0 and stale S1, resolves current-epoch S2 once")
            print("PASS: absent cancelled/revoked owners do not resurrect; test excludes teardown, real CoreBluetooth and GATT admission")
        } else {
            failures.forEach { print("FAIL: \($0)") }
            exit(1)
        }
    }
}
