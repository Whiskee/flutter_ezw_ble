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
    private static let restorationIdentifier = "com.fzfstudio.ezwble.central"
    private static let bluetoothCentralBackgroundMode = "bluetooth-central"
    // 缺少后台模式时输出可执行的排障提示，避免开发者误以为 iOS State Restoration 已经生效。
    private static let stateRestorationMissingBluetoothCentralWarning =
        "stateRestoration: WARNING disabled because host Info.plist is missing UIBackgroundModes bluetooth-central. " +
        "If you expect iOS background reconnect or CoreBluetooth State Restoration, add UIBackgroundModes -> bluetooth-central to Runner/Info.plist."

    /**
     * 当前宿主是否声明了 CoreBluetooth State Restoration 所需的后台模式。
     *
     * iOS 会在 `CBCentralManagerOptionRestoreIdentifierKey` 与缺失
     * `UIBackgroundModes.bluetooth-central` 同时出现时直接抛 NSException。
     * 插件必须先检查宿主 Info.plist；未声明时降级为普通前台 central manager，
     * 让 App 至少能正常启动并使用前台 BLE。
     */
    private static var canEnableStateRestoration: Bool {
        let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String]
        return modes?.contains(bluetoothCentralBackgroundMode) == true
    }

    /**
     * 构造 CBCentralManager 初始化参数。
     *
     * 只有宿主显式声明 `bluetooth-central` 后才传 restore identifier；否则返回 nil，
     * 避免系统异常，同时保留扫描、连接和前台自动回连能力。
     */
    private static func centralManagerOptions() -> [String: Any]? {
        guard canEnableStateRestoration else {
            return nil
        }
        return [
            CBCentralManagerOptionRestoreIdentifierKey: restorationIdentifier
        ]
    }
    
    //  =========== Constants
    //  - 蓝牙管理工具
    var centralManager: CBCentralManager!
    //  - 缓存已连接的设备
    lazy var connectedDevices: [BleConnectedDevice] = []
    
    //  =========== Variables
    //  - 当前蓝牙基础配置，必须实现
    lazy var bleConfigs: [BleConfig] = []
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
    //  - iOS native passive reconnect 观察定时器集合(UUID, Name, 倒计时定时器)
    private lazy var passiveReconnectWatchdogTimers: [(String, String, Timer)] = []
    //  - 是否正在升级中
    lazy var upgradeDevices: [String]? = nil
    //  - 预连接设备集合（使用uuid作为key）
    lazy var preConnectedDevices: Set<String> = []
    //  - OTA WriteWithoutResponse 写队列(key: peripheral.identifier.uuidString)
    //  - 仅在 sendCmdNoWait + psType==1 路径上使用, 详见 docs/IOS_OTA_NOWAIT_SPEC.md §4.2
    private lazy var otaWriteQueues: [String: OtaWriteQueue] = [:]
    //  - 原生自动回连任务，只有业务 connected 后才会加入
    lazy var reconnectTasks: [String: BleReconnectTask] = [:]
    //  - iOS 报 Code=14 后等待新广播的恢复请求。旧 CBPeripheral 的配对安全上下文
    //    已失效，必须在 scan 命中新广播前阻止 passive reconnect 继续复用旧对象。
    lazy var peerPairingRecoveryRequests: [String: BleEasyConnect] = [:]
    let reconnectStore = BleReconnectStore()
    let restorationCoordinator = BleStateRestorationCoordinator()
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
     * 初始化顺序必须先根据宿主 Info.plist 决定是否启用 State Restoration，再创建
     * `CBCentralManager`；如果缺少 `bluetooth-central` 却传入 restore identifier，
     * iOS 会在 App 启动阶段直接抛 NSException，Flutter 层没有机会兜底。
     */
    private override init() {
        super.init()
        let options = BleManager.centralManagerOptions()
        self.centralManager = CBCentralManager(
            delegate: self,
            queue: nil,
            options: options
        )
        if options == nil {
            loggerE(msg: BleManager.stateRestorationMissingBluetoothCentralWarning)
        } else {
            loggerD(msg: "stateRestoration: enabled restore id=\(BleManager.restorationIdentifier)")
        }
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
    }

}

// MARK: - Public Methods
extension BleManager {

    /**
     *  设置蓝牙配置。
     *
     *  Flutter 会在启动、热重启、State Restoration 恢复后调用该方法。这里必须只做
     *  同步赋值，不能把恢复连接/GATT 初始化放在 MethodChannel 调用栈里执行，否则
     *  Dart 的 `await initConfigs` 会阻塞首帧，表现为 App 停在启动阶段并触发 hang 日志。
     */
    func initConfigs(configs: [BleConfig]) {
        self.bleConfigs = configs
        // MethodChannel 调用必须尽快返回 Flutter。State Restoration / auto reconnect
        // 可能同步进入 GATT pipeline，放到下一轮主队列避免阻塞首帧和 Dart await。
        DispatchQueue.main.async { [weak self] in
            // 配置已可用后再重放 restored peripherals；此时才能根据 belongConfig
            // 找到私有服务和 notify 初始化规则。
            self?.flushPendingRestoredPeripherals()
            // 蓝牙已恢复但任务被 poweredOff 暂停时，在配置就绪后补偿恢复。
            self?.resumeReconnectTasksIfBluetoothOn(reason: "initConfigs")
        }
    }

    /**
     *  读取并清空原生自动回连/State Restoration 期间的持久化事件。
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
           let peripheral = centralManager.retrievePeripherals(withIdentifiers: [cbUuid]).first,
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
    func setConnected(uuid: String) {
        guard checkIsFunctionCanBeCalled() else {
            return
        }
        if !preConnectedDevices.contains(uuid) {
            loggerE(msg: "setConnected: \(uuid) connected failed, not pre-connected")
            return
        }
        loggerD(msg: "setConnected: \(uuid) connected")
        //  移除预连接状态
        preConnectedDevices.remove(uuid)
        let connectedDevice = connectedDevices.first(where: { device in
            device.peripheral.identifier.uuidString == uuid
        })
        if let connectedDevice = connectedDevice {
            persistReconnectTarget(device: connectedDevice)
        }
        updateConnectedDevice(uuid: uuid, name: connectedDevice?.peripheral.name ?? "", isConnected: true)
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
    func disconnect(uuid: String, name: String) {
        cancelReconnectTask(uuid: uuid, name: name)
        removePersistedReconnectTarget(uuid: uuid, name: name)
        //  1、移除预连接状态（uuid 为空则为 no-op，但保留以兼容旧路径）
        preConnectedDevices.remove(uuid)
        //  注意：不要在此处调用 removeActiveConnectRequest；需先按 uuid/name 命中 in-flight 或
        // 未完成连接的外设（见 findUnfinishedConnectDevice），否则 Dart 空 uuid + 名称取消无法关联到 CB 外设。

        //  2、命中"in-flight scan-then-connect"请求：connect(easyConnect:) 在本地未找到 peripheral 时
        //     生成 temp-UUID 并追加到 startConnectInfos；此时还没有 connectedDevices / CBPeripheral，
        //     必须主动撤回 scan 触发器并通知 Dart 层。仅在字段非空时比较，避免空 uuid 误命中其他请求。
        let inFlightInfos = startConnectInfos.filter { info in
            (!uuid.isEmpty && info.uuid == uuid) || (!name.isEmpty && info.name == name)
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
                handleConnectState(uuid: info.uuid, name: info.name, state: .disconnectByUser, tag: "cancel in-flight by user")
            }
            loggerD(msg: "disconnect: cancelled in-flight scan/connect for \(uuid.isEmpty ? "(no-uuid)" : uuid)-\(name), removed \(inFlightInfos.count) item(s)")
            return
        }

        //  2.5、命中 activeConnectRequest + 连接超时定时器，但尚未写入 connectedDevices 的 in-flight GATT connect。
        if let request = findActiveConnectRequest(uuid: uuid, name: name) {
            let hasTimer = connectingTimeoutTimers.contains { $0.0 == request.uuid || $0.1 == request.name }
            if hasTimer, findUnfinishedConnectDevice(uuid: uuid, name: name) == nil {
                if let match = scanResultTemp.first(where: { info in
                    (!request.uuid.isEmpty && !request.uuid.hasPrefix("temp-") && info.0.uuid == request.uuid) ||
                    (!request.name.isEmpty && (info.0.name == request.name || info.1.name == request.name))
                }) {
                    centralManager.cancelPeripheralConnection(match.1)
                }
                handleConnectState(uuid: request.uuid, name: request.name, state: .disconnectByUser, tag: "cancel active connect by user")
                loggerD(msg: "disconnect: cancelled active connect for \(request.uuid)-\(request.name), by user")
                return
            }
        }

        //  3、命中"已加入 connectedDevices 但尚未 connectFinish"的 peripheral：
        //     例如从蓝牙设置页/已绑定缓存 retrievePeripherals 命中后已 centralManager.connect(...)，
        //     但 didConnect 回调尚未到达。此时 connectedDevices 存在条目但 isConnected=false。
        //     直接走 handleConnectState(.disconnectByUser)：内部会调用 cancelPeripheralConnection
        //     真正中断 in-progress 的 GATT 连接，避免连接挂起到系统超时
        if let inProgressDevice = findUnfinishedConnectDevice(uuid: uuid, name: name) {
            let p = inProgressDevice.peripheral
            let realUuid = p.identifier.uuidString
            let realName = p.name ?? name
            handleConnectState(uuid: realUuid, name: realName, state: .disconnectByUser, tag: "cancel connecting by user")
            loggerD(msg: "disconnect: cancelled connecting peripheral \(realUuid)-\(realName), by user")
            return
        }

        //  4、已建立连接的设备（isConnected == true）：按 uuid / 广播名匹配
        removeActiveConnectRequest(uuid: uuid, name: name)
        let connectedDevice = connectedDevices.first { device in
            device.peripheral.identifier.uuidString == uuid || device.peripheral.name == name
        }
        updateConnectedDevice(uuid: uuid, name: connectedDevice?.peripheral.name ?? "", isConnected: false, updateByUser: true)
        loggerD(msg: "disconnect:\(uuid)-\(name), disconnect by user")
    }
    
    /**
     *
     *  发送数据
     *
     *  - 升级中不允许发送cmd
     *
     */
    func sendCmd(uuid: String, data: Data, psType: Int = 0) {
        guard checkIsFunctionCanBeCalled() else {
            return
        }
        // 如果设备在升级中且不是OTA指令，则不允许发送
        guard upgradeDevices?.contains(where: {$0 == uuid}) != true || psType == 1 else {
            loggerE(msg: "sendCmd: \(uuid), type=\(psType), cannot send non-OTA commands during upgrade")
            return
        }
        //  通过uuid无法查询设备和特征，都被视为查找不到设备
        guard let device = connectedDevices.first(where: { device in
            device.peripheral.identifier.uuidString == uuid
        }), let writeChars = device.writeCharsDic[psType] else {
            loggerE(msg: "sendCmd: \(uuid), type=\(psType), device not found")
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
        //  1、基础校验失败立即回调 nil, 避免 Dart 端 await 挂起
        guard checkIsFunctionCanBeCalled() else {
            result(nil)
            return
        }
        //  2、升级中只放行 OTA 指令(与 sendCmd 保持一致)
        guard upgradeDevices?.contains(where: { $0 == uuid }) != true || psType == 1 else {
            loggerE(msg: "sendCmdNoWait: \(uuid), type=\(psType), cannot send non-OTA commands during upgrade")
            result(nil)
            return
        }
        //  3、设备/特征不存在视为查找不到设备
        guard let device = connectedDevices.first(where: { device in
            device.peripheral.identifier.uuidString == uuid
        }), let writeChars = device.writeCharsDic[psType] else {
            loggerE(msg: "sendCmdNoWait: \(uuid), type=\(psType), device not found")
            result(nil)
            return
        }
        //  4、分发: OTA 走背压队列, 其它走立即返回的 WriteWithoutResponse
        let isOtaChannel = (psType == 1)
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
            //  - 4.2、入队, result 由 pump 写完后回调; canSend 与 queueDepth 落点便于 tuning
            loggerD(msg: "[ota] write uuid=\(uuid) bytes=\(data.count) canSend=\(device.peripheral.canSendWriteWithoutResponse) queueDepth=\(queue.queueDepth)")
            queue.enqueue(data: data, characteristic: writeChars, result: result)
        } else {
            //  - 4.3、兜底: OTA 特征不声明 writeWithoutResponse 时打 warn 后回退
            if isOtaChannel && !supportsNoResponse {
                loggerE(msg: "[ezw_ble][warn] OTA characteristic missing writeWithoutResponse property, fallback to existing path uuid=\(uuid)")
            }
            //  - 4.4、保持现有 sendCmd 行为: WriteWithoutResponse 立即返回, 不做背压
            device.peripheral.writeValue(data, for: writeChars, type: .withoutResponse)
            loggerD(msg: "sendCmdNoWait: \(uuid), type=\(psType), writeChars=\(writeChars.uuid.uuidString), data length=\(data.count)")
            result(nil)
        }
    }

    /**
     *  进入升级模式
     */
    func enterUpgradeState(uuid: String) {
        guard upgradeDevices?.contains(where: {$0 == uuid}) != true else {
            return
        }
        upgradeDevices?.append(uuid)
        let connectedDevice = connectedDevices.first(where: { $0.peripheral.identifier.uuidString == uuid })
        handleConnectState(uuid: uuid, name: connectedDevice?.peripheral.name ?? "", state: .upgrade)
        loggerD(msg: "enterUpgradeState: \(uuid), enter upgrade state")
    }
    
    /**
     *  退出升级模式
     */
    func quiteUpgradeState(uuid: String) {
        guard upgradeDevices?.contains(where: {$0 == uuid}) == true else {
            return
        }
        upgradeDevices?.removeAll(where: { $0 == uuid })
        let connectedDevice = connectedDevices.first(where: { $0.peripheral.identifier.uuidString == uuid })
        handleConnectState(uuid: uuid, name: connectedDevice?.peripheral.name ?? "", state: .connected)
        loggerD(msg: "quiteUpgradeState(\(uuid)): Had Quite upgrade state")
    }
    
    /**
     * 清除连接缓存
     */
    func cleanConnectCache() {
        //  1、清理当前连接请求和搜索连接信息。
        activeConnectRequests.removeAll()
        startConnectInfos.removeAll()
        peerPairingRecoveryRequests.removeAll()
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
        cancelAllNativePassiveReconnectWatchdogs()
    }
    
    /**
     * 重置
     */
    func reset() {
        stopScan()
        connectedDevices.forEach { device in
            centralManager.cancelPeripheralConnection(device.peripheral)
        }
        connectedDevices.removeAll()
        activeConnectRequests.removeAll()
        startConnectInfos.removeAll()
        peerPairingRecoveryRequests.removeAll()
        connectingTimeoutTimers.forEach { (uuid, name, timer) in
            timer.invalidate()
        }
        connectingTimeoutTimers.removeAll()
        scanConnectTimeoutTimers.forEach { (uuid, name, timer) in
            timer.invalidate()
        }
        scanConnectTimeoutTimers.removeAll()
        cancelAllNativePassiveReconnectWatchdogs()
        upgradeDevices?.removeAll()
        preConnectedDevices.removeAll()
        cancelAllReconnectTasks()
        clearPersistedReconnectTargets()
        //  清空所有 OTA 写队列, 通知 Dart 端 await 立即返回
        otaWriteQueues.values.forEach { $0.cancelAll(reason: "reset") }
        otaWriteQueues.removeAll()
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
    func findPeripheralFromConnected(uuid: String, name: String, serviceUUIDs: [CBUUID])-> CBPeripheral? {
        var queryServices = serviceUUIDs
        if !queryServices.contains(BleManager.ancsServiceUUID) {
            queryServices.append(BleManager.ancsServiceUUID)
        }
        guard !queryServices.isEmpty else { return nil }
        let connectedPeripherals = centralManager.retrieveConnectedPeripherals(withServices: queryServices)
        return connectedPeripherals.first { device in
            device.name == name || device.identifier.uuidString == uuid
        }
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
        var requestIndex = activeConnectRequests.firstIndex(where: { request in
            isSameActiveConnectTarget(
                storedUuid: request.uuid,
                storedName: request.name,
                uuid: uuid,
                name: name
            )
        })
        // Code=14 后 CoreBluetooth 可能为同一物理设备分配新的 identifier。两个 UUID
        // 都是稳定值时，通用 owner 规则不会按名称回退；仅在 pairing-recovery gate 内
        // 允许用非空名称接管旧请求，避免普通同名设备互相覆盖。
        if requestIndex == nil,
           let recoveryIndex = activeConnectRequests.firstIndex(where: { request in
               !name.isEmpty && request.name == name &&
                   isPeerPairingRecoveryActive(uuid: request.uuid, name: request.name)
           }) {
            requestIndex = recoveryIndex
        }
        guard let index = requestIndex else {
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

    /**
     *  处理已经连接的设备
     */
    func handleAlreadyConnected(peripheral: CBPeripheral,  bleConfig: BleConfig, deviceName: String, tag: String = "") {
        //  1、更新连接状态
        handleConnectState(uuid: peripheral.identifier.uuidString, name: peripheral.name ?? "", state: .searchService, tag: tag)
        //  2、更新已连接缓存设备信息
        let uuid = peripheral.identifier.uuidString
        connectedDevices.removeAll { device in
            device.peripheral.identifier.uuidString == uuid || device.peripheral.name == deviceName
        }
        connectedDevices.append(BleConnectedDevice(belongConfig: bleConfig, peripheral: peripheral))
        //  3、获取设备服务
        peripheral.delegate = self
        let services = bleConfig.privateServices.map { $0.serviceUUID }
        let cachedServices = peripheral.services ?? []
        let cachedPrivateServices = cachedServices.filter { service in
            bleConfig.privateServices.contains { $0.serviceUUID == service.uuid }
        }
        loggerD(msg: "connect-flow: \(uuid)-\(peripheral.name ?? deviceName), discover services requested=\(services.map { $0.uuidString }), cached=\(cachedServices.count), cachedMatched=\(cachedPrivateServices.count)/\(bleConfig.privateServices.count), tag=\(tag)")
        if cachedPrivateServices.count == bleConfig.privateServices.count {
            processDiscoveredServices(peripheral: peripheral, error: nil, tag: "\(tag) cached")
        } else {
            peripheral.discoverServices(services)
        }
    }

    private func processDiscoveredServices(peripheral: CBPeripheral, error: Error?, tag: String) {
        //  1、根据条件判断服务是否正常获取
        //  - 1.1、搜索服务出现异常错误
        guard error == nil else {
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

    private func processDiscoveredCharacteristics(peripheral: CBPeripheral, service: CBService, error: Error?, tag: String) {
        //  1、处理错误回调
        guard error == nil else {
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
        updateConnectedDevice(uuid: peripheral.identifier.uuidString, name: peripheral.name ?? "", writeChars: writeChars, readChars: readChars, psType: privateService.type)
        loggerD(msg: "didDiscoverCharacteristicsFor: \(peripheral.identifier.uuidString), psType = \(privateService.type), write = \(writeChars!.uuid.uuidString), read = \(readChars!.uuid.uuidString), tag=\(tag)")
    }
    
    /**
     *  开始连接后，执行连接超时倒计时
     */
    func startConnectingCountdown(currentConfig: BleConfig, uuid: String, name: String, afterUpgrade: Bool, isAuthGrace: Bool = false) {
        //  1、检查是否存在相同的
        guard !connectingTimeoutTimers.contains(where: { info in
            isSameActiveConnectTarget(storedUuid: info.0, storedName: info.1, uuid: uuid, name: name)
        }) else {
            return
        }
        //  2、创建连接超时倒计时定时器
        let timer = Timer.scheduledTimer(withTimeInterval: (currentConfig.connectTimeout + (afterUpgrade ? currentConfig.upgradeSwapTime : 0)) / 1000, repeats: false) { [weak self] timer in
            guard let self = self else { return }
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
                self.startConnectingCountdown(currentConfig: currentConfig, uuid: uuid, name: name, afterUpgrade: afterUpgrade, isAuthGrace: true)
                return
            }
            //  宽限期到期仍未连接(或本就不是预连接) → 强制超时，避免永久卡在 connecting。
            self.handleConnectState(uuid: uuid, name: name, state: .timeout)
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
     *  启动 iOS native passive reconnect 观察 watchdog。
     *
     *  该 watchdog 只观测 pending connect 是否仍被系统持有，不再把等待态改成
     *  timeout。autoReconnect 的产品语义是“用户未主动取消前持续连接中”，因此
     *  CoreBluetooth pending connect 和 Dart/UI 的 connecting 必须保持一致。
     */
    func startNativePassiveReconnectWatchdog(currentConfig: BleConfig, uuid: String, name: String) {
        // 1、同一 endpoint 只保留一个观察 timer，避免重复记录 pending 状态。
        cancelNativePassiveReconnectWatchdog(uuid: uuid, name: name)
        let timeout = currentConfig.connectTimeout / 1000
        let timer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            // 2、timer 触发后先移除自身记录；这是一次性 UI 观测，不做循环重试。
            self.passiveReconnectWatchdogTimers.removeAll { info in
                self.isSameActiveConnectTarget(storedUuid: info.0, storedName: info.1, uuid: uuid, name: name)
            }
            // 3、用户取消、reset 或真实连接已完成时，active request 会消失或设备已 connected。
            guard self.findActiveConnectRequest(uuid: uuid, name: name) != nil else {
                return
            }
            guard self.connectedDevices.first(where: { device in
                device.peripheral.identifier.uuidString == uuid || device.peripheral.name == name
            })?.isConnected != true else {
                return
            }
            // 4、pending connect 仍有效时保持 Dart/UI 的 connecting 状态；真正退出只由
            // 用户取消、蓝牙关闭/reset、真实连接成功或后续 CoreBluetooth 终态驱动。
            self.loggerD(msg: "autoReconnect: \(uuid)-\(name), native passive watchdog observed pending connect, keep connecting")
        }
        passiveReconnectWatchdogTimers.append((uuid, name, timer))
        loggerD(msg: "autoReconnect: \(uuid)-\(name), start native passive watchdog \(Int(timeout * 1000))ms")
    }

    /**
     *  取消单个 native passive reconnect 观察 watchdog。
     */
    func cancelNativePassiveReconnectWatchdog(uuid: String, name: String) {
        // 1、按 active connect owner 语义匹配，兼容 temp UUID / name fallback 阶段。
        passiveReconnectWatchdogTimers = passiveReconnectWatchdogTimers.filter { info in
            let shouldCancel = isSameActiveConnectTarget(storedUuid: info.0, storedName: info.1, uuid: uuid, name: name)
            if shouldCancel {
                info.2.invalidate()
            }
            return !shouldCancel
        }
    }

    /**
     *  取消全部 native passive reconnect 观察 watchdog。
     */
    func cancelAllNativePassiveReconnectWatchdogs() {
        // 1、reset / clean / 蓝牙关闭时必须清掉旧 timer，避免 release 后仍向 Dart 推旧状态。
        passiveReconnectWatchdogTimers.forEach { (_, _, timer) in
            timer.invalidate()
        }
        passiveReconnectWatchdogTimers.removeAll()
    }

    /**
     *  判断目标是否正在等待配对信息清除后的新广播。
     *
     *  iOS Code=14 不是普通链路断连：旧 CBPeripheral 的安全上下文已经失效。
     *  在 fresh advertisement 到来前禁止 auto reconnect 复用它，才能避免一次失败
     *  回调触发下一次 connect/cancel 的高频重入循环。
     */
    func isPeerPairingRecoveryActive(uuid: String, name: String) -> Bool {
        return peerPairingRecoveryRequests.values.contains { request in
            request.uuid == uuid || (!name.isEmpty && request.name == name)
        }
    }

    /**
     *  配对信息重置后的唯一恢复入口。
     *
     *  顺序必须是：先让旧 session 按系统断连收尾，再移除旧 peripheral 缓存，最后
     *  创建 scan-then-connect 请求。继续对旧对象发起 passive connect 只会反复得到
     *  Code=14，也不会给 iOS 重新发起系统配对的机会。
     */
    private func startPeerPairingResetRecovery(
        peripheral: CBPeripheral,
        device: BleConnectedDevice,
        tag: String
    ) {
        let uuid = peripheral.identifier.uuidString
        // 断连回调里的 name 可能暂时为空；优先使用已确认的 reconnect task 名称，确保
        // 新广播可以稳定匹配到这次 scan-first 恢复。
        let peripheralName = peripheral.name ?? ""
        let taskName = reconnectTasks[reconnectKey(uuid: uuid)]?.name ?? ""
        let name = peripheralName.isNotEmpty ? peripheralName : taskName
        guard !isPeerPairingRecoveryActive(uuid: uuid, name: name) else {
            loggerD(msg: "peer pairing reset: \(uuid)-\(name), fresh advertisement recovery already pending")
            return
        }

        var request = BleEasyConnect(
            configName: device.belongConfig.name,
            uuid: uuid,
            name: name,
            afterUpgrade: false,
            directConnect: false,
            time: Date().timeIntervalSince1970
        )
        request.bleConfig = device.belongConfig
        // 先写 gate，再发送 disconnect 状态；scheduleReconnect 会识别该 gate，不能在
        // 本次清理期间再次复用即将被移除的 peripheral。
        peerPairingRecoveryRequests[reconnectKey(uuid: uuid)] = request
        handleConnectState(uuid: uuid, name: name, state: .disconnectFromSys, tag: tag)

        // retrievePeripherals 仍可能返回携带旧 LTK 的对象，恢复连接只能由本轮
        // didDiscover 提供的新广播接管。
        connectedDevices.removeAll { cached in
            cached.peripheral.identifier.uuidString == uuid ||
                (!name.isEmpty && cached.peripheral.name == name)
        }
        startConnectInfos.removeAll { info in
            isSameActiveConnectTarget(
                storedUuid: info.uuid,
                storedName: info.name,
                uuid: uuid,
                name: name
            )
        }
        cancelScanConnectTimeout(uuid: uuid, name: name)

        // 保留原 UUID，并以 name 匹配新的广告；新 identifier 出现后由 scan pipeline
        // 回写 active request，保证后续 GATT 回调能查回正确 BleConfig。
        upsertActiveConnectRequest(request)
        startConnectInfos.append(request)
        startScanConnectTimeout(
            currentConfig: device.belongConfig,
            uuid: request.uuid,
            name: request.name,
            afterUpgrade: false
        )
        startScan()
        loggerD(msg: "peer pairing reset: \(uuid)-\(name), wait fresh advertisement before recovery")
    }

    /**
     *  只有 scan 命中后的新广播才允许解除 Code=14 恢复 gate。
     *
     *  扫描超时仍保留 gate，阻止旧 peripheral 的被动回连；后续显式连接会按自己的
     *  超时状态解除 gate 并创建新的前台尝试。
     */
    func finishPeerPairingResetRecovery(uuid: String, name: String) {
        let removed = peerPairingRecoveryRequests.removeValue(
            forKey: reconnectKey(uuid: uuid)
        ) != nil
        if !removed, !name.isEmpty,
           let key = peerPairingRecoveryRequests.first(where: { $0.value.name == name })?.key {
            peerPairingRecoveryRequests.removeValue(forKey: key)
        }
        loggerD(msg: "peer pairing reset: \(uuid)-\(name), fresh advertisement accepted")
    }

    /**
     *  协调用户显式连接与正在等待新广播的 Code=14 恢复。
     *
     *  扫描尚未结束时重复点击复用已有请求；扫描结束后才允许新的前台请求撤销旧 gate，
     *  避免一次用户操作创建两个竞争同一 peripheral 的 connect owner。
     */
    func prepareExplicitConnectAfterPeerPairingRecovery(uuid: String, name: String) -> Bool {
        guard isPeerPairingRecoveryActive(uuid: uuid, name: name) else {
            return true
        }
        let recoveryScanPending = startConnectInfos.contains { request in
            request.uuid == uuid || (!name.isEmpty && request.name == name)
        }
        guard !recoveryScanPending else {
            loggerD(msg: "peer pairing reset: \(uuid)-\(name), explicit connect reuses pending fresh-advertisement scan")
            return false
        }
        peerPairingRecoveryRequests = peerPairingRecoveryRequests.filter { _, request in
            request.uuid != uuid && (name.isEmpty || request.name != name)
        }
        loggerD(msg: "peer pairing reset: \(uuid)-\(name), previous recovery expired, allow explicit reconnect")
        return true
    }
    
    /**
     *  处理连接失败
     */
    private func handleConnectError(peripheral: CBPeripheral, error: Error?, formMethod: String) {
        //  1、连接识别标签
        let tag = "didDisconnect"
        let logHead = "didFailToConnect-\(formMethod):"
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
                handleConnectState(uuid: peripheral.identifier.uuidString, name: peripheral.name ?? "", state: state, tag: tag)
                loggerE(msg: "\(logHead) \(peripheral.identifier.uuidString), nil error disconnect mapped to \(state.rawValue), bluetooth=\(centralManager.state.label)")
            }
            return
        }
        //  4、错误处理
        //  - 4.1、iOS error 14 表示 pairing 信息失配；autoReconnect 模式下这是可恢复的
        //        系统断连错误，不能进入 alreadyBound 终态，否则会停止持续回连。
        let hasAutoReconnectTask = reconnectTasks.values.contains { task in
            isSameConnectTarget(
                storedUuid: task.uuid,
                storedName: task.name,
                uuid: peripheral.identifier.uuidString,
                name: peripheral.name ?? ""
            )
        }
        if error.code == 14, hasAutoReconnectTask {
            startPeerPairingResetRecovery(peripheral: peripheral, device: myDevice, tag: tag)
            loggerE(msg: "\(logHead) \(peripheral.identifier.uuidString), error code = \(error.code), msg = \(error.localizedDescription), start fresh-advertisement recovery")
            return
        }
        if error.code == 14 {
            handleConnectState(uuid: peripheral.identifier.uuidString, name: peripheral.name ?? "", state: .alreadyBound, tag: tag)
        } else {
            handleConnectState(uuid: peripheral.identifier.uuidString, name: peripheral.name ?? "", state: .disconnectFromSys, tag: tag)
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
                                       updateByUser: Bool = false) {
        //  1、没有缓存就不更新
        guard uuid.isNotEmpty else {
            loggerE(msg: "updateConnectedDevice: \(uuid), empty uuid")
            return
        }
        guard connectedDevices.isNotEmpty else {
            if updateByUser {
                handleConnectState(uuid: uuid, name: name, state: .disconnectByUser, tag: "cancel with empty connectedDevices cache")
            }
            loggerE(msg: "updateConnectedDevice: \(uuid), not found device")
            return
        }

        //  2、获取缓存设备
        guard  let index = connectedDevices.firstIndex(where: { device in
            device.peripheral.identifier.uuidString == uuid || device.peripheral.name == name
        }) else {
            handleConnectState(uuid: uuid, name: name, state: updateByUser ? .disconnectByUser : .disconnectFromSys)
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
        if let isConnected = isConnected {
            connectedDevice.isConnected = isConnected
            //  - 回复连接成功
            if isConnected {
                handleConnectState(uuid: uuid, name: name, state: .connected)
            }
            //  - 发起断连
            else {
                handleConnectState(uuid: uuid, name: name, state: updateByUser ? .disconnectByUser : .disconnectFromSys)
            }
        }
        connectedDevices[index] = connectedDevice
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
        var connectedDevice = connectedDevices[connectedIndex]
        connectedDevice.readCharsNotify = connectedDevice.notifiedReadCharUUIDs.count
        connectedDevices[connectedIndex] = connectedDevice
        let readiness = BleGattReadiness.make(device: connectedDevice, config: bleConfig)
        loggerD(msg: "gatt/notifyReady: \(uuid)-\(name), \(readiness.summary), tag=\(tag)")
        if readiness.isComplete, !connectedDevice.isConnected, !connectedDevice.isBleFlowCompleted {
            connectedDevice.isBleFlowCompleted = true
            connectedDevices[connectedIndex] = connectedDevice
            let mtu = getDeviceMTU(peripheral: connectedDevice.peripheral)
            handleConnectState(uuid: connectedDevice.peripheral.identifier.uuidString, name: connectedDevice.peripheral.name ?? name, state: .connectFinish, mtu: mtu, tag: tag)
            loggerD(msg: "connect-flow readiness: \(connectedDevice.peripheral.identifier.uuidString), connect finish, writeCharsCount = \(connectedDevice.writeCharsDic.keys.count), ps = \(bleConfig.privateServices.count), tag=\(tag)")
        }
    }
    
    /**
     *  连接状态处理与队列管理
     */
    func handleConnectState(uuid: String, name: String, state: BleConnectState, mtu: Int = 247, tag: String = "") {
        let fromTag = "\(tag.isNotEmpty ? " -- from: \(tag)" : "\"\"")"
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
        if state != .connecting {
            // native passive watchdog 只观察「pending connect 无任何 CoreBluetooth 回调」窗口；
            // 一旦进入 didConnect/GATT/终态路径，后续交给普通连接超时和状态机处理。
            cancelNativePassiveReconnectWatchdog(uuid: uuid, name: name)
        }
        //  2、设备连接状态为失败或断连就要设置连接设备连接状态为false
        if state.isError() || state.isDisconnected(), let index = connectedDevices.firstIndex(where: { $0.peripheral.identifier.uuidString == uuid || $0.peripheral.name == name }) {
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
            centralManager.cancelPeripheralConnection(device.peripheral)
            //  断连/错误状态: 取消该外设的 OTA 写队列, 避免 Dart 端 await 挂起
            let queueKey = device.peripheral.identifier.uuidString
            if let queue = otaWriteQueues.removeValue(forKey: queueKey) {
                queue.cancelAll(reason: "device state=\(state.rawValue)")
            }
            loggerD(msg: "connect-flow: \(uuid)-\(name), state = \(state), tag = \(fromTag)")
        }
        //  3、发送连接状态
        sendConnectStateToFlutter(uuid: uuid, name: name, state: state, mtu: mtu)
        if state == .connected, let device = connectedDevices.first(where: {
            $0.peripheral.identifier.uuidString == uuid || $0.peripheral.name == name
        }) {
            armReconnectTask(device: device)
        } else if state.isError() || state.isDisconnected() {
            scheduleReconnect(uuid: uuid, name: name, state: state)
        }
        //  4、连接流程中的状态处理
        guard !state.isConnecting() else {
            //  connectFinish 表示 BLE 物理连接流程完成，移除当前请求缓存。
            //  超时定时器保留运行，作为协议层鉴权的安全兜底。
            if state == .connectFinish {
                removeActiveConnectRequest(uuid: uuid, name: name)
                loggerD(msg: "connect-flow: \(uuid)-\(name), connectFinish, remove active request, tag = \(fromTag)")
            }
            return
        }
        //  5、非连接流程状态：移除当前请求缓存，不再由 native 推进其它设备。
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
    
    /**
     * 发送连接状态
     */
    private func sendConnectStateToFlutter(uuid: String, name: String, state: BleConnectState, mtu: Int) {
        let connectModel = BleConnectModel(uuid: uuid, name: name, connectState: state, mtu: mtu)
        let jsonString = try? connectModel.toJsonString() ?? ""
        loggerD(msg: "connectStatus -> Flutter: \(uuid)-\(name), state=\(state.rawValue), mtu=\(mtu)")
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
            pauseReconnectTasksForBluetoothOff()
            //  - 1.1、移除所有升级设备，避免退出OTA时，重置会连接状态的设备
            upgradeDevices?.removeAll()
            //  - 1.2、系统级蓝牙关闭：把已连接设备标记为 .disconnectFromSys（系统断连），
            //         让 even_connect 的 EvenDeviceReconnectMixin 能在 BLE 恢复后自动接管重连。
            //         ⚠️ 不能用 .bleError / .disconnectByUser：
            //            - .bleError 落在 isError 但不在重连白名单 isConnectError 里
            //            - .disconnectByUser 是用户主动断连语义
            //            两者都不会触发重连，BLE 关再开后会有部分设备（典型如戒指）永远不重连。
            connectedDevices.forEach { matchDevice in
                if matchDevice.isConnected {
                    handleConnectState(
                        uuid: matchDevice.peripheral.identifier.uuidString,
                        name: matchDevice.peripheral.name ?? "",
                        state: .disconnectFromSys
                    )
                }
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
            cancelAllNativePassiveReconnectWatchdogs()
        } else {
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
    
    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String : Any]) {
        let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
        recordAutoReconnectEvent(
            type: "ios_will_restore_state",
            detail: "peripherals=\(peripherals.count), keys=\(Array(dict.keys))"
        )
        loggerD(msg: "stateRestoration: willRestoreState id=\(BleManager.restorationIdentifier), peripherals=\(peripherals.count), keys=\(Array(dict.keys))")
        peripherals.forEach { peripheral in
            restorePeripheral(peripheral, source: "willRestoreState")
        }
    }
    
    func centralManager(_ central: CBCentralManager, didUpdateANCSAuthorizationFor peripheral: CBPeripheral) {
        loggerE(msg: "didUpdateANCSAuthorizationFor")
    }
    
    func centralManager(_ central: CBCentralManager, connectionEventDidOccur event: CBConnectionEvent, for peripheral: CBPeripheral) {
        loggerE(msg: "connectionEventDidOccur: event = \(event.rawValue)")
    }
    
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, timestamp: CFAbsoluteTime, isReconnecting: Bool, error: (any Error)?) {
        loggerE(msg: "didDisconnectPeripheral: timestamp = \(timestamp), isReconnecting = \(isReconnecting), error = \(String(describing: error))")
    }
    
    /**
     * 设备连接成功回调
     */
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        let tag = "didConnect"
        //  1、检查是否获取到了蓝牙配置
        guard let connectRequest = findActiveConnectRequest(peripheral: peripheral),
              let bleConfig = connectRequest.bleConfig else {
            handleConnectState(uuid: peripheral.identifier.uuidString, name: peripheral.name ?? "", state: .noBleConfigFound, tag: tag)
            return
        }
        //  2、发起服务发现
        loggerD(msg: "didConnect: \(peripheral.identifier.uuidString)-\(peripheral.name ?? ""), requestName=\(connectRequest.name), config=\(bleConfig.name)")
        startConnectingCountdown(
            currentConfig: bleConfig,
            uuid: peripheral.identifier.uuidString,
            name: connectRequest.name,
            afterUpgrade: connectRequest.afterUpgrade
        )
        handleAlreadyConnected(peripheral: peripheral, bleConfig: bleConfig, deviceName: connectRequest.name, tag: tag)
    }

    /**
     * 设备连接失败回调
     */
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        handleConnectError(peripheral: peripheral, error: error, formMethod: "didFailToConnect")
    }

    /**
     *  设备断连回调
     */
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
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
        if let error = error {
            //  配对授权失败
            if let error = error as NSError?, error.domain == CBATTErrorDomain, error.code == 5 {
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

    /**
     *  获取设备下发指令数据
     */
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil else {
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
