import Foundation

// Compile the production BleManager target validator against identity-only fakes.
// This does not pretend to simulate CoreBluetooth, writes, or firmware ACKs.
private enum CBPeripheralState { case connected, disconnected }
private final class CBPeripheral {
    let identifier: UUID
    var state = CBPeripheralState.connected
    init(identifier: UUID = UUID()) { self.identifier = identifier }
}
private final class CBCharacteristic {}
private final class OtaWriteQueue {}
private struct ConnectedDevice {
    let peripheral: CBPeripheral
    var writeCharsDic: [Int: CBCharacteristic]
}
private struct UpgradeStateRegistry {
    var allowed = true
    func canSend(endpointId: String, psType: Int) -> Bool { allowed }
}
private final class FileTargetManager {
    var fileWriteQueues: [String: OtaWriteQueue] = [:]
    var connectedDevices: [ConnectedDevice] = []
    var upgradeStateRegistry = UpgradeStateRegistry()
    var callable = true
    private func checkIsFunctionCanBeCalled() -> Bool { callable }

    // PRODUCTION_FILE_TARGET_VALIDATOR

    func accepts(uuid: String, queue: OtaWriteQueue?, peripheral: CBPeripheral,
        expectedPeripheral: CBPeripheral, characteristic: CBCharacteristic) -> Bool {
        canSubmitFilePacket(uuid: uuid, psType: 3, queue: queue,
            peripheral: peripheral, expectedPeripheral: expectedPeripheral,
            characteristic: characteristic)
    }
}

@main
private struct FileWriteTargetTests {
    static func main() throws {
        let peripheral = CBPeripheral()
        let characteristic = CBCharacteristic()
        let queue = OtaWriteQueue()
        let endpoint = peripheral.identifier.uuidString
        let manager = FileTargetManager()
        func reset() {
            peripheral.state = .connected
            manager.callable = true
            manager.upgradeStateRegistry.allowed = true
            manager.fileWriteQueues = [endpoint: queue]
            manager.connectedDevices = [ConnectedDevice(peripheral: peripheral,
                writeCharsDic: [3: characteristic])]
        }
        func accepts(_ candidateQueue: OtaWriteQueue? = queue,
            _ candidatePeripheral: CBPeripheral? = nil,
            _ candidateCharacteristic: CBCharacteristic? = nil) -> Bool {
            manager.accepts(uuid: endpoint, queue: candidateQueue,
                peripheral: candidatePeripheral ?? peripheral,
                expectedPeripheral: peripheral,
                characteristic: candidateCharacteristic ?? characteristic)
        }
        reset()
        try expect(accepts(), "current registered physical target must stay writable")
        try expect(!accepts(nil), "released queue must reject")
        manager.fileWriteQueues.removeAll()
        try expect(!accepts(), "removed queue owner must reject")
        manager.fileWriteQueues[endpoint] = OtaWriteQueue()
        try expect(!accepts(), "replacement queue at same endpoint must reject old owner")
        reset()
        manager.callable = false
        try expect(!accepts(), "manager teardown must reject")
        reset()
        manager.upgradeStateRegistry.allowed = false
        try expect(!accepts(), "upgrade entered while waiting must reject file target")
        reset()
        try expect(!accepts(queue, CBPeripheral(identifier: peripheral.identifier)),
            "same UUID is not the captured physical peripheral")
        peripheral.state = .disconnected
        try expect(!accepts(), "disconnected captured physical target must reject")
        reset()
        manager.connectedDevices.removeAll()
        try expect(!accepts(), "removed live device must reject")
        manager.connectedDevices = [ConnectedDevice(
            peripheral: CBPeripheral(identifier: peripheral.identifier),
            writeCharsDic: [3: characteristic])]
        try expect(!accepts(), "same endpoint on a new physical target must reject")
        reset()
        manager.connectedDevices[0].writeCharsDic.removeAll()
        try expect(!accepts(), "removed characteristic must reject")
        manager.connectedDevices[0].writeCharsDic[3] = CBCharacteristic()
        try expect(!accepts(), "replacement characteristic must reject old target")
        reset()
        try expect(!accepts(queue, nil, CBCharacteristic()), "different frozen characteristic must reject")
        try expect(accepts(), "rejected stale targets must not poison current admission")
        print("production file target validator: 14 identity and gate checks passed")
    }

    private static func expect(_ accepted: Bool, _ message: String) throws {
        if !accepted {
            throw NSError(domain: "FileWriteTargetTests", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
        }
    }
}
