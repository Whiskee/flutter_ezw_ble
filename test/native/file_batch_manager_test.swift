import Foundation
import Flutter

// Only CoreBluetooth/registry boundaries are fake. The runner inserts the exact
// production manager entrypoints, shared submission and MethodChannel dispatch.
final class FileManagerLogSink { func emit(_ message: String) {} }
enum BleEC { static let logger = FileManagerLogSink() }
enum CBPeripheralState { case connected, disconnected }
enum CBCharacteristicWriteType { case withoutResponse }
struct CBCharacteristicProperties: OptionSet {
    let rawValue: Int
    static let writeWithoutResponse = CBCharacteristicProperties(rawValue: 1)
}
struct CBUUID { let uuidString: String }
final class CBCharacteristic {
    var properties: CBCharacteristicProperties = [.writeWithoutResponse]
    let uuid = CBUUID(uuidString: "file-characteristic")
}
final class CBPeripheral {
    let identifier: UUID
    var state = CBPeripheralState.connected
    var canSendWriteWithoutResponse = true
    var writes: [Data] = []
    init(identifier: UUID = UUID()) { self.identifier = identifier }
    func writeValue(_ value: Data, for characteristic: CBCharacteristic, type: CBCharacteristicWriteType) {
        writes.append(value)
    }
    func maximumWriteValueLength(for type: CBCharacteristicWriteType) -> Int { 244 }
}
struct ConnectedDevice {
    let peripheral: CBPeripheral
    var writeCharsDic: [Int: CBCharacteristic]
}
struct UpgradeStateRegistry {
    var allowed = true
    func canSend(endpointId: String, psType: Int) -> Bool { allowed }
}
struct BleG2OtaContext {}
struct BleNativeConnectionTrace {
    var lastRssiDbm: Int?
    var rssiAgeMs: Int?
}
final class BleManager {
    static let shared = BleManager()
    var fileWriteQueues: [String: OtaWriteQueue] = [:]
    var otaWriteQueues: [String: OtaWriteQueue] = [:]
    var connectedDevices: [ConnectedDevice] = []
    var upgradeStateRegistry = UpgradeStateRegistry()
    var callable = true
    func checkIsFunctionCanBeCalled() -> Bool { callable }
    func loggerD(msg: String) {}
    func loggerE(msg: String) {}
    func validateOtaWriteIdentity(uuid: String, device: ConnectedDevice,
        expectedSessionGeneration: Int64, expectedAttemptGeneration: Int64,
        otaContext: BleG2OtaContext?) -> FlutterError? { nil }
    func otaWindowCreditOwner(uuid: String, session: Int64, attempt: Int64,
        context: BleG2OtaContext?) -> OtaWindowCreditOwner? { nil }
    func nativeTraceSnapshot(uuid: String) -> BleNativeConnectionTrace? { nil }

    // PRODUCTION_FILE_BATCH_MANAGER
    // PRODUCTION_FILE_READY_CALLBACK
}
private enum FileMethod { case beginFilePacketBatch, cancelFilePacketBatch, sendFilePacketBatch }
private struct FileBridge {
    func dispatch(_ method: FileMethod, arguments: Any?, result: @escaping FlutterResult) {
        switch method {
        // PRODUCTION_FILE_BATCH_DISPATCH
        }
    }
    // PRODUCTION_FILE_BATCH_DECODER
}

@main
private struct FileBatchManagerTests {
    static func main() throws {
        let manager = BleManager.shared
        let bridge = FileBridge()
        let peripheral = CBPeripheral()
        let endpoint = peripheral.identifier.uuidString
        let characteristic = CBCharacteristic()
        func reset() {
            manager.fileWriteQueues.values.forEach { $0.cancelAll(reason: "test reset") }
            manager.fileWriteQueues.removeAll()
            manager.callable = true
            manager.upgradeStateRegistry.allowed = true
            peripheral.state = .connected
            peripheral.canSendWriteWithoutResponse = true
            peripheral.writes.removeAll()
            characteristic.properties = [.writeWithoutResponse]
            manager.connectedDevices = [ConnectedDevice(peripheral: peripheral, writeCharsDic: [3: characteristic])]
        }
        func invoke(_ method: FileMethod, _ arguments: [String: Any]) -> [Any?] {
            var values: [Any?] = []
            bridge.dispatch(method, arguments: arguments) { values.append($0) }
            return values
        }
        func begin() throws -> String {
            let values = invoke(.beginFilePacketBatch, ["uuid": endpoint])
            guard values.count == 1, let token = values[0] as? String else {
                throw NSError(domain: "FileBatchManagerTests.begin", code: 1)
            }
            return token
        }
        func send(_ token: Any?, psType: Int = 3, packets: [FlutterStandardTypedData]? = nil) -> [Any?] {
            var args: [String: Any] = ["uuid": endpoint, "psType": psType,
                "packets": packets ?? [FlutterStandardTypedData(bytes: Data([1]))]]
            if let token { args["fileBatchToken"] = token }
            return invoke(.sendFilePacketBatch, args)
        }
        func expectError(_ values: [Any?], _ message: String) throws {
            try expect(values.count == 1 && values[0] is FlutterError, message)
        }

        reset()
        try expect(invoke(.cancelFilePacketBatch, ["uuid": endpoint, "fileBatchToken": "unknown"])[0] as? Bool == false
            && manager.fileWriteQueues.isEmpty, "unknown cancellation must not construct queue")
        try expectError(send("unknown"), "unknown send must reject")
        try expect(manager.fileWriteQueues.isEmpty, "unknown send must not construct queue")
        manager.callable = false
        try expectError(invoke(.beginFilePacketBatch, ["uuid": endpoint]), "begin requires live manager")
        reset()
        manager.upgradeStateRegistry.allowed = false
        try expectError(invoke(.beginFilePacketBatch, ["uuid": endpoint]), "begin obeys upgrade gate")
        reset()
        peripheral.state = .disconnected
        try expectError(invoke(.beginFilePacketBatch, ["uuid": endpoint]), "begin requires connected physical target")
        reset()
        characteristic.properties = []
        try expectError(invoke(.beginFilePacketBatch, ["uuid": endpoint]), "begin requires actual WWR characteristic")

        reset()
        let cancelled = try begin()
        manager.callable = false
        try expect(invoke(.cancelFilePacketBatch, ["uuid": endpoint, "fileBatchToken": cancelled])[0] as? Bool == true,
            "cancel must still revoke after manager gate closes")
        manager.callable = true
        try expectError(send(cancelled), "cancel-before-send cannot resurrect via manager")
        try expect(peripheral.writes.isEmpty, "retired token writes nothing")

        reset()
        let completed = try begin()
        try expect(send(completed).count == 1 && peripheral.writes == [Data([1])], "bridge passes live token to actual queue")
        try expectError(send(completed), "completed token cannot be reused")
        let replacement = try begin()
        try expect(replacement != completed, "manager replacement mints different native token")
        try expectError(send(7), "malformed token cannot fall back to legacy")
        try expect(invoke(.cancelFilePacketBatch, ["uuid": endpoint, "fileBatchToken": replacement])[0] as? Bool == true,
            "malformed send cannot clear unrelated valid reservation")

        for failure in ["empty", "psType", "gate", "target", "physical"] {
            reset()
            let token = try begin()
            switch failure {
            case "empty": try expectError(send(token, packets: []), "empty batch fails")
            case "psType": try expectError(send(token, psType: 1), "wrong psType fails")
            case "gate":
                manager.upgradeStateRegistry.allowed = false
                try expectError(send(token), "changed upgrade gate fails")
            case "target":
                manager.connectedDevices[0].writeCharsDic.removeAll()
                try expectError(send(token), "removed target fails")
            default:
                manager.connectedDevices[0] = ConnectedDevice(peripheral: CBPeripheral(identifier: peripheral.identifier),
                    writeCharsDic: [3: characteristic])
                try expectError(send(token), "same UUID replacement is not frozen physical target")
            }
            try expect(invoke(.cancelFilePacketBatch, ["uuid": endpoint, "fileBatchToken": token])[0] as? Bool == false,
                "preflight \(failure) must retire matching unused reservation before error")
            try expect(peripheral.writes.isEmpty, "preflight \(failure) cannot write")
        }

        for malformed in ["psType", "mixedPackets", "missingPackets"] {
            reset()
            let token = try begin()
            var args: [String: Any] = ["uuid": endpoint, "psType": 3, "fileBatchToken": token,
                "packets": [FlutterStandardTypedData(bytes: Data([1]))]]
            switch malformed {
            case "psType": args["psType"] = "3"
            case "mixedPackets": args["packets"] = [FlutterStandardTypedData(bytes: Data([1])), "invalid"] as [Any]
            default: args.removeValue(forKey: "packets")
            }
            try expectError(invoke(.sendFilePacketBatch, args), "owned malformed \(malformed) rejects entire batch")
            try expect(peripheral.writes.isEmpty, "owned malformed \(malformed) must not submit partial frames")
            try expect(invoke(.cancelFilePacketBatch, ["uuid": endpoint, "fileBatchToken": token])[0] as? Bool == false,
                "owned malformed \(malformed) retires matching unused reservation")
        }

        reset()
        let held = try begin()
        peripheral.canSendWriteWithoutResponse = false
        var heldResults: [Any?] = []
        manager.sendFilePacketBatch(uuid: endpoint, packets: [Data([1]), Data([2])], psType: 3,
            fileBatchToken: held, result: { heldResults.append($0) })
        try expectError(send(held), "duplicate pending send fails")
        try expect(heldResults.isEmpty && manager.fileWriteQueues[endpoint]?.queueDepth == 2,
            "duplicate must not retire the already submitted original")
        try expect(invoke(.cancelFilePacketBatch, ["uuid": endpoint, "fileBatchToken": held])[0] as? Bool == true
            && heldResults.count == 1, "original still cancels once")

        reset()
        let oldPhysicalToken = try begin()
        let oldQueue = manager.fileWriteQueues[endpoint]
        let newPhysical = CBPeripheral(identifier: peripheral.identifier)
        manager.connectedDevices = [ConnectedDevice(peripheral: newPhysical, writeCharsDic: [3: characteristic])]
        try expectError(invoke(.beginFilePacketBatch, ["uuid": endpoint]), "same UUID must not transfer reservation to another physical object")
        try expect(manager.fileWriteQueues[endpoint] === oldQueue, "failed begin must not replace registered physical queue")
        try expect(invoke(.cancelFilePacketBatch, ["uuid": endpoint, "fileBatchToken": oldPhysicalToken])[0] as? Bool == true,
            "old exact physical reservation remains revocable")
        oldQueue?.cancelAll(reason: "physical replacement")
        manager.fileWriteQueues.removeAll()
        let newPhysicalToken = try begin()
        newPhysical.canSendWriteWithoutResponse = false
        var newPhysicalResults: [Any?] = []
        manager.sendFilePacketBatch(uuid: endpoint, packets: [Data([9])], psType: 3,
            fileBatchToken: newPhysicalToken, result: { newPhysicalResults.append($0) })
        newPhysical.canSendWriteWithoutResponse = true
        manager.peripheralIsReady(toSendWriteWithoutResponse: peripheral)
        try expect(newPhysical.writes.isEmpty && newPhysicalResults.isEmpty,
            "old same-UUID ready callback cannot pump replacement physical wait")
        manager.peripheralIsReady(toSendWriteWithoutResponse: newPhysical)
        try expect(newPhysical.writes == [Data([9])] && newPhysicalResults.count == 1,
            "current physical ready callback may resume matching owner")
        reset()
        try expect(send(nil).count == 1 && peripheral.writes == [Data([1])], "omitted token preserves legacy FILE path")
        print("production file batch manager/bridge: admission, retirement, malformed-frame and legacy regressions passed")
    }

    private static func expect(_ accepted: Bool, _ message: String) throws {
        if !accepted { throw NSError(domain: "FileBatchManagerTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
}
