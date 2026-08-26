//
//  BleManager.swift
//  flutter_ezw_ble
//
//  Created by Whiskee on 2025/1/3.
//

import Flutter
import CoreBluetooth
import Foundation
import flutter_ezw_utils
import UIKit

class BleManager: NSObject {

    //  使用静态常量来保证实例的唯一性
    static let shared = BleManager()
    
    //  =========== Constants
    //  - 蓝牙管理工具
    var centralManager: CBCentralManager!
    //  - 缓存已连接的设备
    lazy var connectedDevices: [BleConnectedDevice] = []
    
    //  =========== Variables
    //  - 当前蓝牙基础配置，必须实现
    lazy var bleConfigs: [BleConfig] = []
    //  - 区分“配置尚未下发”与“initConfigs 明确传入空配置”。
    var hasInitializedBleConfigs = false
    //  - 搜索：纯净搜索模式，只返回单个设备，且只有名称，uuid
    lazy var scanPureModel: Bool = false
    //  - 搜素：获取结果临时缓存(DeviceInfo, 蓝牙对象)
    lazy var scanResultTemp: [(BleDevice, CBPeripheral)] = []
    //  - 当前连接请求缓存，用于原生回调反查 bleConfig
    lazy var activeConnectRequests: [BleEasyConnect] = []
    //  - 发起连接信息(所属蓝牙配置名称，UUID，设备名称, 发起时间， 是否是升级状态)
    //  -- 用于设备没能立马被发现时开启搜索，并从搜索中获取直接发起连接
    lazy var startConnectInfos: [BleEasyConnect] = []
    //  - 连接超时定时器集合(UUID, Name, 倒计时定时器)
    private lazy var connectingTimeoutTimers: [(String, String, Timer)] = []
    //  - 扫描后再连接阶段的超时定时器集合(UUID, Name, 倒计时定时器)
    private lazy var scanConnectTimeoutTimers: [(String, String, Timer)] = []
    //  - Native OTA marker 与写入门禁的唯一状态源；非可选集合保证首次 enter 必定落盘。
    let upgradeStateRegistry = BleUpgradeStateRegistry()
    //  - 预连接设备集合（使用uuid作为key）
    lazy var preConnectedDevices: Set<String> = []
    //  - OTA WriteWithoutResponse 写队列(key: peripheral.identifier.uuidString)
    //  - 仅在 sendCmdNoWait + psType==1 路径上使用, 详见 docs/IOS_OTA_NOWAIT_SPEC.md §4.2
    private lazy var otaWriteQueues: [String: OtaWriteQueue] = [:]
    //  - 原生自动回连任务，只有业务 connected 后才会加入
    lazy var reconnectTasks: [String: BleReconnectTask] = [:]
    //  - CBCentralManager 使用主队列；同步 retrieve 只允许在 App active 窗口执行，
    //    避免退出宽限期主线程卡在 CoreBluetooth XPC 同步查询并触发 0x8BADF00D。
    var allowsSynchronousCoreBluetoothLookup = false
    /// Code 14 新鲜广播窗口按 exact session 持有扫描 lease；只有本任务启动的扫描
    /// 才能由它停止，旧窗口回调也不得移除新 owner 的 timer。
    var pairingRecoveryScanTimers: [String: (timer: Timer, ownsScan: Bool, sessionGeneration: Int64)] = [:]
    //  - 已因 Code 14 结束的稳定 config+name 身份。它不保留 GATT/owner，也不直接
    //    触发 720；仅让下一次手动连接绕过旧 peripheral，等待一次新鲜广播。
    var stoppedPeerPairingRecoveryKeys: Set<String> = []
    //  - iOS 空 UUID 目标先以 config+完整名称持有 owner，扫描只负责补齐 peripheral UUID。
    lazy var pendingReconnectIdentities: [String: BlePendingReconnectIdentity] = [:]
    //  - 每个 canonical target 最多保留常数个 UUID 别名，兼顾旧 UI hard cancel 与长期内存有界。
    let reconnectIdentityAliases = BleReconnectIdentityAliasIndex()
    //  - 所有 CoreBluetooth 物理连接共用的串行 GATT readiness Gate。
    let connectionAdmissionGate = BleConnectionAdmissionGate()
    //  - generation 只用一个全局饱和序列；历史 UUID 不得在线性 map 中永久残留。
    var connectionAttemptGenerationSequence: Int64 = 0
    var connectionSessionSequence: Int64 = 0
    var currentConnectionAdmissions: [String: BleConnectionAdmission] = [:]
    var peripheralConnectionSessions: [Int64: BlePeripheralConnectionSession] = [:]
    //  - CoreBluetooth cancel 回调不带 attempt id；token gate + 有界 watchdog 同时保证
    //    旧回调不能终止新 generation，且系统漏回调时 deferred connect 也不会永久等待。
    let peripheralCancellationBarrierGate = BlePeripheralCancellationBarrierGate()
    var peripheralCancellationWatchdogs: [String: (token: Int64, workItem: DispatchWorkItem)] = [:]
    // OTA reboot 主动断开已先发出同代终态；随后 CoreBluetooth 的确认回调不能再次
    // schedule reconnect，否则会和 App 的 afterUpgrade activation 竞争。
    private var otaRebootDisconnectSuppressions: Set<String> = []
    private var otaRebootDisconnectWatchdogs: [String: DispatchWorkItem] = [:]
    //  - central.connect 到 didConnect 之间没有 GATT timeout；exact generation/session
    //    watchdog 对自动回连只做观测，普通前台 attempt 才允许有界回收。
    let pendingPhysicalConnectWatchdogs = BlePendingPhysicalConnectWatchdogRegistry()
    //  - 辅助扫描命中只为 exact 长期 pending owner 提供一次受控恢复机会；
    //    与 60 秒观测 watchdog 分离，避免重复提示把恢复窗口向后顺延。
    let visiblePendingRecoveryWatchdogs = BleVisiblePendingRecoveryWatchdogRegistry()
    let deferredPeripheralReconnectRegistry = BleDeferredPeripheralReconnectRegistry()
    var pendingConnectionAdmissionTeardowns: [String: BlePendingConnectionAdmissionTeardown] = [:]
    // Business-auth leases are exact session/attempt tokens. A new prepare for
    // the same endpoint replaces the old one, while stale abort/cleanup paths
    // must not remove a newer token.
    let businessConnectionLeases = BleBusinessConnectionLeaseRegistry()
    // Native Trace 默认关闭。开启后仅记录下一次真实物理 attempt，不改变连接/回连行为。
    var connectionTraceEnabled = false
    var nativeConnectionTraces: [String: BleNativeConnectionTraceBuffer] = [:]
    var nativeTraceRssiTimers: [String: Timer] = [:]
    var nativeTraceRssiInFlightAttemptIds: [String: String] = [:]
    /// Trace 专用的前一连接状态，仅用于区分 Bond 恢复超时/取消与普通连接终态。
    var nativeTraceLastConnectStates: [String: BleConnectState] = [:]
    let reconnectStore = BleReconnectStore()
    //  - 最近一次已输出的扫描配置签名，用于避免每次 startScan 都重复刷配置详情。
    private var lastLoggedScanConfigSignature: String?
    //  =========== Get/Set
    //  - 当前蓝牙状态
    var currentBleState: Int {
        get {
            resumeReconnectTasksIfBluetoothOn(reason: "bleState-query")
            return centralManager.state.rawValue
        }
    }
    
    /**
     * 私有化初始化 BLE 管理器，确保全局只存在一个 CoreBluetooth central manager。
     *
     * 初始化只创建普通 CBCentralManager。后台 BLE 仍由宿主的
     * `bluetooth-central` 能力支持普通 pending connect。
     */
    private override init() {
        super.init()
        self.centralManager = CBCentralManager(
            delegate: self,
            queue: nil,
            options: nil
        )
        // 插件可能在 didBecomeActive 之后才初始化；此时允许继承当前 active 事实。
        // 后续所有切换仍只由 UIApplication 生命周期通知更新。
        allowsSynchronousCoreBluetoothLookup = UIApplication.shared.applicationState == .active
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppWillResignActive),
            name: UIApplication.willResignActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppWillTerminate),
            name: UIApplication.willTerminateNotification,
            object: nil
        )
    }

}

// MARK: - Public Methods
extension BleManager {

    /**
     *  设置蓝牙配置。
     *
     *  Flutter 会在启动、热重启、普通冷启动恢复后调用该方法。这里必须只做
     *  同步赋值，不能把恢复连接/GATT 初始化放在 MethodChannel 调用栈里执行，否则
     *  Dart 的 `await initConfigs` 会阻塞首帧，表现为 App 停在启动阶段并触发 hang 日志。
     */
    func initConfigs(configs: [BleConfig]) {
        let revokedConfigNames = BleReconnectConfigDiff.revokedConfigNames(
            previous: bleConfigs,
            current: configs
        )
        if !revokedConfigNames.isEmpty {
            revokeReconnectConfigs(revokedConfigNames)
        }
        self.bleConfigs = configs
        self.hasInitializedBleConfigs = true
        // MethodChannel 调用必须尽快返回 Flutter，auto reconnect 补偿放到下一轮主队列，
        // 避免在 initConfigs 的 await 边界内同步启动 GATT。
        DispatchQueue.main.async { [weak self] in
            // 1、蓝牙已恢复但任务被 poweredOff 暂停时，在配置就绪后补偿恢复。
            self?.resumeReconnectTasksIfBluetoothOn(reason: "initConfigs")
        }
    }

    /**
     * 配置删除或 autoReconnect=true→false 是 native owner 授权撤销。
     *
     * 先收集并原子失效 task/persisted owner/admission，再 cancel CoreBluetooth peripheral；
     * 因而 active、Gate waiter、pre-physical 的任何迟到 callback 都无法复活旧连接。
     */
    private func revokeReconnectConfigs(_ configNames: Set<String>) {
        let revokedTasks = reconnectTasks.values.filter { configNames.contains($0.belongConfig) }
        let revokedTargets = reconnectStore.removeTargets(configNames: configNames)
        let revokedDevices = connectedDevices.filter { configNames.contains($0.belongConfig.name) }
        let revokedSessions = peripheralConnectionSessions.values.filter {
            configNames.contains($0.config.name)
        }
        let requestEndpoints = (activeConnectRequests + startConnectInfos).compactMap { request in
            configNames.contains(request.belongConfig) ? request.uuid : nil
        }
        let endpointIds = Set(
            (revokedTasks.map(\.uuid) +
                revokedTargets.map(\.uuid) +
                revokedDevices.map { $0.peripheral.identifier.uuidString } +
                revokedSessions.map { $0.admission.endpointId } +
                requestEndpoints)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
        let endpointKeys = Set(endpointIds.map(reconnectKey))

        // 1. 所有长期 owner 与未来 timer 先失效，防止 teardown 期间再次建立 pending connect。
        reconnectTasks = reconnectTasks.filter { !configNames.contains($0.value.belongConfig) }
        pendingReconnectIdentities = pendingReconnectIdentities.filter {
            !configNames.contains($0.value.belongConfig)
        }
        let normalizedConfigPrefixes = configNames.map {
            "\($0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())|"
        }
        stoppedPeerPairingRecoveryKeys = Set(
            stoppedPeerPairingRecoveryKeys.filter { key in
                !normalizedConfigPrefixes.contains(where: key.hasPrefix)
            }
        )
        revokedTasks.forEach { task in
            task.timer?.invalidate()
            reconnectIdentityAliases.removeAliases(canonicalUuid: task.uuid)
        }
        revokedTargets.forEach {
            reconnectIdentityAliases.removeAliases(canonicalUuid: $0.uuid)
        }

        // 2. current map/session 与 Gate 批量失效；只允许仍获授权的 next owner 被 grant。
        let revokedAdmissionIds = Set(revokedSessions.map { $0.admission.sessionId })
        currentConnectionAdmissions = currentConnectionAdmissions.filter {
            !endpointKeys.contains($0.key)
        }
        peripheralConnectionSessions = peripheralConnectionSessions.filter {
            !revokedAdmissionIds.contains($0.key)
        }
        let next = connectionAdmissionGate.cancelEndpoints(endpointIds)

        // 3. 清理扫描、请求、倒计时和业务缓存，不给任何延迟闭包留下授权上下文。
        activeConnectRequests.removeAll {
            configNames.contains($0.belongConfig) || endpointKeys.contains(reconnectKey(uuid: $0.uuid))
        }
        startConnectInfos.removeAll {
            configNames.contains($0.belongConfig) || endpointKeys.contains(reconnectKey(uuid: $0.uuid))
        }
        connectingTimeoutTimers = connectingTimeoutTimers.filter { uuid, _, timer in
            let keep = !endpointKeys.contains(reconnectKey(uuid: uuid))
            if !keep { timer.invalidate() }
            return keep
        }
        scanConnectTimeoutTimers = scanConnectTimeoutTimers.filter { uuid, _, timer in
            let keep = !endpointKeys.contains(reconnectKey(uuid: uuid))
            if !keep { timer.invalidate() }
            return keep
        }
        preConnectedDevices = Set(preConnectedDevices.filter {
            !endpointKeys.contains(reconnectKey(uuid: $0))
        })
        upgradeStateRegistry.removeAll {
            endpointKeys.contains(reconnectKey(uuid: $0))
        }
        var shouldStopOwnedPairingRecoveryScan = false
        endpointKeys.forEach { key in
            otaWriteQueues.removeValue(forKey: key)?.cancelAll(reason: "initConfigs revoked")
            pendingConnectionAdmissionTeardowns.removeValue(forKey: key)
            peripheralCancellationWatchdogs.removeValue(forKey: key)?.workItem.cancel()
            if let scanEntry = pairingRecoveryScanTimers.removeValue(forKey: key) {
                scanEntry.timer.invalidate()
                shouldStopOwnedPairingRecoveryScan = shouldStopOwnedPairingRecoveryScan || scanEntry.ownsScan
            }
        }
        if shouldStopOwnedPairingRecoveryScan {
            stopScan()
        }
        pendingPhysicalConnectWatchdogs.remove(endpointIds: endpointIds).forEach { $0.cancel() }
        visiblePendingRecoveryWatchdogs.remove(endpointIds: endpointIds).forEach { $0.cancel() }
        deferredPeripheralReconnectRegistry.remove(endpointIds: endpointIds)
        peripheralCancellationBarrierGate.discard(endpointIds: endpointIds)

        // 4. map 全部失效后再触发 CoreBluetooth cancel；后续 callback 只能走 stale 路径。
        var cancelledPeripherals = Set<ObjectIdentifier>()
        (revokedDevices.map(\.peripheral) + revokedSessions.map(\.peripheral)).forEach { peripheral in
            guard cancelledPeripherals.insert(ObjectIdentifier(peripheral)).inserted else { return }
            centralManager.cancelPeripheralConnection(peripheral)
        }
        connectedDevices.removeAll { configNames.contains($0.belongConfig.name) }
        if let next {
            startGrantedGattPipeline(next)
        }
        loggerD(msg: "initConfigs: revoked reconnect configs=\(configNames.sorted()), endpoints=\(endpointIds.count)")
    }

    /**
     *  读取并清空原生自动回连期间的持久化事件。
     */
    func drainAutoReconnectEvents() -> [[String: Any]] {
        reconnectStore.drainEvents()
    }
    
    /**
     * 开始扫描设备
     *
     * [param] pureModel 是否开启纯净模式（只返回设备名称，UUID）
     */
    func startScan(pureModel: Bool = false) {
        guard checkIsFunctionCanBeCalled() else {
            return
        }
        //  是否开启纯净模式
        scanPureModel = pureModel
        //  开始搜索
        stopScan(isStartScan: true)
        //  清空缓存
        scanResultTemp.removeAll()
        centralManager.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        // 生成本次扫描所使用的配置快照。搜索无结果时，首先要确认 native 真的拿到了
        // Dart 缓存配置；但同一配置重复开始扫描时只打印一次，避免日志噪声盖过扫描决策日志。
        let configSummary = bleConfigs.map { config in
            "\(config.name){filters=\(config.scan.nameFilters),matchCount=\(config.scan.matchCount)}"
        }.joined(separator: ";")
        let configSignature = "\(pureModel)|\(configSummary)"
        if lastLoggedScanConfigSignature != configSignature {
            lastLoggedScanConfigSignature = configSignature
            loggerD(msg: "startScan/config: pure=\(pureModel), state=\(centralManager.state.label), configs=[\(configSummary)]")
        }
        loggerD(msg: "startScan")
    }
    
    /**
     * 停止扫描设备
     */
    func stopScan(isStartScan: Bool = false) {
        guard checkIsFunctionCanBeCalled()else {
            return
        }
        guard centralManager.isScanning else {
            loggerD(msg: "stopScan: is not scanning")
            return
        }
        guard startConnectInfos.isEmpty else {
            loggerD(msg: "stopScan: connecting with scanning, not handle stop")
            return
        }
        //  关闭纯净模式
        scanPureModel = false
        centralManager.stopScan()
        loggerD(msg: "\(isStartScan ? "checking if scan is already running, stopping it first if necessary" : "stop scan")")
    }

    /**
     *  目标外设是否已被系统/CoreBluetooth 持有连接。
     *
     *  G2 右腿申请 ANCS 后可能停止广播，scanForPeripherals 不会再发现它；
     *  Dart 层 scan-first 流程可用该方法把“系统已连接”也视为一种发现结果。
     */
    func isSystemConnectedPeripheral(belongConfig: String, uuid: String, name: String) -> Bool {
        guard checkIsFunctionCanBeCalled(),
              let bleConfig = bleConfigs.first(where: { config in
                config.name == belongConfig
              }) else {
            loggerD(msg: "system-connected probe: \(uuid)-\(name), no config for \(belongConfig)")
            return false
        }
        let serviceUUIDs = bleConfig.privateServices.map { $0.serviceUUID }
        if findPeripheralFromConnected(
            uuid: uuid,
            name: name,
            serviceUUIDs: serviceUUIDs
        ) != nil {
            loggerD(msg: "system-connected probe: \(uuid)-\(name), hit retrieveConnectedPeripherals")
            return true
        }
        if !uuid.isEmpty,
           let cbUuid = UUID(uuidString: uuid),
           let peripheral = retrievePeripheralsWhenAppActive(
               withIdentifiers: [cbUuid],
               context: "system-connected probe"
           ).first,
           peripheral.state == .connected {
            loggerD(msg: "system-connected probe: \(uuid)-\(name), hit retrievePeripherals")
            return true
        }
        loggerD(msg: "system-connected probe: \(uuid)-\(name), miss")
        return false
    }
    
    /**
     *  设置设备预连接
     */
    func setPreConnected(uuid: String) {
        guard !uuid.isEmpty else {
            return
        }
        preConnectedDevices.insert(uuid)
        loggerD(msg: "Set \(uuid) pre-connected")
    }
    /**
     *  设置连接成功
     */
    @discardableResult
    func setConnected(
        uuid: String,
        expectedAttempt: BleBusinessConnectionAttempt? = nil
    ) -> BleBusinessConnectionStatus {
        guard checkIsFunctionCanBeCalled() else {
            return .invalidArguments
        }
        let exactAdmission: BleConnectionAdmission?
        if let expectedAttempt = expectedAttempt {
            guard let admission = currentConnectionAdmission(uuid: uuid) else {
                return .missingAdmission
            }
            guard admission.sessionGeneration == expectedAttempt.sessionGeneration,
                  admission.generation == expectedAttempt.attemptGeneration else {
                return .attemptMismatch
            }
            // Exact commit must publish the same admission token that Dart
            // prepared; legacy deviceConnected keeps its historical best-effort
            // path by leaving expectedAttempt nil.
            exactAdmission = admission
        } else {
            exactAdmission = currentConnectionAdmission(uuid: uuid)
        }
        if !preConnectedDevices.contains(uuid) {
            loggerE(msg: "setConnected: \(uuid) connected failed, not pre-connected")
            return .missingPrepare
        }
        loggerD(msg: "setConnected: \(uuid) connected")
        //  移除预连接状态
        preConnectedDevices.remove(uuid)
        businessConnectionLeases.remove(endpointKey: reconnectKey(uuid: uuid))
        let connectedDevice = connectedDevices.first(where: { device in
            device.peripheral.identifier.uuidString == uuid
        })
        if let connectedDevice = connectedDevice {
            persistReconnectTarget(device: connectedDevice)
        }
        updateConnectedDevice(
            uuid: uuid,
            name: connectedDevice?.peripheral.name ?? "",
            isConnected: true,
            source: exactAdmission?.source,
            generation: exactAdmission?.sessionGeneration,
            attemptGeneration: exactAdmission?.generation
        )
        let committed = connectedDevices.first(where: { device in
            device.peripheral.identifier.uuidString == uuid
        })?.isConnected == true
        return committed ? .accepted : .deviceDisconnected
    }

    /**
     * Install a bounded business-auth lease for the exact GATT attempt that
     * emitted `connectFinish`. Legacy `devicePreConnected` remains available
     * for older integrations and non-G2 products.
     */
    func prepareBusinessConnection(
        _ attempt: BleBusinessConnectionAttempt
    ) -> BleBusinessConnectionStatus {
        let status = validateBusinessConnectionAttempt(attempt, requirePrepare: false)
        guard status == .accepted else {
            return status
        }
        businessConnectionLeases.prepare(
            endpointKey: reconnectKey(uuid: attempt.uuid),
            attempt: attempt,
            at: Date()
        )
        // Reuse the existing bounded auth-grace timeout so a prepared but never
        // committed attempt still times out through the established path.
        preConnectedDevices.insert(attempt.uuid)
        loggerD(msg: "businessConnection prepare accepted: uuid=\(attempt.uuid), sessionGeneration=\(attempt.sessionGeneration), attemptGeneration=\(attempt.attemptGeneration)")
        return .accepted
    }

    /**
     * Commit business connected only while the exact prepared attempt still
     * owns admission, the physical peripheral is connected, and every
     * private-service write/read/notify readiness bit is complete.
     */
    func commitBusinessConnection(
        _ attempt: BleBusinessConnectionAttempt
    ) -> BleBusinessConnectionStatus {
        let status = validateBusinessConnectionAttempt(attempt, requirePrepare: true)
        guard status == .accepted else {
            return status
        }
        return setConnected(uuid: attempt.uuid, expectedAttempt: attempt)
    }

    /**
     * Abort only the exact prepared token. Stale aborts are no-ops and must not
     * cancel CoreBluetooth pending connect, admission, or autoReconnect owner.
     */
    func abortBusinessConnection(_ attempt: BleBusinessConnectionAttempt) -> Bool {
        guard !attempt.uuid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        let key = reconnectKey(uuid: attempt.uuid)
        guard businessConnectionLeases.abort(endpointKey: key, attempt: attempt) else {
            return false
        }
        preConnectedDevices.remove(attempt.uuid)
        loggerD(msg: "businessConnection abort accepted: uuid=\(attempt.uuid), sessionGeneration=\(attempt.sessionGeneration), attemptGeneration=\(attempt.attemptGeneration)")
        return true
    }

    private func validateBusinessConnectionAttempt(
        _ attempt: BleBusinessConnectionAttempt,
        requirePrepare: Bool
    ) -> BleBusinessConnectionStatus {
        let key = reconnectKey(uuid: attempt.uuid)
        let admission = currentConnectionAdmission(uuid: attempt.uuid)
        let admissionAttempt = admission.map {
            BleBusinessConnectionAttempt(
                uuid: attempt.uuid,
                sessionGeneration: $0.sessionGeneration,
                attemptGeneration: $0.generation
            )
        }
        let session = admission.flatMap { peripheralConnectionSessions[$0.sessionId] }
        let device = connectedDevices.first(where: {
            $0.peripheral.identifier.uuidString == attempt.uuid
        })
        let isSamePeripheral = device != nil && session != nil &&
            device!.peripheral === session!.peripheral
        let readiness = device.map {
            BleGattReadiness.make(device: $0, config: $0.belongConfig)
        }
        return BleBusinessConnectionCommitPolicy.evaluate(
            attempt: attempt,
            admissionAttempt: admissionAttempt,
            preparedAttempt: businessConnectionLeases.attempt(for: key),
            requirePrepare: requirePrepare,
            hasSession: session != nil,
            hasDevice: device != nil,
            isSamePeripheral: isSamePeripheral,
            isPeripheralConnected: session?.peripheral.state == .connected,
            isGattReady: readiness?.isComplete == true
        )
    }
    
    /**
     *  断连 / 取消连接
     *
     *  - 既要支持"已连接设备的主动断连"，也要支持"connecting 中途用户点击取消"
     *  - Dart 层在 scan-then-connect 阶段可能携带空 uuid（temp-UUID 不会回传到 Dart），
     *    必须按 name 命中 in-flight 请求，否则会出现"点击取消无反应、要等扫描超时才结束"
     *  - 在 connect(easyConnect:) 三个阶段都需要可取消：
     *    a) startConnectInfos 中的 scan-then-connect 等待
     *    b) connectedDevices 中已发起 centralManager.connect 但未 connectFinish 的 peripheral
     *    c) 已完成连接流程的 peripheral
     */
    private func explicitCancellationMetadata(
        uuid: String,
        name: String
    ) -> BleExplicitCancellationMetadata? {
        // 1、先通过 alias/name 找到长期 owner；UUID 漂移后不能只查调用方传入的旧 UUID。
        let effectiveUuid = reconnectIdentityAliases.resolvedCanonical(uuid: uuid) ?? uuid
        let reconnectTask = reconnectTasks.values.first { task in
            isSameConnectTarget(
                storedUuid: task.uuid,
                storedName: task.name,
                uuid: effectiveUuid,
                name: name
            )
        }

        // 2、Gate admission 优先；否则使用 owner 保存的当前 Dart session。
        let admission = currentConnectionAdmission(uuid: effectiveUuid)
            ?? reconnectTask.flatMap { currentConnectionAdmission(uuid: $0.uuid) }
        let metadata = BleExplicitCancellationMetadataPolicy.resolve(
            currentAdmission: admission,
            reconnectTask: reconnectTask
        )
        loggerD(
            msg: "disconnect metadata snapshot: \(uuid)->\(effectiveUuid)-\(name), " +
                "source=\(metadata?.source.rawValue ?? "unknown"), " +
                "sessionGeneration=\(metadata?.sessionGeneration ?? 0), " +
                "attemptGeneration=\(metadata?.attemptGeneration ?? 0)"
        )
        return metadata
    }

    func disconnect(uuid: String, name: String) {
        disconnect(
            uuid: uuid,
            name: name,
            cancellationMetadata: explicitCancellationMetadata(
                uuid: uuid,
                name: name
            )
        )
    }

    /// 使用删除 owner 前冻结的身份执行显式取消。
    ///
    /// `cancelAutoReconnectTargets` 会先原子撤销整台逻辑设备的 Gate owner，因此
    /// 必须把 admission/task 元数据从批量入口传入，不能在 Gate 清理后重新查询。
    private func disconnect(
        uuid: String,
        name: String,
        cancellationMetadata: BleExplicitCancellationMetadata?
    ) {
        let effectiveUuid = reconnectIdentityAliases.resolvedCanonical(uuid: uuid) ?? uuid
        cancelReconnectTask(uuid: uuid, name: name)
        removePersistedReconnectTarget(uuid: uuid, name: name)
        //  1、移除预连接状态（uuid 为空则为 no-op，但保留以兼容旧路径）
        preConnectedDevices.remove(uuid)
        preConnectedDevices.remove(effectiveUuid)
        businessConnectionLeases.remove(endpointKey: reconnectKey(uuid: uuid))
        businessConnectionLeases.remove(endpointKey: reconnectKey(uuid: effectiveUuid))
        //  注意：不要在此处调用 removeActiveConnectRequest；需先按 uuid/name 命中 in-flight 或
        // 未完成连接的外设（见 findUnfinishedConnectDevice），否则 Dart 空 uuid + 名称取消无法关联到 CB 外设。

        //  2、命中"in-flight scan-then-connect"请求：connect(easyConnect:) 在本地未找到 peripheral 时
        //     生成 temp-UUID 并追加到 startConnectInfos；此时还没有 connectedDevices / CBPeripheral，
        //     必须主动撤回 scan 触发器并通知 Dart 层。仅在字段非空时比较，避免空 uuid 误命中其他请求。
        let inFlightInfos = startConnectInfos.filter { info in
            (!uuid.isEmpty && (info.uuid == uuid || info.uuid == effectiveUuid)) ||
                (!name.isEmpty && info.name == name)
        }
        if !inFlightInfos.isEmpty {
            //  - 2.1、移除 startConnectInfos，防止 didDiscover 找到设备后又触发连接
            for info in inFlightInfos {
                startConnectInfos.removeAll { $0.uuid == info.uuid || $0.name == info.name }
            }
            //  - 2.2、若已没有任何 scan-then-connect 请求挂起，停止扫描释放电量
            if startConnectInfos.isEmpty {
                stopScan()
            }
            //  - 2.3、emit .disconnectByUser：handleConnectState 内部会清定时器、移除 active 请求并通过
            //         sendConnectStateToFlutter 发回 Dart；Dart 层按 (uuid OR name) 匹配，
            //         name 命中即可正确落到对应 device，触发 UI 切换到已断开态
            for info in inFlightInfos {
                handleConnectState(
                    uuid: info.uuid,
                    name: info.name,
                    state: .disconnectByUser,
                    source: cancellationMetadata?.source,
                    generation: cancellationMetadata?.sessionGeneration,
                    attemptGeneration: cancellationMetadata?.attemptGeneration,
                    tag: "cancel in-flight by user"
                )
            }
            loggerD(msg: "disconnect: cancelled in-flight scan/connect for \(uuid.isEmpty ? "(no-uuid)" : uuid)-\(name), removed \(inFlightInfos.count) item(s)")
            return
        }

        //  2.5、命中 activeConnectRequest + 连接超时定时器，但尚未写入 connectedDevices 的 in-flight GATT connect。
        if let request = findActiveConnectRequest(uuid: effectiveUuid, name: name) {
            let hasTimer = connectingTimeoutTimers.contains { $0.0 == request.uuid || $0.1 == request.name }
            if hasTimer, findUnfinishedConnectDevice(uuid: effectiveUuid, name: name) == nil {
                if let match = scanResultTemp.first(where: { info in
                    (!request.uuid.isEmpty && !request.uuid.hasPrefix("temp-") && info.0.uuid == request.uuid) ||
                    (!request.name.isEmpty && (info.0.name == request.name || info.1.name == request.name))
                }) {
                    centralManager.cancelPeripheralConnection(match.1)
                }
                handleConnectState(
                    uuid: request.uuid,
                    name: request.name,
                    state: .disconnectByUser,
                    source: cancellationMetadata?.source,
                    generation: cancellationMetadata?.sessionGeneration,
                    attemptGeneration: cancellationMetadata?.attemptGeneration,
                    tag: "cancel active connect by user"
                )
                loggerD(msg: "disconnect: cancelled active connect for \(request.uuid)-\(request.name), by user")
                return
            }
        }

        //  3、命中"已加入 connectedDevices 但尚未 connectFinish"的 peripheral：
        //     例如从蓝牙设置页/已绑定缓存 retrievePeripherals 命中后已 centralManager.connect(...)，
        //     但 didConnect 回调尚未到达。此时 connectedDevices 存在条目但 isConnected=false。
        //     直接走 handleConnectState(.disconnectByUser)：内部会调用 cancelPeripheralConnection
        //     真正中断 in-progress 的 GATT 连接，避免连接挂起到系统超时
        if let inProgressDevice = findUnfinishedConnectDevice(uuid: effectiveUuid, name: name) {
            let p = inProgressDevice.peripheral
            let realUuid = p.identifier.uuidString
            let realName = p.name ?? name
            handleConnectState(
                uuid: realUuid,
                name: realName,
                state: .disconnectByUser,
                source: cancellationMetadata?.source,
                generation: cancellationMetadata?.sessionGeneration,
                attemptGeneration: cancellationMetadata?.attemptGeneration,
                tag: "cancel connecting by user"
            )
            loggerD(msg: "disconnect: cancelled connecting peripheral \(realUuid)-\(realName), by user")
            return
        }

        //  4、已建立连接的设备（isConnected == true）：按 uuid / 广播名匹配
        removeActiveConnectRequest(uuid: effectiveUuid, name: name)
        let connectedDevice = connectedDevices.first { device in
            device.peripheral.identifier.uuidString == effectiveUuid || device.peripheral.name == name
        }
        updateConnectedDevice(
            uuid: effectiveUuid,
            name: connectedDevice?.peripheral.name ?? name,
            isConnected: false,
            updateByUser: true,
            source: cancellationMetadata?.source,
            generation: cancellationMetadata?.sessionGeneration,
            attemptGeneration: cancellationMetadata?.attemptGeneration
        )
        loggerD(
            msg: "disconnect:\(uuid)->\(effectiveUuid)-\(name), disconnect by user, " +
                "source=\(cancellationMetadata?.source.rawValue ?? "unknown"), " +
                "sessionGeneration=\(cancellationMetadata?.sessionGeneration ?? 0), " +
                "attemptGeneration=\(cancellationMetadata?.attemptGeneration ?? 0)"
        )
    }

    /**
     * Atomically revoke all reconnect endpoints that belong to one logical device.
     *
     * The Gate is invalidated for the complete target set before any CoreBluetooth cancel is
     * submitted. This prevents the first cancelled G2 leg from granting the second stale leg
     * while a replacement device is waiting to become current.
     */
    func cancelAutoReconnectTargets(_ targets: [BleReconnectTarget], reason: String) {
        // 1. Resolve aliases and name-only owners before mutating reconnectTasks.
        let endpointIds = Set(targets.flatMap { target -> [String] in
            let taskUuids = reconnectTasks.values.filter { task in
                isSameConnectTarget(
                    storedUuid: task.uuid,
                    storedName: task.name,
                    uuid: target.uuid,
                    name: target.name
                )
            }.map(\.uuid)
            let canonical = reconnectIdentityAliases.resolvedCanonical(uuid: target.uuid)
            return taskUuids + [target.uuid, canonical ?? ""]
        }.filter { !$0.isEmpty })
        guard !targets.isEmpty else { return }

        // 2. Freeze every endpoint's accepted identity before Gate/task removal.
        let cancellationTargets = targets.map { target in
            (
                target,
                explicitCancellationMetadata(uuid: target.uuid, name: target.name)
            )
        }

        // 3. Remove every stale endpoint from the Gate as one operation and delay the next owner.
        let next = connectionAdmissionGate.cancelEndpoints(endpointIds)

        // 4. Existing disconnect owns task/store/request/peripheral cleanup and installs a
        // cancellation barrier before CoreBluetooth can deliver a late terminal callback.
        for (target, metadata) in cancellationTargets {
            disconnect(
                uuid: target.uuid,
                name: target.name,
                cancellationMetadata: metadata
            )
        }

        // 5. Only after all old targets have been revoked may a surviving owner enter GATT.
        if let next {
            startGrantedGattPipeline(next)
        }
        loggerD(msg: "cancel auto reconnect targets: endpoints=\(endpointIds), reason=\(reason)")
    }

    /**
     * OTA 成功后的固件 reboot 专用断开。
     *
     * 不能复用 [disconnect]：那条路径代表用户取消，会删除 reconnect task 与持久 owner。
     * 本方法带当前业务 session 的 source/generation 发出 .disconnectFromSys，使 Dart
     * 清理已失效的连接态；原生不在固件 reboot 期间抢跑建链，回连由 afterUpgrade 激活。
     */
    func disconnectForOtaReboot(uuid: String, name: String) {
        let effectiveUuid = reconnectIdentityAliases.resolvedCanonical(uuid: uuid) ?? uuid
        guard let device = connectedDevices.first(where: { device in
            isSameConnectTarget(
                storedUuid: device.peripheral.identifier.uuidString,
                storedName: device.peripheral.name ?? "",
                uuid: effectiveUuid,
                name: name
            )
        }) else {
            loggerE(msg: "ota reboot disconnect: \(uuid)-\(name), no connected device cache")
            return
        }
        let physicalUuid = device.peripheral.identifier.uuidString
        let physicalName = device.peripheral.name ?? name
        markOtaRebootDisconnectSuppression(uuid: physicalUuid)
        handleConnectState(
            uuid: physicalUuid,
            name: physicalName,
            state: .disconnectFromSys,
            suppressReconnectSchedule: true,
            tag: "OTA reboot teardown"
        )
        loggerD(msg: "ota reboot disconnect: \(physicalUuid)-\(physicalName), owner preserved")
    }

    /// 标记/消费 OTA 主动 cancel 的唯一 CoreBluetooth 确认回调，禁止跨越到新会话。
    private func markOtaRebootDisconnectSuppression(uuid: String) {
        let key = reconnectKey(uuid: uuid)
        otaRebootDisconnectWatchdogs[key]?.cancel()
        otaRebootDisconnectSuppressions.insert(key)
        let watchdog = DispatchWorkItem { [weak self] in
            self?.otaRebootDisconnectSuppressions.remove(key)
            self?.otaRebootDisconnectWatchdogs.removeValue(forKey: key)
        }
        otaRebootDisconnectWatchdogs[key] = watchdog
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: watchdog)
    }

    private func consumeOtaRebootDisconnectSuppression(peripheral: CBPeripheral) -> Bool {
        let key = reconnectKey(uuid: peripheral.identifier.uuidString)
        guard otaRebootDisconnectSuppressions.remove(key) != nil else {
            return false
        }
        otaRebootDisconnectWatchdogs.removeValue(forKey: key)?.cancel()
        loggerD(msg: "ota reboot disconnect: consume CoreBluetooth terminal \(peripheral.identifier.uuidString)")
        return true
    }
    
    /**
     *
     *  发送数据
     *
     *  - 升级中仅允许 OTA 通道和上层协议白名单确认的恢复控制指令
     *
     */
    func sendCmd(
        uuid: String,
        data: Data,
        psType: Int = 0,
        allowDuringUpgrade: Bool = false
    ) {
        guard checkIsFunctionCanBeCalled() else {
            return
        }
        // OTA 数据通道天然放行；common 只有 AUTH/时间同步等由业务协议显式标记后
        // 才能越过升级态，普通业务写入仍保持阻断。
        guard upgradeStateRegistry.canSend(
            endpointId: uuid,
            psType: psType,
            allowDuringUpgrade: allowDuringUpgrade
        ) else {
            loggerE(msg: "sendCmd: \(uuid), type=\(psType), cannot send non-OTA commands during upgrade")
            return
        }
        guard let device = connectedDevices.first(where: { device in
            device.peripheral.identifier.uuidString == uuid
        }) else {
            loggerE(msg: "sendCmd: \(uuid), type=\(psType), device cache missing")
            return
        }
        if let admission = currentConnectionAdmission(uuid: uuid) {
            guard let session = peripheralConnectionSessions[admission.sessionId],
                  session.peripheral === device.peripheral else {
                loggerE(msg: "sendCmd: \(uuid), type=\(psType), attempt stale, sessionGeneration=\(admission.sessionGeneration), attemptGeneration=\(admission.generation)")
                return
            }
        }
        guard let writeChars = device.writeCharsDic[psType] else {
            loggerE(msg: "sendCmd: \(uuid), type=\(psType), write characteristic missing")
            return
        }
        //  根据不同uuid类型获取不同的服务特征
        device.peripheral.writeValue(data, for: writeChars, type: .withoutResponse)
        loggerD(msg: "sendCmd: \(uuid), type=\(psType), writeChars=\(writeChars.uuid.uuidString), data length =\(data.count)")
    }

    /**
     *
     *  发送数据 - 不等待响应(Android sendCmdNoWait 的 iOS 对应)
     *
     *  - psType == 1 (OTA): 走 WriteWithoutResponse + canSendWriteWithoutResponse 背压队列,
     *    填满 packets-per-event, 与 Android WRITE_TYPE_NO_RESPONSE 对齐;
     *  - 其它 psType: 退化到现有 WriteWithoutResponse 立即返回路径(行为不变);
     *  - 设计与验收: 见 docs/IOS_OTA_NOWAIT_SPEC.md.
     */
    func sendCmdNoWait(uuid: String, data: Data, psType: Int, result: @escaping FlutterResult) {
        let isOtaChannel = (psType == 1)
        //  1、基础校验失败时，OTA 必须显式失败，避免上层把未提交的数据包当已发送。
        //  -- 非 OTA no-wait 保持历史 nil 返回，避免扩大 MethodChannel 行为面。
        guard checkIsFunctionCanBeCalled() else {
            if isOtaChannel {
                result(OtaWriteQueue.unavailableError(
                    endpoint: uuid,
                    reason: "manager unavailable",
                    pending: 0
                ))
            } else {
                result(nil)
            }
            return
        }
        //  2、升级中只放行 OTA 指令(与 sendCmd 保持一致)
        guard upgradeStateRegistry.canSend(endpointId: uuid, psType: psType) else {
            loggerE(msg: "sendCmdNoWait: \(uuid), type=\(psType), cannot send non-OTA commands during upgrade")
            if isOtaChannel {
                result(OtaWriteQueue.unavailableError(
                    endpoint: uuid,
                    reason: "upgrade gate rejected",
                    pending: 0
                ))
            } else {
                result(nil)
            }
            return
        }
        //  3、设备/特征不存在视为查找不到设备
        guard let device = connectedDevices.first(where: { device in
            device.peripheral.identifier.uuidString == uuid
        }), let writeChars = device.writeCharsDic[psType] else {
            loggerE(msg: "sendCmdNoWait: \(uuid), type=\(psType), device not found")
            if isOtaChannel {
                result(OtaWriteQueue.unavailableError(
                    endpoint: uuid,
                    reason: "device or characteristic missing",
                    pending: 0
                ))
            } else {
                result(nil)
            }
            return
        }
        //  4、分发: OTA 走背压队列, 其它走立即返回的 WriteWithoutResponse
        let supportsNoResponse = writeChars.properties.contains(.writeWithoutResponse)
        if isOtaChannel && supportsNoResponse {
            //  - 4.1、获取或惰性创建 OTA 写队列, 注入 loggerD 用于埋点
            let queue = otaWriteQueues[uuid] ?? OtaWriteQueue(
                peripheral: device.peripheral,
                logger: { [weak self] msg in
                    self?.loggerD(msg: msg)
                }
            )
            otaWriteQueues[uuid] = queue
            //  - 4.2、入队后只有真正调用 peripheral.writeValue 才回调成功。
            //  -- 这里构造提交目标而不让队列直接依赖 CBCharacteristic，便于 XCTest 覆盖背压时序。
            let target = OtaWriteTarget(
                characteristicUUID: writeChars.uuid.uuidString,
                submit: { peripheral, value in
                    guard let cbPeripheral = peripheral as? CBPeripheral else {
                        return false
                    }
                    cbPeripheral.writeValue(value, for: writeChars, type: .withoutResponse)
                    return true
                }
            )
            loggerD(msg: "[ezw_ble][ota] enqueued uuid=\(uuid) bytes=\(data.count) canSend=\(device.peripheral.canSendWriteWithoutResponse) queueDepth=\(queue.queueDepth)")
            queue.enqueue(data: data, target: target, result: result)
        } else if isOtaChannel {
            //  - 4.3、OTA 不支持 WriteWithoutResponse 时 fail closed，不能回退成
            //  -- 看似成功的旧路径，否则 Dart 继续推进会制造 OTA 死锁/错判。
            loggerE(msg: "[ezw_ble][ota] unsupported uuid=\(uuid) char=\(writeChars.uuid.uuidString) reason=missing writeWithoutResponse")
            result(OtaWriteQueue.unsupportedError(
                endpoint: uuid,
                reason: "missing writeWithoutResponse",
                pending: queueDepthForOta(uuid: uuid)
            ))
        } else {
            //  - 4.4、保持现有非 OTA 行为: WriteWithoutResponse 立即返回, 不做背压
            device.peripheral.writeValue(data, for: writeChars, type: .withoutResponse)
            loggerD(msg: "sendCmdNoWait: \(uuid), type=\(psType), writeChars=\(writeChars.uuid.uuidString), data length=\(data.count)")
            result(nil)
        }
    }

    /// OTA 错误 details 需要带上当前 native pending 深度，帮助区分“尚未提交”和“已提交后设备无 ack”。
    private func queueDepthForOta(uuid: String) -> Int {
        return otaWriteQueues[uuid]?.queueDepth ?? 0
    }

    /**
     *  进入升级模式
     */
    func enterUpgradeState(uuid: String) {
        guard !upgradeStateRegistry.contains(uuid) else {
            return
        }
        let connectedDevice = connectedDevices.first(where: { $0.peripheral.identifier.uuidString == uuid })
        let reconnectTask = reconnectTasks.values.first(where: { task in
            isSameConnectTarget(
                storedUuid: task.uuid,
                storedName: task.name,
                uuid: uuid,
                name: connectedDevice?.peripheral.name ?? ""
            )
        })
        let metadata = BleExplicitCancellationMetadataPolicy.resolve(
            currentAdmission: currentConnectionAdmission(uuid: uuid),
            reconnectTask: reconnectTask
        )
        // upgrade 只能投影真实业务连接；缓存、peripheral 或 epoch 任一失效都不得制造假连接态。
        guard let connectedDevice = connectedDevice,
              connectedDevice.isConnected,
              connectedDevice.peripheral.state == .connected,
              let metadata = metadata else {
            loggerE(msg: "enterUpgradeState rejected: \(uuid), missing live connected epoch")
            return
        }
        upgradeStateRegistry.enter(uuid)
        handleConnectState(
            uuid: uuid,
            name: connectedDevice.peripheral.name ?? "",
            state: .upgrade,
            source: metadata.source,
            generation: metadata.sessionGeneration,
            attemptGeneration: metadata.attemptGeneration
        )
        loggerD(msg: "enterUpgradeState: \(uuid), enter upgrade state")
    }
    
    /**
     *  退出升级模式
     */
    func quiteUpgradeState(uuid: String) {
        // 先消费 marker；后续校验失败时保留真实断连态，不能再次被旧 OTA 回调复活。
        guard upgradeStateRegistry.consume(uuid) else {
            return
        }
        let connectedDevice = connectedDevices.first(where: { $0.peripheral.identifier.uuidString == uuid })
        let reconnectTask = reconnectTasks.values.first(where: { task in
            isSameConnectTarget(
                storedUuid: task.uuid,
                storedName: task.name,
                uuid: uuid,
                name: connectedDevice?.peripheral.name ?? ""
            )
        })
        let metadata = BleExplicitCancellationMetadataPolicy.resolve(
            currentAdmission: currentConnectionAdmission(uuid: uuid),
            reconnectTask: reconnectTask
        )
        guard let connectedDevice = connectedDevice,
              connectedDevice.isConnected,
              connectedDevice.peripheral.state == .connected,
              let metadata = metadata else {
            loggerE(msg: "quiteUpgradeState rejected: \(uuid), connection already invalid")
            return
        }
        handleConnectState(
            uuid: uuid,
            name: connectedDevice.peripheral.name ?? "",
            state: .connected,
            source: metadata.source,
            generation: metadata.sessionGeneration,
            attemptGeneration: metadata.attemptGeneration
        )
        loggerD(msg: "quiteUpgradeState(\(uuid)): Had Quite upgrade state")
    }
    
    /**
     * 清除连接缓存
     */
    func cleanConnectCache() {
        cancelAllConnectionAdmissions(reason: "cleanConnectCache")
        businessConnectionLeases.clear()
        //  1、清理当前连接请求和搜索连接信息。
        activeConnectRequests.removeAll()
        startConnectInfos.removeAll()
        cancelAllReconnectTasks()
        clearPersistedReconnectTargets()
        //  2、取消连接超时计时器。
        connectingTimeoutTimers.forEach { (uuid, name, timer) in
            timer.invalidate()
        }
        connectingTimeoutTimers.removeAll()
        scanConnectTimeoutTimers.forEach { (uuid, name, timer) in
            timer.invalidate()
        }
        scanConnectTimeoutTimers.removeAll()
    }
    
    /**
     * 重置
     */
    func reset() {
        stopScan()
        cancelAllConnectionAdmissions(reason: "reset")
        businessConnectionLeases.clear()
        connectedDevices.forEach { device in
            centralManager.cancelPeripheralConnection(device.peripheral)
        }
        connectedDevices.removeAll()
        activeConnectRequests.removeAll()
        startConnectInfos.removeAll()
        connectingTimeoutTimers.forEach { (uuid, name, timer) in
            timer.invalidate()
        }
        connectingTimeoutTimers.removeAll()
        scanConnectTimeoutTimers.forEach { (uuid, name, timer) in
            timer.invalidate()
        }
        scanConnectTimeoutTimers.removeAll()
        upgradeStateRegistry.clear()
        preConnectedDevices.removeAll()
        cancelAllReconnectTasks()
        // resetBle 是中性 runtime teardown：持久 owner/autoReconnect 配置必须保留，
        // 由 Dart 下一次普通 cold_start/autoReconnect activate 建立全新 generation。
        //  清空所有 OTA 写队列, 通知 Dart 端 await 立即返回
        otaWriteQueues.values.forEach { $0.cancelAll(reason: "reset") }
        otaWriteQueues.removeAll()
        stopAllNativeTraceRssiSampling()
        nativeTraceRssiInFlightAttemptIds.removeAll()
        nativeTraceLastConnectStates.removeAll()
        nativeConnectionTraces.removeAll()
        loggerD(msg: "Reset: success")
    }
    
}

// MARK: - Private Methods
extension BleManager {
    
    /**
     *  检查是否设置了蓝牙配置，且正确设置了基础私有服务
     */
    private func checkBleConfigIsConfigured() -> Bool {
        guard let commonPs = bleConfigs.first?.privateServices.first else {
            loggerD(msg: "checkBleConfigIsConfigured: Bluetooth configuration has not been configured or not setting private service yet")
            return false
        }
        guard commonPs.type == 0 else {
            loggerD(msg: "checkBleConfigIsConfigured: The first type of private service must be 0, where 0 represents the basic private service.")
            return false
        }
        return true
    }
    
    /**
     * 检查是否可以调用方法
     *
     * 1、检查蓝牙状态，2、检查是否启用蓝牙配置
    */
    func checkIsFunctionCanBeCalled() -> Bool {
           if (currentBleState != 5) {
               loggerD(msg: "checkBleConfigIsConfigured: ble status = \(currentBleState)")
               return false
           }
           if (!checkBleConfigIsConfigured()) {
               return false
           }
           return true
       }
    
    /**
     *  查找相应的蓝牙配置
     */
    func findCurrentBleConfig(belongConfig: String, uuid: String, name: String) -> BleConfig? {
        guard let currentConfig = bleConfigs.first(where: { config in
            config.name == belongConfig
        })  else {
            handleConnectState(uuid: uuid, name: name, state: .noBleConfigFound)
            return nil
        }
        return currentConfig
    }
    
    /// Apple ANCS 服务 UUID。外设若因 ANCS 被系统自动连接会停止广播，扫描无法发现，
    /// 必须靠 retrieveConnectedPeripherals/retrievePeripherals 取回后直连。
    private static let ancsServiceUUID = CBUUID(string: "7905F431-B5CE-4E99-A40F-4B1E122D00D0")

    /**
     *  获取"系统已连接"的目标外设(覆盖蓝牙设置页/ANCS 等系统级连接)。
     *
     *  用配置全部私有服务 + ANCS 服务一起查询：ANCS-only 连接时私有服务可能尚未被
     *  CoreBluetooth 缓存，只查单个私有服务会漏掉，导致目标掉进扫描而报 630。
     */
    func findPeripheralFromConnected(
        uuid: String,
        name: String,
        serviceUUIDs: [CBUUID],
        requireUniqueMatch: Bool = false
    )-> CBPeripheral? {
        var queryServices = serviceUUIDs
        if !queryServices.contains(BleManager.ancsServiceUUID) {
            queryServices.append(BleManager.ancsServiceUUID)
        }
        guard !queryServices.isEmpty else { return nil }
        let connectedPeripherals = retrieveConnectedPeripheralsWhenAppActive(
            withServices: queryServices,
            context: "findPeripheralFromConnected"
        )
        let matches = connectedPeripherals.filter { device in
            BleReconnectIdentityPolicy.matchesSystemConnectedPeripheral(
                taskUuid: uuid,
                taskName: name,
                peripheralUuid: device.identifier.uuidString,
                peripheralName: device.name ?? ""
            )
        }
        // 1、冷启动 name-only 恢复不得从同名历史设备中任取一个；UUID 已知或普通
        // 调用保持原行为，只有明确要求唯一候选时才 fail-closed。
        if requireUniqueMatch && matches.count != 1 {
            return nil
        }
        return matches.first
    }

    /**
     * Active-only wrapper for CoreBluetooth's synchronous connected-peripheral query.
     *
     * `CBCentralManager(queue: nil)` and MethodChannel callbacks both use the main queue.
     * During process exit this API can block in synchronous XPC longer than FrontBoard's
     * five-second grace window, so inactive callers must defer instead of querying.
     */
    func retrieveConnectedPeripheralsWhenAppActive(
        withServices serviceUUIDs: [CBUUID],
        context: String
    ) -> [CBPeripheral] {
        guard allowsSynchronousCoreBluetoothLookup else {
            loggerD(msg: "appLifecycle: defer retrieveConnectedPeripherals context=\(context)")
            return []
        }
        return centralManager.retrieveConnectedPeripherals(withServices: serviceUUIDs)
    }

    /**
     * Active-only wrapper for CoreBluetooth's synchronous identifier lookup.
     *
     * Callers retain their existing in-memory peripheral while inactive; an empty
     * result here means "deferred", not "device missing", and must not create a terminal state.
     */
    func retrievePeripheralsWhenAppActive(
        withIdentifiers identifiers: [UUID],
        context: String
    ) -> [CBPeripheral] {
        guard allowsSynchronousCoreBluetoothLookup else {
            loggerD(msg: "appLifecycle: defer retrievePeripherals context=\(context)")
            return []
        }
        return centralManager.retrievePeripherals(withIdentifiers: identifiers)
    }
    
    
    /**
     *  解析数据获取MAC地址
     */
    /**
     *  判断两个 active connect owner 是否是同一请求。
     *
     *  CoreBluetooth 扫描早期可能只有 name 或 temp-UUID，因此仍需要 name fallback；
     *  但双方都有稳定 UUID 时必须只认 UUID，避免同名/空名设备互相删除请求或定时器。
     */
    func isSameActiveConnectTarget(storedUuid: String, storedName: String, uuid: String, name: String) -> Bool {
        // 1. 稳定 UUID 是最强身份。双方都有稳定 UUID 且不同，就不能再用 name 兜底。
        let storedHasStableUuid = storedUuid.isNotEmpty && !storedUuid.hasPrefix("temp-")
        let targetHasStableUuid = uuid.isNotEmpty && !uuid.hasPrefix("temp-")
        if storedHasStableUuid && targetHasStableUuid {
            return storedUuid == uuid
        }

        // 2. temp/空 UUID 阶段才允许 name fallback；空 name 永远不能互相命中。
        return (!storedUuid.isEmpty && !uuid.isEmpty && storedUuid == uuid) ||
            (!storedName.isEmpty && !name.isEmpty && storedName == name)
    }

    /**
     *  写入当前连接请求。
     */
    func upsertActiveConnectRequest(_ request: BleEasyConnect) {
        //  1、先移除同 owner 的旧请求；双方都有稳定 UUID 时不允许仅因同名互相覆盖。
        activeConnectRequests.removeAll { item in
            isSameActiveConnectTarget(
                storedUuid: item.uuid,
                storedName: item.name,
                uuid: request.uuid,
                name: request.name
            )
        }
        //  2、写入最新连接请求，供 didConnect/服务发现/特征发现回调反查配置。
        activeConnectRequests.append(request)
    }

    /**
     *  根据外设查找当前连接请求。
     */
    private func findActiveConnectRequest(peripheral: CBPeripheral) -> BleEasyConnect? {
        //  1、优先用 UUID 或名称匹配请求。
        return findActiveConnectRequest(
            uuid: peripheral.identifier.uuidString,
            name: peripheral.name ?? ""
        )
    }

    /**
     *  根据 UUID 或名称查找当前连接请求。
     */
    func findActiveConnectRequest(uuid: String, name: String) -> BleEasyConnect? {
        //  1、通过 active owner 匹配请求，避免空 name 或同名设备串扰。
        return activeConnectRequests.first { request in
            isSameActiveConnectTarget(
                storedUuid: request.uuid,
                storedName: request.name,
                uuid: uuid,
                name: name
            )
        }
    }

    /**
     * 更新当前活动连接请求的 UUID。
     *
     * scan-then-connect 初始请求可能只有设备名；扫描命中真实 peripheral 后，必须把 CoreBluetooth
     * identifier 回写到 active request，后续 didConnect/service/characteristic 回调才能找到配置。
     */
    func updateActiveConnectRequestUuid(uuid: String, name: String) {
        // 1. 通过 active owner 找到同一目标的活动请求。
        guard let index = activeConnectRequests.firstIndex(where: { request in
            isSameActiveConnectTarget(
                storedUuid: request.uuid,
                storedName: request.name,
                uuid: uuid,
                name: name
            )
        }) else {
            return
        }

        // 2. 只补写 UUID，不改变请求中的配置、名称或升级标记。
        activeConnectRequests[index].uuid = uuid
    }

    /**
     *  移除当前连接请求。
     */
    func removeActiveConnectRequest(uuid: String, name: String) {
        //  1、只移除同 owner 的请求，避免同名左右腿互相清理。
        activeConnectRequests.removeAll { request in
            isSameActiveConnectTarget(
                storedUuid: request.uuid,
                storedName: request.name,
                uuid: uuid,
                name: name
            )
        }
    }

    /**
     *  查找「协议层尚未 connectFinish」的缓存外设（`isConnected == false`），用于用户取消连接。
     *
     *  - Dart 常传空 uuid + 设备名；CoreBluetooth 在 GATT 连接过程中 `peripheral.name` 可能仍为 nil，
     *    仅靠外设名称匹配会失败，需通过 `activeConnectRequests`（与 connect() 写入的 uuid/name 一致）桥接。
     *  - 必须在移除 `activeConnectRequests` 之前调用，否则无法反查。
     */
    private func findUnfinishedConnectDevice(uuid: String, name: String) -> BleConnectedDevice? {
        if let req = findActiveConnectRequest(uuid: uuid, name: name) {
            if let matched = connectedDevices.first(where: { device in
                guard !device.isConnected else { return false }
                if !req.uuid.isEmpty, device.peripheral.identifier.uuidString == req.uuid {
                    return true
                }
                if !req.name.isEmpty {
                    let pname = device.peripheral.name ?? ""
                    if pname == req.name { return true }
                }
                return false
            }) {
                return matched
            }
            //  请求仍为 temp-UUID 且尚未与 CB 标识对齐时，用未完成条目 + 名称收窄（避免仅靠 peripheral.name==nil 失配）
            if req.uuid.hasPrefix("temp-") {
                let unfinished = connectedDevices.filter { !$0.isConnected }
                if unfinished.count == 1 {
                    return unfinished.first
                }
                return unfinished.first { d in
                    let pn = d.peripheral.name ?? ""
                    if !req.name.isEmpty, pn == req.name { return true }
                    if !name.isEmpty, pn == name { return true }
                    return false
                }
            }
            return nil
        }
        return connectedDevices.first { device in
            guard !device.isConnected else { return false }
            let pid = device.peripheral.identifier.uuidString
            let pname = device.peripheral.name ?? ""
            if !uuid.isEmpty, pid == uuid { return true }
            if !name.isEmpty, !pname.isEmpty, pname == name { return true }
            return false
        }
    }


    /**
     *  非 directConnect 连接前清除目标在 scanResultTemp 中的陈旧条目，避免离线/屏蔽箱设备仍被 blind GATT connect 拖成 timeout。
     */
    func purgeStaleScanCache(uuid: String, name: String) {
        scanResultTemp.removeAll { info in
            (!uuid.isEmpty && info.0.uuid == uuid) ||
            (!name.isEmpty && (info.0.name == name || info.1.name == name))
        }
    }

    /**
     *  判断目标是否出现在当前扫描窗口缓存中（与 Android isTargetVisibleInScan 对齐）。
     */
    func isTargetVisibleInScan(uuid: String, name: String) -> Bool {
        scanResultTemp.contains { info in
            (!uuid.isEmpty && info.0.uuid == uuid) ||
            (!name.isEmpty && (info.0.name == name || info.1.name == name))
        }
    }

    /**
     *  查找指定外设所属 BLE 配置。
     */
    func findBleConfig(uuid: String, name: String) -> BleConfig? {
        //  1、优先从当前连接请求中获取配置。
        if let config = findActiveConnectRequest(uuid: uuid, name: name)?.bleConfig {
            return config
        }
        //  2、其次从已连接缓存中获取配置。
        return connectedDevices.first { device in
            device.peripheral.identifier.uuidString == uuid ||
            device.peripheral.name == name
        }?.belongConfig
    }

    /// 打开/关闭进程内 native Trace；关闭只清诊断缓存和 RSSI timer，不改变连接 owner。
    func setConnectionTraceEnabled(_ enabled: Bool) {
        connectionTraceEnabled = enabled
        if !enabled {
            stopAllNativeTraceRssiSampling()
            nativeConnectionTraces.removeAll()
            nativeTraceRssiInFlightAttemptIds.removeAll()
            nativeTraceLastConnectStates.removeAll()
        }
        loggerD(msg: "connection trace enabled=\(enabled)")
    }

    func startNativeTrace(endpointId: String) {
        guard connectionTraceEnabled, !endpointId.isEmpty else { return }
        let key = reconnectKey(uuid: endpointId)
        let trace = BleNativeConnectionTraceBuffer()
        trace.record(stage: "attempt", result: "started")
        nativeConnectionTraces[key] = trace
        nativeTraceLastConnectStates.removeValue(forKey: key)
    }

    func recordNativeTrace(
        uuid: String,
        stage: String,
        result: String,
        serviceType: String? = nil,
        causeDomain: String? = nil,
        causeCode: Int? = nil,
        bondState: String? = nil,
        writeLimitBytes: Int? = nil,
        linkTrigger: String? = nil,
        rssiBucket: String? = nil,
        phy: String? = nil,
        priorityAction: String? = nil,
        actionResult: String? = nil
    ) {
        guard connectionTraceEnabled, !uuid.isEmpty else { return }
        nativeConnectionTraces[reconnectKey(uuid: uuid)]?.record(
            stage: stage,
            result: result,
            serviceType: serviceType,
            causeDomain: causeDomain,
            causeCode: causeCode,
            bondState: bondState,
            writeLimitBytes: writeLimitBytes,
            linkTrigger: linkTrigger,
            rssiBucket: rssiBucket,
            phy: phy,
            priorityAction: priorityAction,
            actionResult: actionResult
        )
    }

    func nativeTraceSnapshot(uuid: String) -> BleNativeConnectionTrace? {
        guard connectionTraceEnabled else { return nil }
        return nativeConnectionTraces[reconnectKey(uuid: uuid)]?.snapshot()
    }

    func recordNativeTraceForState(uuid: String, state: BleConnectState) {
        guard connectionTraceEnabled else { return }
        let key = reconnectKey(uuid: uuid)
        let previousState = nativeTraceLastConnectStates[key]
        nativeTraceLastConnectStates[key] = state
        switch state {
        case .connecting:
            recordNativeTrace(uuid: uuid, stage: "connect", result: "started")
        case .contactDevice:
            recordNativeTrace(uuid: uuid, stage: "connect", result: "success", causeDomain: "CoreBluetooth")
            // CoreBluetooth intentionally exposes no public bond-state API. The
            // marker follows physical connect and never infers `bonded` from GATT.
            recordNativeTrace(
                uuid: uuid,
                stage: "bond",
                result: "not_observable",
                bondState: "not_observable"
            )
            recordNativeTrace(
                uuid: uuid,
                stage: "link_policy",
                result: "state_changed",
                linkTrigger: "platform_capability",
                phy: "unknown",
                priorityAction: "unsupported",
                actionResult: "not_applicable"
            )
        case .searchService:
            recordNativeTrace(uuid: uuid, stage: "service_discovery", result: "started")
        case .serviceFail:
            recordNativeTrace(uuid: uuid, stage: "service_discovery", result: "failed")
        case .searchChars:
            recordNativeTrace(uuid: uuid, stage: "characteristic_discovery", result: "started")
        case .charsFail:
            recordNativeTrace(uuid: uuid, stage: "characteristic_discovery", result: "failed")
        case .startBinding:
            recordNativeTrace(
                uuid: uuid,
                stage: "bond",
                result: "started",
                bondState: "security_recovery"
            )
        case .alreadyBound:
            recordNativeTrace(
                uuid: uuid,
                stage: "bond",
                result: "failed",
                bondState: "security_recovery"
            )
        case .boundFail:
            recordNativeTrace(
                uuid: uuid,
                stage: "bond",
                result: "failed",
                bondState: "security_recovery"
            )
        case .noDeviceFound:
            recordNativeTrace(uuid: uuid, stage: "scan", result: "failed")
        case .connectFinish:
            recordNativeTrace(uuid: uuid, stage: "gatt_ready", result: "success")
        case .timeout:
            if previousState == .startBinding {
                recordNativeTrace(
                    uuid: uuid,
                    stage: "bond",
                    result: "timeout",
                    causeDomain: "CoreBluetooth",
                    bondState: "security_recovery"
                )
            } else {
                recordNativeTrace(uuid: uuid, stage: "connect", result: "timeout", causeDomain: "watchdog")
            }
        case .bleError, .systemError:
            recordNativeTrace(uuid: uuid, stage: "connect", result: "failed")
        case .disconnectByUser:
            if previousState == .startBinding {
                recordNativeTrace(
                    uuid: uuid,
                    stage: "bond",
                    result: "cancelled",
                    bondState: "security_recovery"
                )
            }
            recordNativeTrace(uuid: uuid, stage: "disconnect", result: "expected")
            stopNativeTraceRssiSampling(uuid: uuid)
        case .disconnectFromSys:
            recordNativeTrace(uuid: uuid, stage: "disconnect", result: "abnormal")
            stopNativeTraceRssiSampling(uuid: uuid)
        default:
            break
        }
    }

    func startNativeTraceRssiSampling(peripheral: CBPeripheral) {
        guard connectionTraceEnabled else { return }
        let key = reconnectKey(uuid: peripheral.identifier.uuidString)
        stopNativeTraceRssiSampling(uuid: peripheral.identifier.uuidString)
        // Freeze the producer attempt into the timer. A replacement attempt may
        // reuse the same CoreBluetooth UUID but must never inherit this sampler.
        guard let expectedAttemptId = nativeConnectionTraces[key]?.attemptId else { return }
        nativeTraceRssiTimers[key] = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self, weak peripheral] _ in
            guard let self = self, let peripheral = peripheral else { return }
            self.readNativeTraceRssi(peripheral: peripheral, expectedAttemptId: expectedAttemptId)
            self.nativeTraceRssiTimers[key] = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: true) { [weak self, weak peripheral] _ in
                guard let self = self, let peripheral = peripheral else { return }
                self.readNativeTraceRssi(peripheral: peripheral, expectedAttemptId: expectedAttemptId)
            }
        }
    }

    func stopNativeTraceRssiSampling(uuid: String) {
        let key = reconnectKey(uuid: uuid)
        nativeTraceRssiTimers.removeValue(forKey: key)?.invalidate()
        nativeTraceRssiInFlightAttemptIds.removeValue(forKey: key)
    }

    func stopAllNativeTraceRssiSampling() {
        nativeTraceRssiTimers.values.forEach { $0.invalidate() }
        nativeTraceRssiTimers.removeAll()
        nativeTraceRssiInFlightAttemptIds.removeAll()
    }

    private func readNativeTraceRssi(peripheral: CBPeripheral, expectedAttemptId: String) {
        let uuid = peripheral.identifier.uuidString
        let key = reconnectKey(uuid: uuid)
        // The Gate admission ends at business connected, while the physical
        // link and its trace remain alive. Continue only for the exact cached
        // peripheral, and reject an old timer after attempt replacement.
        let hasExactBusinessOwner = peripheral.state == .connected && connectedDevices.contains { device in
            device.peripheral === peripheral &&
                device.isConnected &&
                device.isBleFlowCompleted
        }
        guard connectionTraceEnabled,
              let trace = nativeConnectionTraces[key],
              trace.attemptId == expectedAttemptId,
              nativeTraceRssiInFlightAttemptIds[key] == nil,
              currentConnectionAdmission(uuid: uuid) != nil || hasExactBusinessOwner else {
            return
        }
        nativeTraceRssiInFlightAttemptIds[key] = expectedAttemptId
        peripheral.readRSSI()
    }

    /**
     *  处理已经连接的设备
     */
    func handleAlreadyConnected(peripheral: CBPeripheral,  bleConfig: BleConfig, deviceName: String, tag: String = "") {
        // 旧入口仅作为「已有物理链路」适配层，禁止直接 discoverServices。
        if currentConnectionAdmission(uuid: peripheral.identifier.uuidString) == nil {
            _ = registerConnectionAttempt(
                peripheral: peripheral,
                config: bleConfig,
                deviceName: deviceName,
                afterUpgrade: false,
                source: .foreground
            )
        }
        connectPeripheralAfterCancellationBarrier(peripheral, autoReconnect: false)
    }

    func processDiscoveredServices(peripheral: CBPeripheral, error: Error?, tag: String) {
        guard isCurrentConnectionPipeline(peripheral) else { return }
        //  1、根据条件判断服务是否正常获取
        //  - 1.1、搜索服务出现异常错误
        guard error == nil else {
            let nsError = error as NSError?
            recordNativeTrace(
                uuid: peripheral.identifier.uuidString,
                stage: "service_discovery",
                result: "failed",
                causeDomain: nsError?.domain,
                causeCode: nsError?.code
            )
            if let nsError {
                recordBondSecurityFailureIfNeeded(peripheral: peripheral, error: nsError)
            }
            handleConnectState(uuid: peripheral.identifier.uuidString, name: peripheral.name ?? "", state: .serviceFail, tag: tag)
            loggerD(msg: "didDiscoverServices: \(peripheral.identifier.uuidString), search service fail = \(String(describing: error))")
            return
        }
        //  - 1.2、没有查询到配置
        guard let bleConfig = findBleConfig(uuid: peripheral.identifier.uuidString, name: peripheral.name ?? "") else {
            handleConnectState(uuid: peripheral.identifier.uuidString, name: peripheral.name ?? "", state: .noBleConfigFound, tag: tag)
            return
        }
        //  - 1.3、没有获取服务
        guard let services = peripheral.services else {
            handleConnectState(uuid: peripheral.identifier.uuidString, name: peripheral.name ?? "", state: .serviceFail, tag: tag)
            return
        }
        //  2、只获取需要注册的服务
        let myServices = services.filter { service in
            bleConfig.privateServices.contains { ps in
                ps.service == service.uuid.uuidString
            }
        }
        loggerD(msg: "didDiscoverServices: \(peripheral.identifier.uuidString)-\(peripheral.name ?? ""), total=\(services.count), matched=\(myServices.count), expected=\(bleConfig.privateServices.count), tag=\(tag)")
        recordNativeTrace(uuid: peripheral.identifier.uuidString, stage: "service_discovery", result: "success")
        handleConnectState(uuid: peripheral.identifier.uuidString, name: peripheral.name ?? "", state: .searchChars, tag: tag)
        //  - 2.1、遍历发现所有私有服务的读写特征。缓存完整时直接消费缓存特征，避免恢复路径等不到回调。
        myServices.forEach { service in
            loggerD(msg: "didDiscoverServices: \(peripheral.identifier.uuidString), service = \(service.uuid.uuidString), charsCached=\(service.characteristics?.count ?? 0), tag=\(tag)")
            if let characteristics = service.characteristics, characteristics.isNotEmpty {
                processDiscoveredCharacteristics(peripheral: peripheral, service: service, error: nil, tag: "\(tag) cached")
            } else {
                peripheral.discoverCharacteristics(nil, for: service)
            }
        }
    }

    func processDiscoveredCharacteristics(peripheral: CBPeripheral, service: CBService, error: Error?, tag: String) {
        guard isCurrentConnectionPipeline(peripheral) else { return }
        //  1、处理错误回调
        guard error == nil else {
            let nsError = error as NSError?
            recordNativeTrace(
                uuid: peripheral.identifier.uuidString,
                stage: "characteristic_discovery",
                result: "failed",
                causeDomain: nsError?.domain,
                causeCode: nsError?.code
            )
            if let nsError {
                recordBondSecurityFailureIfNeeded(peripheral: peripheral, error: nsError)
            }
            handleConnectState(uuid: peripheral.identifier.uuidString, name: peripheral.name ?? "", state: .charsFail, tag: tag)
            loggerE(msg: "didDiscoverCharacteristicsFor: \(peripheral.identifier.uuidString), error = \(String(describing: error))")
            return
        }
        //  2、获取设备所属蓝牙配置
        guard let bleConfig = findBleConfig(uuid: peripheral.identifier.uuidString, name: peripheral.name ?? "") else {
            handleConnectState(uuid: peripheral.identifier.uuidString, name: peripheral.name ?? "", state: .noBleConfigFound, tag: tag)
            return
        }
        //  3、不处理不在配置中的私有服务
        guard let privateService = bleConfig.privateServices.first(where: { uuid in
            uuid.serviceUUID == service.uuid
        }) else {
            handleConnectState(uuid: peripheral.identifier.uuidString, name: peripheral.name ?? "", state: .charsFail, tag: tag)
            loggerE(msg: "didDiscoverCharacteristicsFor: \(peripheral.identifier.uuidString), error =  ")
            return
        }
        //  4、获取读写特征
        let writeChars = service.characteristics?.first { write in
            write.uuid == privateService.writeCharUUID
        }
        let readChars = service.characteristics?.first { read in
            read.uuid == privateService.readCharUUID
        }
        if writeChars == nil || readChars == nil {
            recordNativeTrace(
                uuid: peripheral.identifier.uuidString,
                stage: "characteristic_discovery",
                result: "failed",
                serviceType: "\(privateService.type)"
            )
            handleConnectState(uuid: peripheral.identifier.uuidString, name: peripheral.name ?? "", state: .charsFail, tag: tag)
            loggerE(msg: "didDiscoverCharacteristicsFor: \(peripheral.identifier.uuidString), error = Chars not found")
            return
        }
        if let connectedDevice = connectedDevices.first(where: { device in
            device.peripheral.identifier.uuidString == peripheral.identifier.uuidString
        }),
           connectedDevice.writeCharsDic[privateService.type]?.uuid == writeChars!.uuid,
           connectedDevice.readCharsDic[privateService.type]?.uuid == readChars!.uuid {
            loggerD(msg: "didDiscoverCharacteristicsFor: \(peripheral.identifier.uuidString), psType = \(privateService.type), duplicate chars ignored, tag=\(tag)")
            return
        }
        recordNativeTrace(
            uuid: peripheral.identifier.uuidString,
            stage: "characteristic_discovery",
            result: "success",
            serviceType: "\(privateService.type)"
        )
        updateConnectedDevice(uuid: peripheral.identifier.uuidString, name: peripheral.name ?? "", writeChars: writeChars, readChars: readChars, psType: privateService.type)
        loggerD(msg: "didDiscoverCharacteristicsFor: \(peripheral.identifier.uuidString), psType = \(privateService.type), write = \(writeChars!.uuid.uuidString), read = \(readChars!.uuid.uuidString), tag=\(tag)")
    }
    
    /**
     *  开始连接后，执行连接超时倒计时
     */
    func startConnectingCountdown(
        currentConfig: BleConfig,
        uuid: String,
        name: String,
        afterUpgrade: Bool,
        isAuthGrace: Bool = false,
        admission: BleConnectionAdmission? = nil
    ) {
        //  1、检查是否存在相同的
        guard !connectingTimeoutTimers.contains(where: { info in
            isSameActiveConnectTarget(storedUuid: info.0, storedName: info.1, uuid: uuid, name: name)
        }) else {
            return
        }
        //  2、创建连接超时倒计时定时器
        let timer = Timer.scheduledTimer(withTimeInterval: (currentConfig.connectTimeout + (afterUpgrade ? currentConfig.upgradeSwapTime : 0)) / 1000, repeats: false) { [weak self] timer in
            guard let self = self else { return }
            if let admission = admission, self.currentConnectionAdmission(admission) == nil {
                // Gate owner 已更换，说明本 timer 属于迟到 generation/session。
                return
            }
            //  先移除当前(一次性)超时定时器记录
            if let index = self.connectingTimeoutTimers.firstIndex(where: { info in
                self.isSameActiveConnectTarget(storedUuid: info.0, storedName: info.1, uuid: uuid, name: name)
            }) {
                self.connectingTimeoutTimers.remove(at: index)
            }
            //  已连接：无需任何处理
            guard self.connectedDevices.first(where: { device in
                device.peripheral.identifier.uuidString == uuid || device.peripheral.name == name
            })?.isConnected != true else {
                return
            }
            //  预连接(协议层鉴权进行中)：给一次有界宽限期，而不是永久豁免。
            //  永久豁免会导致 Dart 端鉴权流程异常/挂起(deviceConnected 永不到达)时，
            //  设备永久停在 connectFinish，App UI 一直显示"连接中"且无法自愈。
            if self.preConnectedDevices.contains(uuid) && !isAuthGrace {
                self.loggerD(msg: "connect-flow: \(uuid)-\(name), pre-connected, start bounded auth grace")
                self.startConnectingCountdown(
                    currentConfig: currentConfig,
                    uuid: uuid,
                    name: name,
                    afterUpgrade: afterUpgrade,
                    isAuthGrace: true,
                    admission: admission
                )
                return
            }
            //  宽限期到期仍未连接(或本就不是预连接) → 强制超时，避免永久卡在 connecting。
            self.handleConnectState(
                uuid: uuid,
                name: name,
                state: .timeout,
                source: admission.flatMap { self.currentConnectionAdmission($0)?.source } ?? .unknown
            )
        }
        connectingTimeoutTimers.append((uuid, name, timer))
        loggerD(msg: "connect-flow: \(uuid)-\(name), start connect time out timer\(isAuthGrace ? " (auth grace)" : "")")
    }

    /**
     *  开始扫描后再连接阶段的超时倒计时。
     *
     *  iOS 后台扫描可能长时间没有 didDiscover 回调，不能只依赖扫描回调里的时间差检查。
     *  这里仍保持 scan 阶段“找不到设备”的 noDeviceFound 语义，避免把没电/拉距误报成 GATT timeout。
     */
    func startScanConnectTimeout(currentConfig: BleConfig, uuid: String, name: String, afterUpgrade: Bool) {
        cancelScanConnectTimeout(uuid: uuid, name: name)
        let timeout = (currentConfig.connectTimeout + (afterUpgrade ? currentConfig.upgradeSwapTime : 0)) / 1000
        let timer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            self.scanConnectTimeoutTimers.removeAll { info in
                self.isSameActiveConnectTarget(storedUuid: info.0, storedName: info.1, uuid: uuid, name: name)
            }
            guard self.findActiveConnectRequest(uuid: uuid, name: name) != nil else {
                return
            }
            guard self.startConnectInfos.contains(where: { info in
                self.isSameActiveConnectTarget(storedUuid: info.uuid, storedName: info.name, uuid: uuid, name: name)
            }) else {
                return
            }
            self.startConnectInfos.removeAll { info in
                self.isSameActiveConnectTarget(storedUuid: info.uuid, storedName: info.name, uuid: uuid, name: name)
            }
            if self.startConnectInfos.isEmpty {
                self.stopScan()
            }
            self.handleConnectState(uuid: uuid, name: name, state: .noDeviceFound, tag: "scan connect timeout")
            self.loggerD(msg: "connect-flow: \(uuid)-\(name), scan connect timeout")
        }
        scanConnectTimeoutTimers.append((uuid, name, timer))
        loggerD(msg: "connect-flow: \(uuid)-\(name), start scan connect timeout timer")
    }

    /**
     *  取消扫描后再连接阶段的超时倒计时。
     */
    func cancelScanConnectTimeout(uuid: String, name: String) {
        scanConnectTimeoutTimers = scanConnectTimeoutTimers.filter { info in
            let shouldCancel = isSameActiveConnectTarget(storedUuid: info.0, storedName: info.1, uuid: uuid, name: name)
            if shouldCancel {
                info.2.invalidate()
            }
            return !shouldCancel
        }
    }

    /**
     *  处理连接失败
     */
    private func handleConnectError(peripheral: CBPeripheral, error: Error?, formMethod: String) {
        // OTA reboot teardown 已同步上报同代断连并主动 cancel；这条回调只是系统确认。
        // 若按普通系统断连再次调度，会在固件 reboot 期间与 afterUpgrade activation 竞争。
        if consumeOtaRebootDisconnectSuppression(peripheral: peripheral) {
            return
        }
        //  1、连接识别标签
        let tag = "didDisconnect"
        let logHead = "didFailToConnect-\(formMethod):"
        // 2. connecting/queued 外设即使尚未进 connectedDevices，也必须按 exact
        // generation/session/peripheral 释放 Gate；禁止仅按 UUID 抓到后续新 attempt。
        if let admission = currentConnectionAdmission(uuid: peripheral.identifier.uuidString) {
            guard let session = peripheralConnectionSessions[admission.sessionId],
                  session.peripheral === peripheral else {
                loggerD(msg: "\(logHead) \(peripheral.identifier.uuidString), stale terminal peripheral ignored")
                return
            }
            let nsError = error as NSError?
            let hasAutoReconnectTask = reconnectTasks.values.contains { task in
                isSameConnectTarget(
                    storedUuid: task.uuid,
                    storedName: task.name,
                    uuid: peripheral.identifier.uuidString,
                    name: peripheral.name ?? ""
                )
            }
            var pairingFailureAction: BlePeerPairingFailureAction?
            if nsError?.code == 14, hasAutoReconnectTask {
                // 被动自动回连只允许一次新鲜广播恢复；手动连接或恢复再次失败
                // 都结束本轮 owner，下一次手动点击才会创建新的真实连接。
                pairingFailureAction = registerPeerPairingFailure(
                    uuid: peripheral.identifier.uuidString,
                    name: peripheral.name ?? session.deviceName,
                    source: admission.source
                )
            } else if nsError?.code != 14, hasAutoReconnectTask {
                resetPeerPairingRecoveryAfterNonPairingFailure(
                    uuid: admission.endpointId,
                    name: peripheral.name ?? session.deviceName
                )
            }
            // stopAttempt 表示当前 owner 已删除；统一上报 alreadyBound 终态。
            // App 只会把 manual source 的本次真实 Code 14 映射成 720，自动来源静默。
            let stoppedForPairingFailure = pairingFailureAction == .stopAttempt
            let state: BleConnectState = (nsError?.code == 14 && (!hasAutoReconnectTask || stoppedForPairingFailure))
                ? .alreadyBound
                : .disconnectFromSys
            recordNativeTrace(
                uuid: admission.endpointId,
                stage: state == .alreadyBound ? "bond" : "disconnect",
                result: state == .alreadyBound ? "failed" : "abnormal",
                causeDomain: nsError?.domain,
                causeCode: nsError?.code,
                bondState: state == .alreadyBound ? "security_recovery" : nil
            )
            handleConnectState(
                uuid: admission.endpointId,
                name: peripheral.name ?? session.deviceName,
                state: state,
                source: admission.source,
                // native attempt generation 只用于 exact Gate teardown；Flutter 终态
                // 必须沿用 recovery batch 的逻辑 session，避免 epoch guard 丢弃真回调。
                generation: admission.sessionGeneration,
                peripheralTerminalAcknowledged: true,
                tag: tag
            )
            loggerE(msg: "\(logHead) \(admission.endpointId), queued/active terminal state=\(state.rawValue), error=\(String(describing: error))")
            return
        }
        //  2、获取我正在连接的设备
        guard let myDevice = connectedDevices.first(where: {$0.peripheral.identifier.uuidString == peripheral.identifier.uuidString}) else {
            loggerE(msg: "\(logHead) \(peripheral.identifier.uuidString), not my connected device")
            return
        }
        //  3、error 为空不一定是用户主动断连。蓝牙关闭 / 系统回收 CoreBluetooth
        //     pending 连接时也可能给 nil error；只要当前是系统蓝牙不可用，或该设备仍有
        //     autoReconnect 任务，就必须按系统断连处理，避免误清长期回连意图。
        guard let error = error as? NSError else {
            //  不执行断连
            //  - 已经断连就不再处理
            //  - 没有退出升级状态的不用处理
            if myDevice.isConnected {
                let shouldKeepReconnect = centralManager.state != .poweredOn ||
                    reconnectTasks.values.contains { task in
                        isSameConnectTarget(
                            storedUuid: task.uuid,
                            storedName: task.name,
                            uuid: peripheral.identifier.uuidString,
                            name: peripheral.name ?? ""
                        )
                    }
                let state: BleConnectState = shouldKeepReconnect ? .disconnectFromSys : .disconnectByUser
                handleConnectState(
                    uuid: peripheral.identifier.uuidString,
                    name: peripheral.name ?? "",
                    state: state,
                    peripheralTerminalAcknowledged: true,
                    tag: tag
                )
                loggerE(msg: "\(logHead) \(peripheral.identifier.uuidString), nil error disconnect mapped to \(state.rawValue), bluetooth=\(centralManager.state.label)")
            }
            return
        }
        //  4、错误处理
        //  - 4.1、iOS error 14 表示 pairing 信息失配；autoReconnect 模式下这是可恢复的
        //        系统断连错误，不能进入 alreadyBound 终态，否则会停止持续回连。
        let reconnectTask = reconnectTasks.values.first { task in
            isSameConnectTarget(
                storedUuid: task.uuid,
                storedName: task.name,
                uuid: peripheral.identifier.uuidString,
                name: peripheral.name ?? ""
            )
        }
        if error.code == 14, let reconnectTask {
            let admission = currentConnectionAdmission(uuid: peripheral.identifier.uuidString)
            let attemptSource = admission?.source ?? reconnectTask.source
            let pairingFailureAction = registerPeerPairingFailure(
                uuid: peripheral.identifier.uuidString,
                name: peripheral.name ?? "",
                source: attemptSource
            )
            let stoppedForPairingFailure = pairingFailureAction == .stopAttempt
            recordNativeTrace(
                uuid: peripheral.identifier.uuidString,
                stage: stoppedForPairingFailure ? "bond" : "disconnect",
                result: stoppedForPairingFailure ? "failed" : "abnormal",
                causeDomain: error.domain,
                causeCode: error.code,
                bondState: stoppedForPairingFailure ? "security_recovery" : nil
            )
            handleConnectState(
                uuid: peripheral.identifier.uuidString,
                name: peripheral.name ?? "",
                state: stoppedForPairingFailure ? .alreadyBound : .disconnectFromSys,
                source: attemptSource,
                generation: admission?.sessionGeneration ?? reconnectTask.sessionGeneration,
                peripheralTerminalAcknowledged: true,
                tag: tag
            )
            let pairingRecoveryLabel = pairingFailureAction?.rawValue ?? "none"
            let mappedStateLabel = stoppedForPairingFailure
                ? BleConnectState.alreadyBound.rawValue
                : BleConnectState.disconnectFromSys.rawValue
            loggerE(msg: "\(logHead) \(peripheral.identifier.uuidString), error code = \(error.code), msg = \(error.localizedDescription), pairingRecovery=\(pairingRecoveryLabel), mapped to \(mappedStateLabel) for autoReconnect")
            return
        }
        if error.code != 14, reconnectTask != nil {
            resetPeerPairingRecoveryAfterNonPairingFailure(
                uuid: peripheral.identifier.uuidString,
                name: peripheral.name ?? ""
            )
        }
        if error.code == 14 {
            recordNativeTrace(
                uuid: peripheral.identifier.uuidString,
                stage: "bond",
                result: "failed",
                causeDomain: error.domain,
                causeCode: error.code,
                bondState: "security_recovery"
            )
            handleConnectState(
                uuid: peripheral.identifier.uuidString,
                name: peripheral.name ?? "",
                state: .alreadyBound,
                peripheralTerminalAcknowledged: true,
                tag: tag
            )
        } else {
            recordNativeTrace(
                uuid: peripheral.identifier.uuidString,
                stage: "disconnect",
                result: "abnormal",
                causeDomain: error.domain,
                causeCode: error.code
            )
            handleConnectState(
                uuid: peripheral.identifier.uuidString,
                name: peripheral.name ?? "",
                state: .disconnectFromSys,
                peripheralTerminalAcknowledged: true,
                tag: tag
            )
        }
        loggerE(msg: "\(logHead) \(peripheral.identifier.uuidString), error code = \(error.code), msg = \(error.localizedDescription)")
    }
    
    /**
     *  更新缓存设备数据
     */
    private func updateConnectedDevice(uuid: String,
                                       name: String,
                                       writeChars: CBCharacteristic? = nil,
                                       readChars: CBCharacteristic? = nil,
                                       psType: Int = 0,
                                       isConnected: Bool? = nil,
                                       updateByUser: Bool = false,
                                       source: BleConnectSource? = nil,
                                       generation: Int64? = nil,
                                       attemptGeneration: Int64? = nil) {
        //  1、没有缓存就不更新
        guard uuid.isNotEmpty else {
            loggerE(msg: "updateConnectedDevice: \(uuid), empty uuid")
            return
        }
        guard connectedDevices.isNotEmpty else {
            if updateByUser {
                handleConnectState(
                    uuid: uuid,
                    name: name,
                    state: .disconnectByUser,
                    source: source,
                    generation: generation,
                    attemptGeneration: attemptGeneration,
                    tag: "cancel with empty connectedDevices cache"
                )
            }
            loggerE(msg: "updateConnectedDevice: \(uuid), not found device")
            return
        }

        //  2、获取缓存设备
        guard  let index = connectedDevices.firstIndex(where: { device in
            device.peripheral.identifier.uuidString == uuid || device.peripheral.name == name
        }) else {
            handleConnectState(
                uuid: uuid,
                name: name,
                state: updateByUser ? .disconnectByUser : .disconnectFromSys,
                source: source,
                generation: generation,
                attemptGeneration: attemptGeneration
            )
            loggerE(msg: "updateConnectedDevice: \(uuid), no cache device object")
            return
        }
        //  3、更新缓存设备信息
        var connectedDevice = connectedDevices[index]
        let shouldCheckBleFlow = writeChars != nil || readChars != nil
        //  - 设置写
        if let writeChars = writeChars {
            connectedDevice.writeCharsDic[psType] = writeChars
        }
        //  - 设置读
        if let readChars = readChars {
            connectedDevice.readCharsDic[psType] = readChars
            //  CoreBluetooth 恢复/缓存路径可能已经处于 notifying，不一定再触发一次回调。
            if readChars.isNotifying {
                connectedDevice.notifiedReadCharUUIDs.insert(readChars.uuid.uuidString)
                connectedDevice.readCharsNotify = connectedDevice.notifiedReadCharUUIDs.count
                loggerD(msg: "updateConnectedDevice: \(uuid), read char already notifying, char=\(readChars.uuid.uuidString), notifyProgress=\(connectedDevice.readCharsNotify)")
            } else {
                //  - 开始订阅读特征变化值，即开启接收设备数据
                connectedDevice.peripheral.setNotifyValue(true, for: readChars)
            }
        }
        //  - 设置连接状态
        var reportedState: BleConnectState?
        if let isConnected = isConnected {
            connectedDevice.isConnected = isConnected
            reportedState = isConnected
                ? .connected
                : (updateByUser ? .disconnectByUser : .disconnectFromSys)
        }

        // 所有缓存字段必须在状态上报前一次性提交。`handleConnectState(.connected)` 会释放
        // admission Gate 并可能同步启动下一 endpoint 的 pipeline；后者会重排
        // connectedDevices，因此不能跨状态上报继续持有本次查到的数组 index。
        connectedDevices[index] = connectedDevice
        if let reportedState = reportedState {
            handleConnectState(
                uuid: uuid,
                name: name,
                state: reportedState,
                source: source,
                generation: generation,
                attemptGeneration: attemptGeneration
            )
        }
        loggerD(msg: "updateConnectedDevice: \(uuid), state = \(connectedDevice.peripheral.state), device = \(connectedDevice.toString())")
        if shouldCheckBleFlow {
            tryEmitConnectFinish(uuid: uuid, name: name, bleConfig: connectedDevice.belongConfig, tag: "updateConnectedDevice")
        }
    }

    private func tryEmitConnectFinish(uuid: String, name: String, bleConfig: BleConfig, tag: String) {
        guard let connectedIndex = connectedDevices.firstIndex(where: { device in
            device.peripheral.identifier.uuidString == uuid || device.peripheral.name == name
        }) else {
            loggerE(msg: "connect-flow readiness: \(uuid)-\(name), no cache device object")
            return
        }
        guard isCurrentConnectionPipeline(connectedDevices[connectedIndex].peripheral) else {
            return
        }
        var connectedDevice = connectedDevices[connectedIndex]
        connectedDevice.readCharsNotify = connectedDevice.notifiedReadCharUUIDs.count
        connectedDevices[connectedIndex] = connectedDevice
        let readiness = BleGattReadiness.make(device: connectedDevice, config: bleConfig)
        loggerD(msg: "gatt/notifyReady: \(uuid)-\(name), \(readiness.summary), tag=\(tag)")
        if readiness.isComplete, !connectedDevice.isConnected, !connectedDevice.isBleFlowCompleted {
            connectedDevice.isBleFlowCompleted = true
            connectedDevices[connectedIndex] = connectedDevice
            let mtu = getDeviceMTU(peripheral: connectedDevice.peripheral)
            let writeLimit = connectedDevice.peripheral.maximumWriteValueLength(for: .withoutResponse)
            recordNativeTrace(
                uuid: connectedDevice.peripheral.identifier.uuidString,
                stage: "mtu",
                result: "not_observable",
                writeLimitBytes: writeLimit
            )
            recordNativeTrace(uuid: connectedDevice.peripheral.identifier.uuidString, stage: "gatt_ready", result: "success")
            startNativeTraceRssiSampling(peripheral: connectedDevice.peripheral)
            handleConnectState(uuid: connectedDevice.peripheral.identifier.uuidString, name: connectedDevice.peripheral.name ?? name, state: .connectFinish, mtu: mtu, tag: tag)
            loggerD(msg: "connect-flow readiness: \(connectedDevice.peripheral.identifier.uuidString), connect finish, writeCharsCount = \(connectedDevice.writeCharsDic.keys.count), ps = \(bleConfig.privateServices.count), tag=\(tag)")
        }
    }
    
    /**
     *  连接状态处理与队列管理
     */
    func handleConnectState(
        uuid: String,
        name: String,
        state: BleConnectState,
        mtu: Int = 247,
        source: BleConnectSource? = nil,
        generation: Int64? = nil,
        attemptGeneration: Int64? = nil,
        peripheralTerminalAcknowledged: Bool = false,
        systemAutoReconnectInProgress: Bool = false,
        suppressReconnectSchedule: Bool = false,
        tag: String = ""
    ) {
        let fromTag = "\(tag.isNotEmpty ? " -- from: \(tag)" : "\"\"")"
        // source 必须在 Gate release 前快照，否则 terminal/connected 事件会丢失本轮来源。
        let currentAdmission = currentConnectionAdmission(uuid: uuid)
        let currentDevice = connectedDevices.first(where: { device in
            isSameConnectTarget(
                storedUuid: device.peripheral.identifier.uuidString,
                storedName: device.peripheral.name ?? "",
                uuid: uuid,
                name: name
            )
        })
        let reconnectTask = reconnectTasks.values.first(where: { task in
            isSameConnectTarget(
                storedUuid: task.uuid,
                storedName: task.name,
                uuid: uuid,
                name: name
            )
        })
        let terminalMetadata = BleTerminalConnectionMetadataPolicy.resolve(
            state: state,
            currentAdmission: currentAdmission,
            reconnectTask: reconnectTask
        )
        let eventSource = source ?? terminalMetadata?.source ?? .unknown
        let eventGeneration = generation ?? terminalMetadata?.generation ?? 0
        let eventAttemptGeneration = attemptGeneration ?? terminalMetadata?.attemptGeneration ?? currentAdmission?.generation ?? 0
        recordNativeTraceForState(uuid: uuid, state: state)
        if currentAdmission == nil,
           source == nil,
           generation == nil,
           let terminalMetadata = terminalMetadata {
            loggerD(msg: "connect-flow: \(uuid)-\(name), reuse business-connected terminal epoch, state=\(state.rawValue), source=\(terminalMetadata.source.rawValue), generation=\(terminalMetadata.generation), attemptGeneration=\(terminalMetadata.attemptGeneration)")
        }
        if state == .disconnectFromSys,
           currentAdmission == nil,
           source == nil,
           generation == nil,
           terminalMetadata == nil {
            // 终态绝不能静默退化：保留 task 与缓存快照，便于定位 identity/task 被错误
            // 清除的路径；Dart 侧仍会严格拒绝 unknown/0，避免迟到回调污染新会话。
            loggerE(msg: "connect-flow: \(uuid)-\(name), missing terminal epoch, cachedConnected=\(currentDevice?.isConnected == true), taskFound=\(reconnectTask != nil), taskGeneration=\(reconnectTask?.lastConnectedGeneration ?? 0), taskAttemptGeneration=\(reconnectTask?.lastConnectedAttemptGeneration ?? 0), taskSource=\(reconnectTask?.source.rawValue ?? "unknown")")
        }
        if state == .disconnectByUser {
            cancelReconnectTask(uuid: uuid, name: name)
        }
        //  1、超时定时器处理
        //  - 缓存中有定时器数据
        //  - 失败或者连接成功就要停止（即非连接状态）
        if let index = connectingTimeoutTimers.firstIndex(where: { info in
            isSameActiveConnectTarget(storedUuid: info.0, storedName: info.1, uuid: uuid, name: name)
        }), !state.isConnecting() {
            //  -- 1.1、移除定时器
            let timer = connectingTimeoutTimers[index]
            timer.2.invalidate()
            connectingTimeoutTimers.remove(at: index)
            loggerD(msg: "connect-flow: \(uuid)-\(name), state = \(state.rawValue), stop connect timer, tag = \(fromTag)")
        }
        if !state.isConnecting() {
            cancelScanConnectTimeout(uuid: uuid, name: name)
        }
        var deferredAdmissionTeardown = false
        //  2、设备连接状态为失败或断连就要设置连接设备连接状态为false
        let cacheIndexes = connectionCacheIndexes(uuid: uuid, name: name)
        if state.isError() || state.isDisconnected(), cacheIndexes.isNotEmpty {
            // 历史版本可能因 retrieve 返回不同对象而留下同 UUID 多条缓存。
            // 终态必须失效全部条目，不能只更新第一条后让回连看到另一条假已连接记录。
            for index in cacheIndexes {
                var device = connectedDevices[index]
                device.isConnected = false
                device.isBleFlowCompleted = false
                //  异常断连标记：下次重连前需先扫描刷新 CoreBluetooth 缓存
                //  - disconnectFromSys：系统异常断连，CoreBT peripheral 元数据可能 stale
                //  - timeout：connect() 静默无反应，同样是 CoreBT 缓存问题的典型表现
                if state == .disconnectFromSys || state == .timeout {
                    device.needsScanBeforeReconnect = true
                }
                for (_, readChar) in device.readCharsDic {
                    device.peripheral.setNotifyValue(false, for: readChar)
                }
                device.readCharsNotify = 0
                device.notifiedReadCharUUIDs.removeAll()
                connectedDevices[index] = device
            }
            let device = currentDevice ?? connectedDevices[cacheIndexes[0]]
            if let currentAdmission = currentAdmission,
               !peripheralTerminalAcknowledged,
               device.peripheral.state != .disconnected {
                // service/char/timeout/user-cancel 都必须等 CoreBluetooth 真正 teardown 后
                // 才释放 Gate；否则下一 endpoint 会与旧 cancel 在 HCI 上重叠。
                deferConnectionAdmissionReleaseUntilPeripheralTerminal(
                    admission: currentAdmission,
                    peripheral: device.peripheral,
                    deviceName: device.peripheral.name ?? name,
                    terminalState: state
                )
                deferredAdmissionTeardown = true
            }
            if !systemAutoReconnectInProgress {
                centralManager.cancelPeripheralConnection(device.peripheral)
            }
            //  断连/错误状态: 取消该外设的 OTA 写队列, 避免 Dart 端 await 挂起
            let queueKey = device.peripheral.identifier.uuidString
            if let queue = otaWriteQueues.removeValue(forKey: queueKey) {
                queue.cancelAll(reason: "device state=\(state.rawValue)")
            }
            loggerD(msg: "connect-flow: \(uuid)-\(name), state = \(state), cacheEntries=\(cacheIndexes.count), tag = \(fromTag)")
        }
        // 3. 已收到 didFail/didDisconnect（或外设本就 disconnected）才可以同步释放；
        //    其余终态由 cancellation barrier callback/watchdog 完成 release/start-next。
        if (state.isError() || state.isDisconnected()),
           let currentAdmission = currentAdmission,
           !deferredAdmissionTeardown {
            releaseConnectionAdmissionAndStartNext(currentAdmission, invalidateEndpoint: true)
        }

        //  4、发送连接状态
        sendConnectStateToFlutter(
            uuid: uuid,
            name: name,
            state: state,
            mtu: mtu,
            source: eventSource,
            generation: eventGeneration,
            attemptGeneration: eventAttemptGeneration
        )
        if state == .connected, let device = connectedDevices.first(where: {
            $0.peripheral.identifier.uuidString == uuid || $0.peripheral.name == name
        }) {
            armReconnectTask(
                device: device,
                source: .autoReconnect,
                businessConnected: true,
                generation: eventGeneration,
                attemptGeneration: eventAttemptGeneration
            )
        }
        if state == .connected {
            // 即使业务设备缓存暂时缺失，正常成功也必须释放本轮 Gate owner。
            completeBusinessConnectionAdmission(uuid: uuid)
        } else if (state.isError() || state.isDisconnected()) && !deferredAdmissionTeardown {
            // admission 已在上方释放；再移除旧 request owner 后才允许创建下一代。
            // 若反过来调度，scheduleReconnect 会命中旧 active request 并永久 defer。
            removeActiveConnectRequest(uuid: uuid, name: name)
            loggerD(msg: "connect-flow: \(uuid)-\(name), terminal cleanup before reconnect schedule, tag = \(fromTag)")
            if systemAutoReconnectInProgress, let peripheral = currentDevice?.peripheral {
                adoptSystemAutoReconnect(peripheral, name: name)
                return
            }
            if suppressReconnectSchedule {
                loggerD(msg: "connect-flow: \(uuid)-\(name), native reconnect schedule suppressed, tag=\(fromTag)")
                return
            }
            if state != .alreadyBound {
                resetPeerPairingRecoveryAfterNonPairingFailure(
                    uuid: uuid,
                    name: name
                )
            }
            scheduleReconnect(uuid: uuid, name: name, state: state)
            return
        }
        //  5、连接流程中的状态处理
        guard !state.isConnecting() else {
            //  connectFinish 表示 BLE 物理连接流程完成，移除当前请求缓存。
            //  超时定时器保留运行，作为协议层鉴权的安全兜底。
            if state == .connectFinish {
                removeActiveConnectRequest(uuid: uuid, name: name)
                loggerD(msg: "connect-flow: \(uuid)-\(name), connectFinish, remove active request, tag = \(fromTag)")
            }
            return
        }
        //  6、非连接流程状态：移除当前请求缓存，不再由 native 推进其它设备。
        removeActiveConnectRequest(uuid: uuid, name: name)
        loggerD(msg: "connect-flow: \(uuid)-\(name), state = \(state), remove active request, tag = \(fromTag)")
    }
    
    /**
     * 获取设备的 MTU 值
     */
    private func getDeviceMTU(peripheral: CBPeripheral) -> Int {
        // 方法1: 通过 maximumWriteValueLength 获取 (推荐)
        let maxWriteLength = peripheral.maximumWriteValueLength(for: .withoutResponse)
        let attMTU = maxWriteLength + 3  // ATT_MTU = 数据载荷 + 3字节ATT头部
        loggerD(msg: "\(peripheral.identifier.uuidString), mtu = \(attMTU), max write length = \(maxWriteLength)")
        return attMTU
    }

    /// CoreBluetooth exposes security failures, but not the current bond state.
    /// Keep this evidence list explicit so ordinary GATT failures never become
    /// false pairing diagnoses.
    private func isBondSecurityError(_ error: NSError) -> Bool {
        if error.domain == CBErrorDomain,
           error.code == CBError.Code.peerRemovedPairingInformation.rawValue {
            return true
        }
        guard error.domain == CBATTErrorDomain else { return false }
        return [
            CBATTError.Code.insufficientAuthentication.rawValue,
            CBATTError.Code.insufficientAuthorization.rawValue,
            CBATTError.Code.insufficientEncryptionKeySize.rawValue,
            CBATTError.Code.insufficientEncryption.rawValue,
        ].contains(error.code)
    }

    /// Security evidence can arrive from service, characteristic, CCCD, or value callbacks.
    /// It records pairing recovery without claiming that CoreBluetooth exposes bond state.
    private func recordBondSecurityFailureIfNeeded(peripheral: CBPeripheral, error: NSError) {
        guard isBondSecurityError(error) else { return }
        recordNativeTrace(
            uuid: peripheral.identifier.uuidString,
            stage: "bond",
            result: "failed",
            causeDomain: error.domain,
            causeCode: error.code,
            bondState: "security_recovery"
        )
    }
    
    /**
     * 发送连接状态
     */
    private func sendConnectStateToFlutter(
        uuid: String,
        name: String,
        state: BleConnectState,
        mtu: Int,
        source: BleConnectSource,
        generation: Int64,
        attemptGeneration: Int64
    ) {
        let connectModel = BleConnectModel(
            uuid: uuid,
            name: name,
            connectState: state,
            mtu: mtu,
            source: source,
            generation: generation,
            attemptGeneration: attemptGeneration,
            nativeTrace: nativeTraceSnapshot(uuid: uuid)
        )
        let jsonString = try? connectModel.toJsonString() ?? ""
        loggerD(msg: "connectStatus -> Flutter: \(uuid)-\(name), state=\(state.rawValue), mtu=\(mtu), source=\(source.rawValue), generation=\(generation), attemptGeneration=\(attemptGeneration)")
        BleEC.connectStatus.emit(jsonString)
    }
    
    /**
     * Logger d
     */
    func loggerD(msg: String) {
        BleEC.logger.emit("[d]-BleManage::\(msg)")
    }
    
    /**
     * Logger e
     */
    func loggerE(msg: String) {
        BleEC.logger.emit("[e]-BleManage::\(msg)")
    }
}


// MARK: - CBCentralManagerDelegate
extension BleManager: CBCentralManagerDelegate {
 
    /**
     *  蓝牙状态监听
     */
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        BleEC.bleState.emit(central.state.rawValue)
        //  1、如果蓝牙状态不是开启，则将所有已连接的设备设置为非连接状态
        if central.state != .poweredOn {
            // admission/task 元数据必须先冻结；后续 Gate teardown 会清空当前 generation。
            let transportOffSnapshots = bluetoothOffConnectionSnapshots()
            pauseReconnectTasksForBluetoothOff()
            suspendConnectionAdmissionGateForBluetoothOff()
            //  - 1.1、移除所有升级设备，避免退出OTA时，重置会连接状态的设备
            upgradeStateRegistry.clear()
            //  - 1.2、系统级蓝牙关闭：把连接中/已连接端点标记为 .disconnectFromSys，
            //         让 Dart 状态机先退出陈旧连接态；长期回连 task 仍由 native 暂停并在恢复后继续。
            //         ⚠️ 不能用 .bleError / .disconnectByUser：
            //            - .bleError 落在 isError 但不在重连白名单 isConnectError 里
            //            - .disconnectByUser 是用户主动断连语义
            //            两者都不会触发重连，BLE 关再开后会有部分设备（典型如戒指）永远不重连。
            transportOffSnapshots.forEach { snapshot in
                handleConnectState(
                    uuid: snapshot.uuid,
                    name: snapshot.name,
                    state: .disconnectFromSys,
                    source: snapshot.source,
                    generation: snapshot.generation,
                    attemptGeneration: snapshot.attemptGeneration
                )
            }
            //  - 1.3、清除缓存
            startConnectInfos.removeAll()
            activeConnectRequests.removeAll()
            preConnectedDevices.removeAll()
            connectingTimeoutTimers.forEach { (uuid, name, timer) in
                timer.invalidate()
            }
            connectingTimeoutTimers.removeAll()
            scanConnectTimeoutTimers.forEach { (uuid, name, timer) in
                timer.invalidate()
            }
            scanConnectTimeoutTimers.removeAll()
        } else {
            resumeConnectionAdmissionGateAfterBluetoothOn()
            resumeReconnectTasksAfterBluetoothOn()
        }
        loggerD(msg: "centralManagerDidUpdateState: State = \(central.state.label), code = \(central.state.rawValue)")
    }
    
    /**
     * 设备发现回调。
     *
     * 这里仅做 CoreBluetooth delegate 转发；扫描解析、SN/MAC 规则、matchCount 聚合和
     * scan-then-connect 命中都由 `BleScanPipeline` 承担。
     */
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        // 1. 保持 delegate 层极薄，扫描领域逻辑全部下沉到 BleScanPipeline。
        handleDiscoveredPeripheral(peripheral, advertisementData: advertisementData, rssi: RSSI)
    }
    
    func centralManager(_ central: CBCentralManager, didUpdateANCSAuthorizationFor peripheral: CBPeripheral) {
        loggerE(msg: "didUpdateANCSAuthorizationFor")
    }
    
    func centralManager(_ central: CBCentralManager, connectionEventDidOccur event: CBConnectionEvent, for peripheral: CBPeripheral) {
        loggerE(msg: "connectionEventDidOccur: event = \(event.rawValue)")
    }
    
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, timestamp: CFAbsoluteTime, isReconnecting: Bool, error: (any Error)?) {
        loggerE(msg: "didDisconnectPeripheral: timestamp = \(timestamp), isReconnecting = \(isReconnecting), error = \(String(describing: error))")
        if consumePeripheralCancellationBarrier(peripheral) { return }
        if isReconnecting {
            // 系统已持有 reconnect 时只结束旧业务 session 并重建 admission；再次 connect/cancel
            // 会破坏 CoreBluetooth 的自动回连 rendezvous。
            handleConnectState(
                uuid: peripheral.identifier.uuidString,
                name: peripheral.name ?? "",
                state: .disconnectFromSys,
                peripheralTerminalAcknowledged: true,
                systemAutoReconnectInProgress: isReconnecting,
                tag: "didDisconnectPeripheral(system auto reconnect)"
            )
            return
        }
        handleConnectError(peripheral: peripheral, error: error, formMethod: "didDisconnectPeripheral(timestamp)")
    }
    
    /**
     * 设备连接成功回调
     */
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        let tag = "didConnect"
        // hard cancel 后的旧 didConnect 不能复活已取消 session；继续 cancel 并等终态消费 barrier。
        if hasPeripheralCancellationBarrier(peripheral) {
            centralManager.cancelPeripheralConnection(peripheral)
            loggerD(msg: "admission gate: \(peripheral.identifier.uuidString), stale didConnect blocked by cancellation barrier")
            return
        }
        //  1、检查是否获取到了蓝牙配置
        guard let connectRequest = findActiveConnectRequest(peripheral: peripheral),
              let bleConfig = connectRequest.bleConfig else {
            handleConnectState(uuid: peripheral.identifier.uuidString, name: peripheral.name ?? "", state: .noBleConfigFound, tag: tag)
            return
        }
        //  2、真实 didConnect 只提交 Gate；排队期间不启动 timeout/service discovery。
        loggerD(msg: "didConnect: \(peripheral.identifier.uuidString)-\(peripheral.name ?? ""), requestName=\(connectRequest.name), config=\(bleConfig.name)")
        enqueuePhysicalConnectionThroughGate(peripheral)
    }

    /**
     * 设备连接失败回调
     */
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        if consumePeripheralCancellationBarrier(peripheral) { return }
        handleConnectError(peripheral: peripheral, error: error, formMethod: "didFailToConnect")
    }

    /**
     *  设备断连回调
     */
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        if consumePeripheralCancellationBarrier(peripheral) { return }
        handleConnectError(peripheral: peripheral, error: error, formMethod: "didDisconnectPeripheral")
    }
    
}


// MARK: - CBPeripheralManagerDelegate
extension BleManager: CBPeripheralManagerDelegate, CBPeripheralDelegate {
    
    /**
     *  获取设备更新状态
     */
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        loggerD(msg: "peripheralManagerDidUpdateState: Peripheral manager = \(peripheral.isAdvertising), state = \(peripheral.state.rawValue)")
    }
    
    
    /**
     *  服务发现回调
     */
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        let tag = "didDiscoverSerices"
        processDiscoveredServices(peripheral: peripheral, error: error, tag: tag)
    }
    
    /**
     *  读写特征回调
     */
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        let tag = "didDiscoverCharacteristics"
        processDiscoveredCharacteristics(peripheral: peripheral, service: service, error: error, tag: tag)
    }
    
    /**
     *  特征订阅状态
     */
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        let tag = "didUpdateNotification"
        guard isCurrentConnectionPipeline(peripheral) else { return }
        if let error = error {
            let nsError = error as NSError
            recordNativeTrace(
                uuid: peripheral.identifier.uuidString,
                stage: "cccd",
                result: "failed",
                causeDomain: nsError.domain,
                causeCode: nsError.code
            )
            recordBondSecurityFailureIfNeeded(peripheral: peripheral, error: nsError)
            //  配对授权失败
            if isBondSecurityError(nsError) {
                handleConnectState(uuid: peripheral.identifier.uuidString, name: peripheral.name ?? "", state: .boundFail, tag: tag)
            }
            loggerE(msg: "update notification state: \(peripheral.identifier.uuidString), error = \(error)")
            return
        }
        //  2、获取设备所属蓝牙配置
        guard let bleConfig = findBleConfig(uuid: peripheral.identifier.uuidString, name: peripheral.name ?? "") else {
            handleConnectState(uuid: peripheral.identifier.uuidString, name: peripheral.name ?? "", state: .noBleConfigFound, tag: tag)
            return
        }
        guard characteristic.isNotifying else {
            loggerE(msg: "update notification state: \(peripheral.identifier.uuidString), error = no notifying")
            return
        }
        //  当全部的Uuids特征信息全部获取完,且设备未连接，则发送连接流程完成
        guard let connectedIndex = connectedDevices.firstIndex(where: { device in
            device.peripheral.identifier.uuidString == peripheral.identifier.uuidString
        }) else {
            loggerE(msg: "update notification state: \(peripheral.identifier.uuidString), error = no notifying")
            return
        }
        var connectedDevice = connectedDevices[connectedIndex]
        let characteristicUUID = characteristic.uuid.uuidString
        if connectedDevice.notifiedReadCharUUIDs.contains(characteristicUUID) {
            loggerD(msg: "update notification state: \(peripheral.identifier.uuidString)-\(peripheral.name ?? ""), char=\(characteristicUUID), duplicate notify ignored")
            tryEmitConnectFinish(uuid: peripheral.identifier.uuidString, name: peripheral.name ?? "", bleConfig: bleConfig, tag: "\(tag) duplicate")
            return
        }
        connectedDevice.notifiedReadCharUUIDs.insert(characteristicUUID)
        connectedDevice.readCharsNotify = connectedDevice.notifiedReadCharUUIDs.count
        connectedDevices[connectedIndex] = connectedDevice
        recordNativeTrace(uuid: peripheral.identifier.uuidString, stage: "cccd", result: "success")
        tryEmitConnectFinish(uuid: peripheral.identifier.uuidString, name: peripheral.name ?? "", bleConfig: bleConfig, tag: tag)

    }
    
    /**
     *  WriteWithoutResponse 背压解除回调
     *  - CoreBluetooth 通知该外设可继续接收无应答写入, 把信号转发到对应的 OTA 写队列继续 pump.
     */
    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        let uuid = peripheral.identifier.uuidString
        guard let queue = otaWriteQueues[uuid] else {
            return
        }
        queue.onPeripheralReadyToSendWriteWithoutResponse()
    }

    /// RSSI samples are trace diagnostics only; they do not emit an independent event.
    func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        let uuid = peripheral.identifier.uuidString
        let key = reconnectKey(uuid: uuid)
        let inFlightAttemptId = nativeTraceRssiInFlightAttemptIds.removeValue(forKey: key)
        guard connectionTraceEnabled,
              let trace = nativeConnectionTraces[key],
              trace.attemptId == inFlightAttemptId else {
            return
        }
        if let error = error {
            let nsError = error as NSError
            loggerE(msg: "connection trace RSSI: \(uuid), read failed domain=\(nsError.domain), code=\(nsError.code)")
            return
        }
        trace.updateRssi(RSSI.intValue)
    }

    /**
     *  获取设备下发指令数据
     */
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil else {
            if let nsError = error as NSError? {
                recordBondSecurityFailureIfNeeded(peripheral: peripheral, error: nsError)
            }
            loggerE(msg: "cmd response: \(peripheral.identifier.uuidString), error = \(String(describing: error))")
            return
        }
        //  1、检查是否有应答数据
        guard let data = characteristic.value else {
            loggerE(msg: "cmd response: \(peripheral.identifier.uuidString), error = No data")
            return
        }
        //  2、设备是否存在并连接中
        guard let device = connectedDevices.first(where: { device in
            device.peripheral.identifier.uuidString == peripheral.identifier.uuidString
        }) else {
            loggerE(msg: "cmd response: \(peripheral.identifier.uuidString), device had already disconnected")
            return
        }
        //  3、获取对应的私有服务类型
        guard let privateService = device.belongConfig.privateServices.first(where: { uuid in
            uuid.readCharUUID == characteristic.uuid
        }) else {
            loggerE(msg: "cmd response: \(peripheral.identifier.uuidString), can not find chars")
            return
        }
        //  4、发送指令到flutter
        let bleCmdMap = BleCmd(uuid: peripheral.identifier.uuidString, psType: privateService.type, data: data, isSuccess: error == nil).toMap()
        BleEC.receiveData.emit(bleCmdMap)
        loggerD(msg: "cmd response(char): \(peripheral.identifier.uuidString), chars = \(characteristic.uuid.uuidString), data length = \(data.count)")
    }
    
}
