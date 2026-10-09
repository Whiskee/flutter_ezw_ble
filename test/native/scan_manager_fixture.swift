import CoreBluetooth
import Foundation

// Manager/GATT boundaries are spies, not a second scan or identity resolver.
// These fixtures do not execute the real CoreBluetooth daemon or Gate admission.
struct BleConfig {
    let name: String
    let scan: BleScan
    let autoReconnect: Bool
    let connectTimeout: Double = 10_000
}

enum BleConnectSource: String {
    case autoReconnect, manualReconnect, foreground
}

struct BleReconnectTarget {
    let belongConfig: String
    let uuid: String
    let name: String
    let expectedMacSuffix: String
}

struct BleReconnectTask {
    let target: BleReconnectTarget
    let sessionGeneration: Int64
}

struct BleEasyConnect {
    let uuid: String
    let name: String
    let afterUpgrade: Bool
    let time: Double?
    let bleConfig: BleConfig?
}

struct BleConnectedDevice {
    let belongConfig: BleConfig
    let peripheral: CBPeripheral
}

enum BleConnectState {
    case noDeviceFound, noBleConfigFound, bleError, connecting
}

final class ScanEventSpy {
    var events: [String] = []
    func emit(_ json: String) { events.append(json) }
}

enum BleEC {
    static let scanResult = ScanEventSpy()
}

extension CBPeripheral {
    func toBleDevice(belongConfig: String, sn: String, rssi: Int, mac: String, advertisedName: String) -> BleDevice {
        BleDevice(belongConfig: belongConfig, name: advertisedName, uuid: identifier.uuidString, sn: sn, mac: mac, rssi: rssi)
    }
}

final class BleManager {
    let centralManager = CBCentralManager()
    var currentTransportRecoveryEpoch: Int64 = 4
    var pendingReconnectIdentities: [String: BlePendingReconnectIdentity] = [:]
    var scanResultTemp: [(BleDevice, CBPeripheral)] = []
    var startConnectInfos: [BleEasyConnect] = []
    var connectedDevices: [BleConnectedDevice] = []
    var bleConfigs: [BleConfig] = []
    var scanPureModel = false
    var tasks: [String: BleReconnectTask] = [:]
    var armCalls = 0
    var activateCalls = 0
    var physicalConnectCalls = 0
    var peerPairingCalls = 0

    func loggerD(msg: String) {}
    func loggerE(msg: String) {}
    func armReconnectTarget(_ target: BleReconnectTarget, source: BleConnectSource, sessionGeneration: Int64) -> BleReconnectTask? {
        armCalls += 1
        let task = BleReconnectTask(target: target, sessionGeneration: sessionGeneration)
        tasks[target.uuid] = task
        return task
    }
    func activateArmedReconnectTask(_ task: BleReconnectTask, source: BleConnectSource) {
        activateCalls += 1
    }
    func resumePeerPairingRecoveryIfMatched(peripheral: CBPeripheral, advertisedName: String, belongConfig: String, advertisedMac: String, rssi: Int) -> Bool {
        peerPairingCalls += 1
        return false
    }
    func stopScan() {}
    func cancelScanConnectTimeout(uuid: String, name: String) {}
    func handleConnectState(uuid: String, name: String, state: BleConnectState, tag: String = "") {}
    func updateActiveConnectRequestUuid(uuid: String, name: String) {}
    func currentConnectionAdmission(uuid: String) -> Int? { nil }
    func registerConnectionAttempt(peripheral: CBPeripheral, config: BleConfig, deviceName: String, afterUpgrade: Bool, source: BleConnectSource) -> Int? { 1 }
    func recordNativeTrace(uuid: String, stage: String, result: String) {}
    func connectPeripheralAfterCancellationBarrier(_ peripheral: CBPeripheral, autoReconnect: Bool) { physicalConnectCalls += 1 }
    func isAutoReconnectAttempt(uuid: String, name: String) -> Bool { false }
}
