import Foundation

// Utility convenience normally supplied by flutter_ezw_utils; owner matching
// itself is extracted from the production reconnect coordinator.
extension String { var isNotEmpty: Bool { !isEmpty } }

// Only platform edges are replaced. The generated file compiles the actual
// production manager extension and sendCmd body with these CB stand-ins.
final class CBCharacteristic {
    let uuid: UUID
    var value: Data? = Data([1])
    var isNotifying = true
    var service: CBService?
    init(uuid: UUID = UUID()) { self.uuid = uuid }
}
final class CBService {
    let uuid: UUID
    let peripheral: CBPeripheral
    init(uuid: UUID, peripheral: CBPeripheral) {
        self.uuid = uuid
        self.peripheral = peripheral
    }
}
final class CBPeripheral {
    enum State { case connected, disconnected }
    enum WriteType { case withoutResponse }
    let identifier: UUID
    var name: String? = "test"
    init(identifier: UUID = UUID()) { self.identifier = identifier }
    var state = State.connected
    var canSendWriteWithoutResponse = true
    var notifications: [Bool] = []
    var writes = 0
    var lastWriteCharacteristic: CBCharacteristic?
    func setNotifyValue(_ value: Bool, for characteristic: CBCharacteristic) { notifications.append(value) }
    func writeValue(_ data: Data, for characteristic: CBCharacteristic, type: WriteType) {
        writes += 1
        lastWriteCharacteristic = characteristic
    }
}
struct FlutterError {
    let code: String
    let message: String?
    let details: Any?
}
typealias FlutterResult = (Any?) -> Void
struct BleG2OtaContext {
    var transactionId = ""
    var generation: Int64 = 0
    var instanceId = ""
    init(data: [String: Any]? = nil) {}
}
final class FlutterStandardTypedData {
    let data: Data
    init(_ data: Data) { self.data = data }
}
struct PrivateService {
    var type: Int
    var readCharUUID: UUID?
    var writeCharUUID: UUID? = nil
    var serviceUUID: UUID = UUID()
}
typealias BlePrivateService = PrivateService
struct Config {
    var name = "g2"
    var privateServices: [PrivateService] = []
}
final class TestEvents {
    var values: [[String: Any]] = []
    func emit(_ value: [String: Any]) { values.append(value) }
}
final class LogEvents { func emit(_ value: String) {} }
enum BleEC {
    static let receiveData = TestEvents()
    static let logger = LogEvents()
}
struct BleConnectedDevice {
    var peripheral: CBPeripheral
    var belongConfig = Config()
    var isConnected = true
    var isBleFlowCompleted = true
    var readCharsDic: [Int: CBCharacteristic]
    var writeCharsDic: [Int: CBCharacteristic]
}
struct Admission {
    var sessionId = "session"
    var sessionGeneration: Int64
    var generation: Int64
}
struct ConnectionSession { var peripheral: CBPeripheral }
struct Task {
    var uuid: String
    var belongConfig = "g2"
    var name = "test"
    var sessionGeneration: Int64 = 3
    var lastConnectedGeneration: Int64? = 3
    var lastConnectedAttemptGeneration: Int64? = 4
}
struct Metadata { var sessionGeneration: Int64; var attemptGeneration: Int64 }
enum BleExplicitCancellationMetadataPolicy {
    static func resolve(currentAdmission: Admission?, reconnectTask: Task?) -> Metadata? {
        if let currentAdmission { return Metadata(sessionGeneration: currentAdmission.sessionGeneration, attemptGeneration: currentAdmission.generation) }
        guard let reconnectTask else { return nil }
        return Metadata(sessionGeneration: reconnectTask.sessionGeneration,
            attemptGeneration: reconnectTask.sessionGeneration == reconnectTask.lastConnectedGeneration ? reconnectTask.lastConnectedAttemptGeneration ?? 0 : 0)
    }
}
final class OtaTransactions {
    var allowed = true
    func shouldAllowLegacyCleanup(endpointId: String) -> Bool { allowed }
    func activeContext(for uuid: String) -> BleG2OtaContext? { nil }
}
final class UpgradeRegistry {
    var active = false
    func contains(_ uuid: String) -> Bool { active }
    func canSend(endpointId: String, psType: Int, allowDuringUpgrade: Bool) -> Bool { !active || psType == 1 || allowDuringUpgrade }
}
final class Central {
    var cancels = 0
    func cancelPeripheralConnection(_ peripheral: CBPeripheral) { cancels += 1 }
}

private func check(_ value: @autoclosure () -> Bool, _ reason: String) {
    if !value() { fatalError(reason) }
}

/// Exercise the production channel case and manager extension against actual
/// write counters; only CB/framework boundaries are stand-ins.
private func testOwnedCommonWrites() {
    let manager = BleManager.shared
    let peripheral = CBPeripheral()
    let common = CBCharacteristic()
    let write = CBCharacteristic()
    let service = CBService(uuid: UUID(), peripheral: peripheral)
    common.service = service
    write.service = service
    let config = Config(privateServices: [PrivateService(type: 0,
        readCharUUID: common.uuid, writeCharUUID: write.uuid, serviceUUID: service.uuid)])
    manager.bleConfigs = [config]
    manager.connectedDevices = [BleConnectedDevice(peripheral: peripheral,
        belongConfig: config, readCharsDic: [0: common], writeCharsDic: [0: write])]
    let uuid = peripheral.identifier.uuidString
    manager.reconnectTasks[uuid] = Task(uuid: uuid)
    let attempt = BleBusinessConnectionAttempt(uuid: uuid, sessionGeneration: 3, attemptGeneration: 4)
    let packet = Data([0xaa, 0x84])
    let intent: [String: Any] = ["uuid": uuid, "sessionGeneration": Int64(3), "attemptGeneration": Int64(4)]
    let arguments: [String: Any] = ["uuid": uuid, "psType": 0,
        "data": FlutterStandardTypedData(packet), "expectedAttempt": intent]
    var completions = 0
    var lastError: FlutterError?
    func send(_ value: [String: Any]) {
        let before = completions
        manager.dispatchSendCmd(value) { result in
            completions += 1
            lastError = result as? FlutterError
        }
        check(completions == before + 1, "each channel write completes exactly once")
    }
    send(arguments)
    check(lastError == nil && peripheral.writes == 1 && peripheral.lastWriteCharacteristic === write,
        "valid owned common packet reaches the configured write characteristic")
    if case .owned(let first) = BleOwnedCommonWriteIntent.decode([
        "uuid": uuid, "expectedAttempt": ["uuid": uuid, "sessionGeneration": 1, "attemptGeneration": 1]
    ]) {
        check(first.sessionGeneration == 1 && first.attemptGeneration == 1,
            "codec integer one is valid and distinct from boolean true")
    } else { fatalError("the initial positive pair must remain valid") }

    let malformed: [Any] = [NSNull(), [:], ["uuid": uuid],
        ["uuid": uuid, "sessionGeneration": 3, "attemptGeneration": 0],
        ["uuid": uuid, "sessionGeneration": -3, "attemptGeneration": 4],
        ["uuid": uuid, "sessionGeneration": "3", "attemptGeneration": 4],
        ["uuid": uuid, "sessionGeneration": 3.0, "attemptGeneration": 4],
        ["uuid": uuid, "sessionGeneration": true, "attemptGeneration": 4],
        ["uuid": uuid, "sessionGeneration": NSNumber(value: UInt64.max), "attemptGeneration": 4],
        ["uuid": UUID().uuidString, "sessionGeneration": 3, "attemptGeneration": 4]]
    for invalid in malformed {
        var value = arguments
        value["expectedAttempt"] = invalid
        send(value)
        check(lastError?.code == "owned_write_invalid_arguments" && peripheral.writes == 1,
            "malformed owner cannot downgrade into a legacy write")
    }
    for badData in [NSNull(), FlutterStandardTypedData(Data())] as [Any] {
        var value = arguments
        value["data"] = badData
        send(value)
        check(lastError?.code == "owned_write_invalid_arguments" && peripheral.writes == 1,
            "owned empty/missing data cannot report success")
    }
    for psType in [1, 2, 3, -1] {
        var value = arguments
        value["psType"] = psType
        send(value)
        check(lastError?.code == "owned_write_unsupported" && peripheral.writes == 1,
            "OTA/FILE/other owned lanes stay unsupported")
    }
    var invalidType = arguments
    invalidType["psType"] = false
    send(invalidType)
    check(lastError?.code == "owned_write_invalid_arguments", "bool is not a channel integer")

    manager.setRuntimeCommonNotifications(uuid: uuid, sessionGeneration: 3,
        attemptGeneration: 4, revision: 1, enabled: false) { _ in }
    send(arguments)
    check(lastError?.code == "COMMON_NOT_READY" && peripheral.writes == 1,
        "pending common unsubscribe fences owned writes before CB")
    _ = manager.runtimeCommonNotifications.didUpdate(uuid: uuid,
        peripheralId: ObjectIdentifier(peripheral), characteristicId: ObjectIdentifier(common),
        enabled: false, failed: false)
    manager.setRuntimeCommonNotifications(uuid: uuid, sessionGeneration: 3,
        attemptGeneration: 4, revision: 2, enabled: true) { _ in }
    send(arguments)
    check(lastError?.code == "COMMON_NOT_READY" && peripheral.writes == 1,
        "pending common restore does not grant write admission")
    _ = manager.runtimeCommonNotifications.didUpdate(uuid: uuid,
        peripheralId: ObjectIdentifier(peripheral), characteristicId: ObjectIdentifier(common),
        enabled: true, failed: false)
    common.isNotifying = false
    send(arguments)
    check(lastError?.code == "COMMON_NOT_READY" && peripheral.writes == 1,
        "the physical characteristic must also remain notifying")
    common.isNotifying = true
    send(arguments)
    check(lastError == nil && peripheral.writes == 2, "confirmed common restore permits current owner")

    manager.bleConfigs = []
    send(arguments)
    check(lastError?.code == "owned_write_stale" && peripheral.writes == 2,
        "a removed configuration cannot keep its old write lease")
    manager.bleConfigs = [Config(privateServices: [PrivateService(type: 0,
        readCharUUID: common.uuid, writeCharUUID: UUID(), serviceUUID: service.uuid)])]
    send(arguments)
    check(lastError?.code == "owned_write_stale" && peripheral.writes == 2,
        "reconfigured GATT characteristics cannot inherit cached readiness")
    manager.bleConfigs = [config]
    manager.reconnectTasks[uuid]?.belongConfig = "another-config"
    send(arguments)
    check(lastError?.code == "owned_write_stale" && peripheral.writes == 2,
        "reconnect and cached config owners must match")
    manager.reconnectTasks[uuid]?.belongConfig = config.name
    manager.reconnectTasks[uuid]?.lastConnectedAttemptGeneration = 0
    send(arguments)
    check(lastError?.code == "owned_write_stale" && peripheral.writes == 2,
        "zero committed attempt cannot authorize a positive caller token")
    manager.reconnectTasks[uuid]?.lastConnectedAttemptGeneration = nil
    send(arguments)
    check(lastError?.code == "owned_write_stale" && peripheral.writes == 2,
        "missing committed attempt cannot authorize a positive caller token")
    manager.reconnectTasks[uuid]?.lastConnectedAttemptGeneration = 4
    manager.reconnectTasks[uuid]?.sessionGeneration = 5
    send(arguments)
    check(lastError?.code == "owned_write_stale" && peripheral.writes == 2,
        "an old successful pair cannot be borrowed by a newer session")
    manager.reconnectTasks[uuid]?.sessionGeneration = 3
    common.service = CBService(uuid: service.uuid, peripheral: CBPeripheral(identifier: peripheral.identifier))
    send(arguments)
    check(lastError?.code == "owned_write_stale" && peripheral.writes == 2,
        "same UUID cannot authorize another peripheral object's characteristic")
    common.service = service
    write.service = CBService(uuid: service.uuid, peripheral: CBPeripheral(identifier: peripheral.identifier))
    send(arguments)
    check(lastError?.code == "owned_write_stale" && peripheral.writes == 2,
        "write and read must both belong to the exact peripheral object")
    write.service = service
    manager.upgradeStateRegistry.active = true
    var otaBypass = arguments
    otaBypass["allowDuringUpgrade"] = true
    send(otaBypass)
    check(lastError?.code == "owned_write_stale" && peripheral.writes == 2,
        "owned common cannot borrow the legacy OTA whitelist")
    manager.upgradeStateRegistry.active = false
    manager.g2OtaTransactions.allowed = false
    send(arguments)
    check(lastError?.code == "owned_write_stale" && peripheral.writes == 2,
        "an active OTA transaction prevents owned common writes")
    manager.g2OtaTransactions.allowed = true
    manager.admission = Admission(sessionGeneration: 3, generation: 5)
    send(arguments)
    check(lastError?.code == "owned_write_stale" && peripheral.writes == 2,
        "a newly admitted attempt fences the previous committed token")
    manager.admission = nil
    manager.cancellationBarrier = true
    send(arguments)
    check(lastError?.code == "owned_write_stale" && peripheral.writes == 2,
        "a physical cancellation barrier closes the owned write edge")
    manager.cancellationBarrier = false

    // Simulate the platform completing a replacement physical attempt. Queued
    // SDK fragments still carrying the old pair must not reach the new object.
    let replacement = CBPeripheral(identifier: peripheral.identifier)
    let replacementCommon = CBCharacteristic(uuid: common.uuid)
    let replacementWrite = CBCharacteristic(uuid: write.uuid)
    let replacementService = CBService(uuid: service.uuid, peripheral: replacement)
    replacementCommon.service = replacementService
    replacementWrite.service = replacementService
    manager.connectedDevices = [BleConnectedDevice(peripheral: replacement,
        belongConfig: config, readCharsDic: [0: replacementCommon], writeCharsDic: [0: replacementWrite])]
    manager.reconnectTasks[uuid]?.lastConnectedAttemptGeneration = 5
    send(arguments)
    check(lastError?.code == "owned_write_stale" && replacement.writes == 0,
        "old queued packet cannot write on a replacement physical owner")
    var current = arguments
    current["expectedAttempt"] = ["uuid": uuid, "sessionGeneration": 3, "attemptGeneration": 5]
    send(current)
    check(lastError == nil && replacement.writes == 1 && replacement.lastWriteCharacteristic === replacementWrite,
        "new exact token writes only its own connection's write characteristic")
    replacement.state = .disconnected
    send(current)
    check(lastError?.code == "owned_write_stale" && replacement.writes == 1,
        "cached connected flags cannot authorize a disconnected peripheral")
    replacement.state = .connected
    manager.callable = false
    send(current)
    check(lastError?.code == "owned_write_stale" && replacement.writes == 1,
        "Bluetooth unavailable cannot produce an owned success receipt")
    manager.callable = true
    manager.connectedDevices[0].isConnected = false
    send(current)
    check(lastError?.code == "owned_write_stale" && replacement.writes == 1,
        "pre-business transport cannot use committed common ownership")

    // Legacy callers retain the old AUTH/initialization behavior even though
    // the new strict branch rejects the same not-yet-committed state.
    var legacy = current
    legacy.removeValue(forKey: "expectedAttempt")
    send(legacy)
    check(lastError == nil && replacement.writes == 2, "unowned initialization path remains compatible")
    check(manager.sendCmd(uuid: uuid, data: packet, psType: 1, expectedAttempt: attempt)?.code
        == "owned_write_unsupported", "direct owned non-common calls also fail closed")
}

@main
struct ManagerBehaviorTests {
    static func main() {
        let manager = BleManager()
        let peripheral = CBPeripheral()
        let common = CBCharacteristic()
        let ota = CBCharacteristic()
        let uuid = peripheral.identifier.uuidString
        manager.connectedDevices = [BleConnectedDevice(peripheral: peripheral,
            readCharsDic: [0: common, 1: ota], writeCharsDic: [0: common, 1: ota])]
        manager.reconnectTasks[uuid] = Task(uuid: uuid)
        manager.connectedDevices[0].belongConfig.privateServices = [PrivateService(type: 0, readCharUUID: common.uuid)]
        manager.peripheral(peripheral, didUpdateValueFor: common, error: nil)
        check(BleEC.receiveData.values.count == 1 && BleEC.receiveData.values.last?["attemptGeneration"] as? Int64 == 4, "current common receipt has exact business pair")
        let receive = BleEC.receiveData.values.last?["receiveIdentity"] as? [String: Any]
        check(receive?["attemptGeneration"] as? Int64 == 4, "current common receipt keeps V2.4 native receive provenance")
        manager.peripheral(CBPeripheral(identifier: peripheral.identifier), didUpdateValueFor: common, error: nil)
        manager.peripheral(peripheral, didUpdateValueFor: CBCharacteristic(uuid: common.uuid), error: nil)
        check(BleEC.receiveData.values.count == 1, "old peripheral/characteristic objects cannot stamp current common pair")
        manager.connectedDevices[0].isConnected = false
        manager.peripheral(peripheral, didUpdateValueFor: common, error: nil)
        check(BleEC.receiveData.values.last?["attemptGeneration"] as? Int64 == 0, "pre-business AUTH receipt keeps legacy zero pair")
        manager.connectedDevices[0].isConnected = true
        check(manager.getRuntimeCommonOwner(uuid: uuid)?["attemptGeneration"] as? Int64 == 4, "read current successful positive pair")
        var result: [String: Any]?
        manager.setRuntimeCommonNotifications(uuid: uuid, sessionGeneration: 3,
            attemptGeneration: 0, revision: 1, enabled: false) { result = $0 as? [String: Any] }
        check(result?["status"] as? String == "stale" && peripheral.notifications.isEmpty, "attempt zero cannot change CCCD")
        manager.setRuntimeCommonNotifications(uuid: uuid, sessionGeneration: 3,
            attemptGeneration: 4, revision: 1, enabled: false) { result = $0 as? [String: Any] }
        check(peripheral.notifications == [false], "valid owner submits common false")
        check(manager.sendCmd(uuid: uuid, data: Data([1]))?.code == "COMMON_NOT_READY" && peripheral.writes == 0, "actual production write rejected before CB")
        check(manager.sendCmd(uuid: uuid, data: Data([1]), psType: 1) == nil && peripheral.writes == 1, "OTA characteristic not fenced")
        _ = manager.runtimeCommonNotifications.didUpdate(uuid: uuid, peripheralId: ObjectIdentifier(peripheral),
            characteristicId: ObjectIdentifier(common), enabled: false, failed: false)
        check(result?["status"] as? String == "confirmed", "manager reports actual false confirmation")
        manager.setRuntimeCommonNotifications(uuid: uuid, sessionGeneration: 3,
            attemptGeneration: 4, revision: 2, enabled: true) { result = $0 as? [String: Any] }
        check(manager.sendCmd(uuid: uuid, data: Data([1]))?.code == "COMMON_NOT_READY", "actual write still blocked awaiting true")
        _ = manager.runtimeCommonNotifications.didUpdate(uuid: uuid, peripheralId: ObjectIdentifier(peripheral),
            characteristicId: ObjectIdentifier(common), enabled: true, failed: false)
        check(manager.sendCmd(uuid: uuid, data: Data([1])) == nil && peripheral.writes == 2, "actual write recovers after true callback")
        manager.reconnectTasks[uuid]?.sessionGeneration = 5
        check(manager.getRuntimeCommonOwner(uuid: uuid) == nil, "new session cannot combine historical attempt")
        manager.reconnectTasks[uuid]?.sessionGeneration = 3
        manager.upgradeStateRegistry.active = true
        check(manager.getRuntimeCommonOwner(uuid: uuid) == nil, "OTA prevents runtime pause")
        manager.upgradeStateRegistry.active = false
        manager.g2OtaTransactions.allowed = false
        check(manager.getRuntimeCommonOwner(uuid: uuid) == nil, "active transaction prevents runtime pause")
        manager.g2OtaTransactions.allowed = true
        manager.admission = Admission(sessionGeneration: 3, generation: 5)
        manager.peripheralConnectionSessions["session"] = ConnectionSession(peripheral: peripheral)
        check(manager.getRuntimeCommonOwner(uuid: uuid) == nil, "new initialization cannot reuse business owner")
        check(manager.sendCmd(uuid: uuid, data: Data([1])) == nil, "new attempt AUTH follows normal path")
        manager.peripheral(peripheral, didUpdateValueFor: common, error: nil)
        let authReceive = BleEC.receiveData.values.last?["receiveIdentity"] as? [String: Any]
        check(authReceive?["attemptGeneration"] as? Int64 == 5, "current initialization stamps its own receive admission")
        let beforeStale = BleEC.receiveData.values.count
        manager.peripheralConnectionSessions["session"] = ConnectionSession(peripheral: CBPeripheral(identifier: peripheral.identifier))
        manager.peripheral(peripheral, didUpdateValueFor: common, error: nil)
        check(BleEC.receiveData.values.count == beforeStale, "stale initialization cannot borrow current runtime common pair")
        manager.admission = nil
        manager.connectedDevices[0].isConnected = false
        check(manager.getRuntimeCommonOwner(uuid: uuid) == nil, "cache without business connected cannot pause")
        testOwnedCommonWrites()
        print("runtime common manager: all behavior checks passed")
    }
}
