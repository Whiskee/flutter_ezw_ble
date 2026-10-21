import Foundation

// Platform-only adapters for the extracted, unchanged production scheduling
// methods. Fake Timer/ProcessInfo advance deterministically without sleeping.
final class FakeClock {
    var systemUptime: TimeInterval = 100
    var timers: [Timer] = []
    func advance(_ seconds: TimeInterval) {
        systemUptime += seconds
        let due = timers.filter { !$0.cancelled && $0.deadline <= systemUptime }
        due.forEach { $0.cancelled = true; $0.callback($0) }
    }
}
enum ProcessInfo { static let processInfo = FakeClock() }

// Keep main-queue work separate from the scheduling call so assertions can
// inspect the persisted owner before the real beginReconnectAttempt body runs.
struct DispatchTime {
    let uptime: TimeInterval
    static func now() -> DispatchTime { DispatchTime(uptime: ProcessInfo.processInfo.systemUptime) }
    static func + (lhs: DispatchTime, rhs: TimeInterval) -> DispatchTime {
        DispatchTime(uptime: lhs.uptime + rhs)
    }
}
final class MainDispatchSpy {
    private var pending: [() -> Void] = []
    func async(execute work: @escaping () -> Void) { pending.append(work) }
    func asyncAfter(deadline: DispatchTime, execute work: @escaping () -> Void) {
        _ = Timer.scheduledTimer(withTimeInterval: max(0, deadline.uptime - ProcessInfo.processInfo.systemUptime), repeats: false) { _ in work() }
    }
    func drain() {
        let ready = pending
        pending.removeAll()
        ready.forEach { $0() }
    }
}
enum DispatchQueue { static let main = MainDispatchSpy() }
final class Timer {
    let deadline: TimeInterval
    let callback: (Timer) -> Void
    var cancelled = false
    init(delay: TimeInterval, callback: @escaping (Timer) -> Void) {
        deadline = ProcessInfo.processInfo.systemUptime + delay
        self.callback = callback
    }
    func invalidate() { cancelled = true }
    static func scheduledTimer(withTimeInterval delay: TimeInterval, repeats: Bool, block: @escaping (Timer) -> Void) -> Timer {
        precondition(!repeats)
        let timer = Timer(delay: delay, callback: block)
        ProcessInfo.processInfo.timers.append(timer)
        return timer
    }
}
enum BleConnectState: String { case disconnectFromSys, noDeviceFound }
enum BleConnectSource { case autoReconnect, manualReconnect, stateRestoration }
enum PairingRecoveryState { case normal, awaitingFreshAdvertisement }
enum OwnerDisposition { case created, deferred, rejected }
struct BleReconnectOwnerActivationOutcome { let disposition: OwnerDisposition; let reason: String }
struct BleDevice { let belongConfig: String; let name: String; let uuid: String; let sn: String; let mac: String; let rssi: Int }
struct BleConnectedDevice { let peripheral: CBPeripheral; let isConnected: Bool }
struct BleEasyConnect {
    let configName: String; let uuid: String; let name: String
    let afterUpgrade: Bool; let directConnect: Bool; let time: TimeInterval
    var bleConfig: BleConfig?
}
enum BleStateRestorationEscrowState { case connected, pending, idle }
struct BleStateRestorationEscrowClaim {
    let peripheral: CBPeripheral; let state: BleStateRestorationEscrowState
    var peerConnectedObservedAt: Date? = nil
}
final class RestorationSpy {
    var peripherals: [CBPeripheral] = []
    var debt: BleInvalidParametersBackoff?
    func invalidParametersBackoff(uuid: String) -> BleInvalidParametersBackoff? { debt }
    func contains(uuid: String) -> Bool { peripherals.contains { $0.identifier.uuidString == uuid } }
    func owns(_ peripheral: CBPeripheral) -> Bool { peripherals.contains { $0 === peripheral } }
}
enum BleReconnectSourcePolicy { static func afterTerminalAttempt() -> BleConnectSource { .autoReconnect } }
struct BleConfig { let name: String; var autoReconnect = true }
struct BleReconnectTask {
    let belongConfig: String
    var uuid: String
    var name: String
    var ownerToken = UUID()
    var sessionGeneration: Int64 = 2
    var recoveryEpoch: Int64 = 4
    var invalidParametersBackoff = BleInvalidParametersBackoff()
    var awaitingRecoveryActivation = false
    var pausedByBluetoothOff = false
    var deferredByAppInactivity = false
    var pairingRecoveryState = PairingRecoveryState.normal
    var source = BleConnectSource.autoReconnect
    var attempt = 0
    var timer: Timer?
}
let CBConnectPeripheralOptionEnableAutoReconnect = "autoReconnect"
final class Central {
    enum State { case poweredOn, poweredOff; var label: String { "state" } }
    var state = State.poweredOn
    var connectStarts = 0
    func connect(_ peripheral: CBPeripheral, options: [String: Bool]? = nil) { connectStarts += 1 }
    func cancelPeripheralConnection(_ peripheral: CBPeripheral) {}
}
final class UpgradeRegistry { func contains(_ uuid: String) -> Bool { false } }
final class CBPeripheral {
    enum State: Int { case connected, disconnected, connecting, disconnecting }
    let identifier: UUID
    var state = State.disconnected
    var name: String? = "left"
    weak var delegate: AnyObject?
    init(_ uuid: UUID) { identifier = uuid }
}
struct BleConnectionAdmission: Equatable {
    let endpointId: String
    let sessionId: Int64
    var generation: Int64 { sessionId }
    let sessionGeneration: Int64
    var source: BleConnectSource = .autoReconnect
}
struct BlePeripheralConnectionSession {
    let peripheral: CBPeripheral
    let deviceName: String
    var hasObservedPhysicalContact = false
}
final class BarrierSpy { func isBlocking(endpointId: String) -> Bool { false } }
struct BleReconnectTarget {
    let belongConfig: String; let uuid: String; let name: String; let expectedMacSuffix: String
}
final class MigrationStoreFixture {
    func migrate(oldUuid: String, oldName: String, to: BleReconnectTarget) {}
    func target(uuid: String, name: String) -> BleReconnectTarget? { nil }
}
final class MigrationAliasFixture { func migrate(from: String, to: String) {} }
final class AdmissionGateFixture { func retireInactiveEndpoint(_ uuid: String) {} }
final class BleManager {
    var reconnectTasks: [String: BleReconnectTask] = [:]
    let reconnectStore = MigrationStoreFixture()
    let reconnectIdentityAliases = MigrationAliasFixture()
    let connectionAdmissionGate = AdmissionGateFixture()
    var bleConfigs = [BleConfig(name: "g2")]
    var centralManager = Central()
    let upgradeStateRegistry = UpgradeRegistry()
    var currentTransportRecoveryEpoch: Int64 = 4
    var physicalStarts: [String] = []
    // Snapshot the production begin call rather than deriving its source from
    // the stored owner after dispatch; that would hide stale argument copies.
    var directReconnectStarts: [BleReconnectTask] = []
    var connectedDevices: [BleConnectedDevice] = []
    let restorationCoordinator = RestorationSpy()
    var scanResultTemp: [(BleDevice, CBPeripheral)] = []
    var activeRequests: [BleEasyConnect] = []
    func upsertActiveConnectRequest(_ request: BleEasyConnect) { activeRequests = [request] }
    func replaceConnectionCache(peripheral: CBPeripheral, config: BleConfig, reason: String) {}
    func registerConnectionAttempt(peripheral: CBPeripheral, config: BleConfig, deviceName: String, afterUpgrade: Bool, source: BleConnectSource, sessionGeneration: Int64) -> BleConnectionAdmission? {
        let admission = BleConnectionAdmission(endpointId: peripheral.identifier.uuidString, sessionId: 500, sessionGeneration: sessionGeneration)
        admissions[admission.endpointId] = admission
        peripheralConnectionSessions[500] = BlePeripheralConnectionSession(peripheral: peripheral, deviceName: deviceName)
        return admission
    }
    func connectPeripheralAfterCancellationBarrier(_ peripheral: CBPeripheral, autoReconnect: Bool) {
        drivePeripheralConnection(peripheral, expectedAdmission: currentConnectionAdmission(uuid: peripheral.identifier.uuidString)!, autoReconnect: autoReconnect, remainingStateChecks: 10, reason: "restoration")
    }
    func armPeerConnectedContactGrace(_ peripheral: CBPeripheral, reason: String) {}
    func activateArmedReconnectTask(_ task: BleReconnectTask, source: BleConnectSource) -> BleReconnectOwnerActivationOutcome {
        beginReconnectAttempt(uuid: task.uuid)
        return BleReconnectOwnerActivationOutcome(disposition: .created, reason: "fixture")
    }
    let peripheralValidity = BlePeripheralValidityRegistry()
    let peripheralCancellationBarrierGate = BarrierSpy()
    var admissions: [String: BleConnectionAdmission] = [:]
    var peripheralConnectionSessions: [Int64: BlePeripheralConnectionSession] = [:]
    var removedRequests = 0
    var watchdogStarts = 0
    var gateStarts = 0
    func currentConnectionAdmission(uuid: String) -> BleConnectionAdmission? { admissions[uuid] }
    func currentConnectionAdmission(_ expected: BleConnectionAdmission) -> BleConnectionAdmission? {
        admissions[expected.endpointId] == expected ? expected : nil
    }
    func removeActiveConnectRequest(uuid: String, name: String) { removedRequests += 1 }
    func releaseConnectionAdmissionAndStartNext(_ admission: BleConnectionAdmission, invalidateEndpoint: Bool) {
        admissions.removeValue(forKey: admission.endpointId)
        peripheralConnectionSessions.removeValue(forKey: admission.sessionId)
    }
    func enqueuePhysicalConnectionThroughGate(_ peripheral: CBPeripheral) { gateStarts += 1 }
    func startPendingPhysicalConnectWatchdog(_ peripheral: CBPeripheral, admission: BleConnectionAdmission, autoReconnect: Bool) { watchdogStarts += 1 }
    var inactiveWithoutObject = false
    let passiveReconnectDebounceMs: Double = 3000
    func reconnectKey(uuid: String) -> String { uuid.uppercased() }
    func isSameConnectTarget(storedUuid: String, storedName: String, uuid: String, name: String) -> Bool { storedUuid == uuid }
    func shouldScheduleReconnect(state: BleConnectState) -> Bool { true }
    func otaReconnectSchedulingAdmission(task: BleReconnectTask, observedUuid: String) -> (allowed: Bool, isOtaGranted: Bool, reason: String) { (true, false, "") }
    func beginTransportRecoveryCycleIfNeeded() -> Int64 { currentTransportRecoveryEpoch }
    func shouldDeferReconnectForAppInactivity(_ task: BleReconnectTask) -> Bool { inactiveWithoutObject }
    func deferReconnectTaskForAppInactivity(_ task: BleReconnectTask, context: String) {
        var current = reconnectTasks[reconnectKey(uuid: task.uuid)]!
        current.timer?.invalidate(); current.timer = nil
        current.deferredByAppInactivity = true
        reconnectTasks[reconnectKey(uuid: task.uuid)] = current
    }
    func findActiveConnectRequest(uuid: String, name: String) -> Int? { nil }
    func beginDirectReconnectAttempt(task: BleReconnectTask, config: BleConfig) {
        physicalStarts.append(task.uuid)
        directReconnectStarts.append(task)
    }
    func loggerD(msg: String) {}
}
