import Foundation

// Only platform edges are replaced. The generated file compiles the actual
// production manager extension and sendCmd body with these CB stand-ins.
final class CBCharacteristic {
    let uuid: UUID
    var value: Data? = Data([1])
    var isNotifying = true
    init(uuid: UUID = UUID()) { self.uuid = uuid }
}
final class CBPeripheral {
    enum State { case connected, disconnected }
    enum WriteType { case withoutResponse }
    let identifier: UUID
    var name: String? = "test"
    init(identifier: UUID = UUID()) { self.identifier = identifier }
    var state = State.connected
    var notifications: [Bool] = []
    var writes = 0
    func setNotifyValue(_ value: Bool, for characteristic: CBCharacteristic) { notifications.append(value) }
    func writeValue(_ data: Data, for characteristic: CBCharacteristic, type: WriteType) { writes += 1 }
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
}
struct PrivateService { var type: Int; var readCharUUID: UUID }
struct Config { var privateServices: [PrivateService] = [] }
final class TestEvents {
    var values: [[String: Any]] = []
    func emit(_ value: [String: Any]) { values.append(value) }
}
enum BleEC { static let receiveData = TestEvents() }
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
        manager.admission = nil
        manager.connectedDevices[0].isConnected = false
        check(manager.getRuntimeCommonOwner(uuid: uuid) == nil, "cache without business connected cannot pause")
        print("runtime common manager: all behavior checks passed")
    }
}
