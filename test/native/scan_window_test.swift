import Foundation

// Only the platform boundaries are spies. The Dart harness inserts the actual
// BleManager methods below so these assertions exercise production scan policy.

let CBCentralManagerScanOptionAllowDuplicatesKey = "allowDuplicates"

struct CBUUID: Equatable, CustomStringConvertible {
    let uuidString: String
    init(string: String) { self.uuidString = string.uppercased() }
    var description: String { uuidString }
}

enum UIApplicationState { case active, background }

final class UIApplication {
    static let shared = UIApplication()
    var applicationState: UIApplicationState = .active
}

enum FakeCentralState: Int {
    case unknown = 0
    case poweredOn = 5
    var label: String { self == .poweredOn ? "poweredOn" : "unknown" }
}

final class FakeCentralManager {
    var isScanning = false
    var state: FakeCentralState = .poweredOn
    var failNextScan = false
    var scanCalls: [[String]?] = []
    var stopCount = 0

    func scanForPeripherals(withServices services: [CBUUID]?, options: [String: Bool]) {
        scanCalls.append(services?.map(\.uuidString))
        isScanning = !failNextScan
        failNextScan = false
    }

    func stopScan() {
        stopCount += 1
        isScanning = false
    }
}

struct FakeScan { let nameFilters: [String] = []; let matchCount = 1 }
struct FakeConfig { let name = "ring"; let scan = FakeScan() }

extension Array { var isNotEmpty: Bool { !isEmpty } }

final class BleManager {
    var centralManager = FakeCentralManager()
    var bleConfigs = [FakeConfig()]
    var currentBleState = 5
    var configured = true
    var externalScanActive = false
    var externalScanPureModel = false
    var externalScanServiceUuids: [String] = []
    var externalScanIncludeUnfilteredScan = true
    var externalScanIncludeNormalResults = false
    var externalScanIncludeUnfilteredPureResults = true
    var internalScanActive = false
    var peerPairingRecoveryScanOwnerKeys: Set<String> = []
    var startConnectInfos: [String] = []
    var scanPureModel = false
    var scanPureModelIncludesNormalResults = false
    var scanPureModelIncludesUnfilteredResults = true
    var scanPureServiceUuidHints: Set<String> = []
    var scanResultTemp: [String] = []
    var pureScanResultTempUuids: Set<String> = []
    var activeScanSignature: String?
    var activeScanGeneration: Int64 = 0
    var scanGenerationSeed: Int64 = 0
    var lastLoggedScanConfigSignature: String?
    var logs: [String] = []

    func checkBleConfigIsConfigured() -> Bool { configured }
    func checkIsFunctionCanBeCalled() -> Bool { true }
    func loggerD(msg: String) { logs.append("D:" + msg) }
    func loggerE(msg: String) { logs.append("E:" + msg) }

    // PRODUCTION_METHODS_PLACEHOLDER
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        print("FAIL: \(message)")
        exit(1)
    }
}

func lastServices(_ manager: BleManager) -> [String]? {
    manager.centralManager.scanCalls.last ?? nil
}

func bool(_ result: [String: Any], _ key: String) -> Bool { result[key] as? Bool ?? false }
func int64(_ result: [String: Any], _ key: String) -> Int64 { result[key] as? Int64 ?? -1 }
func text(_ result: [String: Any], _ key: String) -> String { result[key] as? String ?? "" }

func assertStart(_ result: [String: Any], _ reason: String = "started") {
    expect(bool(result, "started"), "expected started result, got \(result)")
    expect(text(result, "reason") == reason, "expected reason \(reason), got \(result)")
}

func assertStopped(_ result: [String: Any], _ reason: String = "stopped") {
    expect(!bool(result, "started"), "expected stopped result, got \(result)")
    expect(text(result, "reason") == reason, "expected reason \(reason), got \(result)")
}

func testOrdinaryDefaultsNil() {
    let manager = BleManager()
    assertStart(manager.startScan())
    expect(lastServices(manager) == nil, "ordinary default scan should use nil services")
    expect(manager.scanPureModel == false, "ordinary default must not enable pure mode")
    expect(manager.scanPureServiceUuidHints.isEmpty, "ordinary default must not keep FE59 hints")
}

func testFe59OnlyForegroundAndBackground() {
    let manager = BleManager()
    UIApplication.shared.applicationState = .active
    assertStart(manager.startExternalScan(pureModel: true, iosServiceUuids: ["FE59"], includeUnfilteredScan: false, includeUnfilteredPureScanResults: false))
    expect(lastServices(manager) == ["FE59"], "DFU-only foreground should physically filter FE59")
    expect(manager.scanPureServiceUuidHints == ["FE59"], "DFU raw hints should keep FE59")
    UIApplication.shared.applicationState = .background
    assertStart(manager.reconcileScanWindow(reason: "background"), "alreadyRunning")
    expect(lastServices(manager) == ["FE59"], "DFU-only background should physically filter FE59")
}

func testMixedForegroundNilBackgroundFe59AndReleaseRestoresOrdinary() {
    let manager = BleManager()
    UIApplication.shared.applicationState = .active
    assertStart(manager.startExternalScan(pureModel: true, iosServiceUuids: ["FE59"], includeUnfilteredScan: false, includeUnfilteredPureScanResults: false))
    manager.startConnectInfos = ["ordinary"]
    assertStart(manager.reconcileScanWindow(reason: "pending"))
    expect(lastServices(manager) == nil, "mixed foreground should use nil physical scan for ordinary discovery")
    expect(manager.scanPureServiceUuidHints == ["FE59"], "mixed foreground must retain FE59 raw hints")
    expect(manager.scanPureModelIncludesNormalResults, "mixed foreground must keep normal scan parsing")
    UIApplication.shared.applicationState = .background
    assertStart(manager.reconcileScanWindow(reason: "background"))
    expect(lastServices(manager) == ["FE59"], "mixed background should filter FE59")
    UIApplication.shared.applicationState = .active
    assertStart(manager.reconcileScanWindow(reason: "active"))
    expect(lastServices(manager) == nil, "mixed foreground return should restore nil scan")
    manager.stopExternalScan()
    expect(manager.centralManager.isScanning, "ordinary pending owner should survive external DFU release")
    expect(lastServices(manager) == nil, "external release should leave ordinary nil scan")
    expect(manager.scanPureModel == false, "external release should clear pure mode when ordinary remains")
}

// Raw scope changes must reconfigure even while physical services stay nil.
func testModeProbeRawScopeIndependentOfOrdinaryDemand() {
    let manager = BleManager()
    UIApplication.shared.applicationState = .active
    assertStart(manager.startExternalScan(pureModel: true, iosServiceUuids: ["FE59"], includeUnfilteredScan: true, includeNormalScanResults: true, includeUnfilteredPureScanResults: false))
    expect(lastServices(manager) == nil && !manager.scanPureModelIncludesUnfilteredResults, "normal owner must not widen DFU-only raw results")
    let dfuGeneration = manager.activeScanGeneration
    assertStart(manager.startExternalScan(pureModel: true, iosServiceUuids: ["FE59"], includeUnfilteredScan: true, includeNormalScanResults: true, includeUnfilteredPureScanResults: true))
    expect(manager.activeScanGeneration > dfuGeneration && manager.scanPureModelIncludesUnfilteredResults, "dual-mode owner must reconfigure raw routing without changing physical scope")
    expect(manager.scanPureModelIncludesNormalResults && lastServices(manager) == nil, "dual-mode owner must retain validated ordinary parsing")
    UIApplication.shared.applicationState = .background
    assertStart(manager.reconcileScanWindow(reason: "background"))
    expect(lastServices(manager) == ["FE59"], "raw application demand must not erase background DFU service filter")
}

func testInternalDemandRegistersDespiteExistingDfuPhysicalScan() {
    let manager = BleManager()
    UIApplication.shared.applicationState = .background
    assertStart(manager.startExternalScan(pureModel: true, iosServiceUuids: ["FE59"], includeUnfilteredScan: false, includeUnfilteredPureScanResults: false))
    expect(lastServices(manager) == ["FE59"], "precondition: DFU physical filter")
    UIApplication.shared.applicationState = .active
    assertStart(manager.startPairingRecoveryScanOwner(key: "peer-a"))
    expect(lastServices(manager) == nil, "pairing owner should re-arbitrate foreground scan to nil")
    expect(manager.scanPureServiceUuidHints == ["FE59"], "pairing owner must not erase FE59 raw hints")
    expect(manager.scanPureModelIncludesNormalResults, "pairing owner should keep ordinary parsing while DFU pure owner exists")
}

func testTwoPeerOwnersReleaseEitherOrderPreserveDfu() {
    for order in [["peer-a", "peer-b"], ["peer-b", "peer-a"]] {
        let manager = BleManager()
        UIApplication.shared.applicationState = .active
        assertStart(manager.startExternalScan(pureModel: true, iosServiceUuids: ["FE59"], includeUnfilteredScan: false, includeUnfilteredPureScanResults: false))
        assertStart(manager.startPairingRecoveryScanOwner(key: "peer-a"))
        assertStart(manager.startPairingRecoveryScanOwner(key: "peer-b"), "alreadyRunning")
        manager.stopPairingRecoveryScanOwner(key: order[0])
        expect(manager.centralManager.isScanning, "first peer release should preserve remaining owner")
        expect(lastServices(manager) == nil, "remaining peer owner should keep foreground nil scan")
        manager.stopPairingRecoveryScanOwner(key: order[1])
        expect(manager.centralManager.isScanning, "final peer release should preserve external DFU owner")
        expect(lastServices(manager) == ["FE59"], "final peer release should restore DFU FE59 filter")
    }
}

func testRejectedExternalStartCannotRevive() {
    for mode in ["bleUnavailable", "notConfigured", "systemCallFailed"] {
        let manager = BleManager()
        UIApplication.shared.applicationState = .background
        if mode == "bleUnavailable" { manager.currentBleState = 0 }
        if mode == "notConfigured" { manager.configured = false }
        if mode == "systemCallFailed" { manager.centralManager.failNextScan = true }
        let result = manager.startExternalScan(pureModel: true, iosServiceUuids: ["FE59"], includeUnfilteredScan: false)
        expect(!bool(result, "started"), "\(mode) should reject external start")
        expect(text(result, "reason") == mode, "expected \(mode), got \(result)")
        manager.currentBleState = 5
        manager.configured = true
        assertStopped(manager.reconcileScanWindow(reason: "laterLifecycle"), "stopped")
        expect(!manager.centralManager.isScanning, "\(mode) must not revive external scan on later lifecycle")
        expect(manager.centralManager.scanCalls.isEmpty || mode == "systemCallFailed", "\(mode) should not add later scan calls")
    }
}

func testIdempotentGenerationAndUuidNormalization() {
    let manager = BleManager()
    UIApplication.shared.applicationState = .background
    let first = manager.startExternalScan(
        pureModel: true,
        iosServiceUuids: ["", "fe59", "FE59", "180F", "bad-value"],
        includeUnfilteredScan: false
    )
    assertStart(first)
    expect(lastServices(manager) == ["FE59", "180F"], "UUID normalization should trim invalid and de-dupe")
    expect(manager.scanPureServiceUuidHints == ["FE59", "180F"], "pure hints should use normalized UUID set")
    let generation = int64(first, "generation")
    let second = manager.reconcileScanWindow(reason: "same")
    assertStart(second, "alreadyRunning")
    expect(int64(second, "generation") == generation, "idempotent same signature should keep generation")
    expect(manager.centralManager.scanCalls.count == 1, "idempotent same signature should not rescan")
}

UIApplication.shared.applicationState = .active
testOrdinaryDefaultsNil()
testFe59OnlyForegroundAndBackground()
testMixedForegroundNilBackgroundFe59AndReleaseRestoresOrdinary()
testModeProbeRawScopeIndependentOfOrdinaryDemand()
testInternalDemandRegistersDespiteExistingDfuPhysicalScan()
testTwoPeerOwnersReleaseEitherOrderPreserveDfu()
testRejectedExternalStartCannotRevive()
testIdempotentGenerationAndUuidNormalization()
print("PASS: production BleManager scan-window policy preserves FE59 DFU, ordinary nil scans, keyed peer owners, failed-start cleanup, generation idempotency and UUID normalization")
