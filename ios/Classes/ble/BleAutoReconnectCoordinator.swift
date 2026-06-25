//
//  BleAutoReconnectCoordinator.swift
//  flutter_ezw_ble
//
//  Owns iOS native auto reconnect task scheduling. The coordinator only restores
//  the physical CoreBluetooth link; every successful link must still pass through
//  service discovery, characteristic lookup, notify/CCCD setup, and Dart business auth.
//

import CoreBluetooth
import Foundation

/**
 *  iOS 自动回连调度扩展。
 *
 *  保持为 BleManager extension 是为了复用现有 CoreBluetooth delegate 和 GATT pipeline，
 *  但把任务调度/退避/持久化这些策略从 BleManager 主文件中隔离出来。
 */
extension BleManager {
    private var passiveReconnectDebounceMs: TimeInterval { 1500 }

    /**
     *  判断两个连接目标是否指向同一 BLE 设备。
     */
    func isSameConnectTarget(storedUuid: String, storedName: String, uuid: String, name: String) -> Bool {
        // 双方都有稳定 UUID 时，UUID 是唯一 owner；不能因为广播名相同就互相命中。
        let storedHasStableUuid = storedUuid.isNotEmpty && !storedUuid.hasPrefix("temp-")
        let targetHasStableUuid = uuid.isNotEmpty && !uuid.hasPrefix("temp-")
        if storedHasStableUuid && targetHasStableUuid {
            return storedUuid == uuid
        }

        // 只有 UUID 缺失/temp 阶段才允许 name fallback；空 name 永远不匹配。
        return (!storedUuid.isEmpty && !uuid.isEmpty && storedUuid == uuid) ||
            (!storedName.isEmpty && !name.isEmpty && storedName == name)
    }

    /**
     *  生成自动回连任务 key。
     *
     *  UUID 大小写在日志/系统回调中可能不完全一致，统一 lowercased 可以避免同一设备重复任务。
     */
    func reconnectKey(uuid: String) -> String {
        return uuid.lowercased()
    }

    /**
     *  记录 native 自动回连事件。
     *
     *  State Restoration 唤醒时 Dart 可能尚未订阅 EventChannel，因此事件先进入持久化缓冲。
     */
    func recordAutoReconnectEvent(type: String, uuid: String = "", name: String = "", detail: String = "") {
        reconnectStore.recordEvent(type: type, uuid: uuid, name: name, detail: detail)
    }

    /**
     *  查询持久化回连目标。
     *
     *  restoration 只能拿到 CBPeripheral，必须通过持久化目标找回 belongConfig。
     */
    func persistedReconnectTarget(uuid: String, name: String = "") -> BleReconnectTarget? {
        reconnectStore.target(uuid: uuid, name: name)
    }

    /**
     *  保存业务已确认连接的设备为自动回连目标。
     *
     *  只有 Dart 调用 deviceConnected 后才会走到这里，避免 GATT ready 但业务认证失败的设备被自动回连。
     */
    func persistReconnectTarget(device: BleConnectedDevice) {
        let uuid = device.peripheral.identifier.uuidString
        // 空 UUID 无法作为 CoreBluetooth retrieve/pending connect 的稳定身份。
        guard uuid.isNotEmpty else {
            return
        }
        reconnectStore.upsert(device: device)
        loggerD(msg: "autoReconnect: \(uuid), persisted native reconnect target")
    }

    /**
     *  移除单个持久化目标。
     *
     *  用户主动断开时必须同时取消内存任务和磁盘目标，避免后续系统断连回调重新唤起回连。
     */
    func removePersistedReconnectTarget(uuid: String, name: String = "") {
        reconnectStore.remove(uuid: uuid, name: name)
    }

    /**
     *  清空全部持久化回连目标。
     *
     *  reset/remove-all 语义要求彻底放弃 native 自动回连意图。
     */
    func clearPersistedReconnectTargets() {
        reconnectStore.clearTargets()
    }

    /**
     *  Arm 一个自动回连任务。
     *
     *  该函数只建立“后续系统断连可以重试”的任务，不会立即发起连接。
     */
    func armReconnectTask(device: BleConnectedDevice) {
        let config = device.belongConfig
        // 配置关闭 autoReconnect 时，业务层仍可主动 connect，但原生不保留长期回连意图。
        guard config.autoReconnect else {
            return
        }
        let uuid = device.peripheral.identifier.uuidString
        // 自动回连必须依赖稳定 peripheral identifier。
        guard uuid.isNotEmpty else {
            return
        }
        let key = reconnectKey(uuid: uuid)
        var task = reconnectTasks[key] ?? BleReconnectTask(
            belongConfig: config.name,
            uuid: uuid,
            name: device.peripheral.name ?? ""
        )
        task.name = device.peripheral.name ?? task.name
        task.attempt = 0
        task.pausedByBluetoothOff = false
        task.timer?.invalidate()
        task.timer = nil
        reconnectTasks[key] = task
        loggerD(msg: "autoReconnect: \(uuid), task armed for \(config.name)")
    }

    /**
     *  取消单个自动回连任务。
     *
     *  disconnect/remove 会调用这里；任务取消后，后续 stale callback 只能打日志，不能恢复连接。
     */
    func cancelReconnectTask(uuid: String, name: String = "") {
        let matches = reconnectTasks.filter { _, task in
            isSameConnectTarget(storedUuid: task.uuid, storedName: task.name, uuid: uuid, name: name)
        }
        for (key, task) in matches {
            // timer 必须先 invalidate，否则取消后仍可能触发一次 beginReconnectAttempt。
            task.timer?.invalidate()
            reconnectTasks.removeValue(forKey: key)
            loggerD(msg: "autoReconnect: \(task.uuid)-\(task.name), task cancelled")
        }
    }

    /**
     *  取消所有自动回连任务。
     *
     *  reset 场景需要内存任务和持久化目标一起清理。
     */
    func cancelAllReconnectTasks() {
        reconnectTasks.values.forEach { $0.timer?.invalidate() }
        reconnectTasks.removeAll()
    }

    /**
     *  蓝牙关闭时暂停自动回连任务。
     *
     *  poweredOff 不是最终失败，不能把任务标记为 noDeviceFound；等待 poweredOn 后继续调度。
     */
    func pauseReconnectTasksForBluetoothOff() {
        for key in reconnectTasks.keys {
            guard var task = reconnectTasks[key] else {
                continue
            }
            // 关闭蓝牙期间 timer 继续跑没有意义，只会制造 timeout 噪音。
            task.timer?.invalidate()
            task.timer = nil
            task.pausedByBluetoothOff = true
            reconnectTasks[key] = task
        }
        if !reconnectTasks.isEmpty {
            loggerD(msg: "autoReconnect: pause \(reconnectTasks.count) task(s), bluetooth off")
        }
    }

    /**
     *  蓝牙恢复后继续被暂停的任务。
     *
     *  这里统一进入 scheduleReconnect，保证恢复、系统断连、超时都复用同一套退避策略。
     */
    func resumeReconnectTasksAfterBluetoothOn() {
        let pausedTasks = reconnectTasks.values.filter { $0.pausedByBluetoothOff }
        // 没有暂停任务时不输出日志，避免生命周期噪音掩盖真正的回连阶段。
        guard pausedTasks.isNotEmpty else {
            return
        }
        loggerD(msg: "autoReconnect: resume \(pausedTasks.count) paused task(s), bluetooth on")
        for task in pausedTasks {
            let key = reconnectKey(uuid: task.uuid)
            if var stored = reconnectTasks[key] {
                stored.pausedByBluetoothOff = false
                reconnectTasks[key] = stored
            }
            scheduleReconnect(uuid: task.uuid, name: task.name, state: .disconnectFromSys)
        }
    }

    /**
     *  如果蓝牙已开启，则尝试恢复暂停任务。
     *
     *  currentBleState、initConfigs 和前台生命周期都会调用这里，用于补偿系统状态回调丢失或顺序变化。
     */
    func resumeReconnectTasksIfBluetoothOn(reason: String) {
        guard reconnectTasks.contains(where: { $0.value.pausedByBluetoothOff }) else {
            return
        }
        guard centralManager.state == .poweredOn else {
            loggerD(msg: "autoReconnect: resume skipped, reason=\(reason), bluetooth=\(centralManager.state.label)")
            return
        }
        loggerD(msg: "autoReconnect: resume requested, reason=\(reason)")
        resumeReconnectTasksAfterBluetoothOn()
    }

    /**
     *  App 即将回到前台时补偿恢复暂停任务。
     *
     *  iOS 后台期间 CoreBluetooth 状态回调可能早于 Dart 恢复完成，这里只触发原生任务检查。
     */
    @objc func handleAppWillEnterForeground() {
        resumeReconnectTasksIfBluetoothOn(reason: "willEnterForeground")
    }

    /**
     *  App 激活后补偿恢复暂停任务。
     *
     *  与 willEnterForeground 互补，覆盖从 restoration / push / 普通打开进入 active 的不同路径。
     */
    @objc func handleAppDidBecomeActive() {
        resumeReconnectTasksIfBluetoothOn(reason: "didBecomeActive")
    }

    /**
     *  判断某个连接状态是否允许自动回连。
     *
     *  用户主动断开不在白名单里，避免 disconnect 后被系统回调重新拉起连接。
     */
    func shouldScheduleReconnect(state: BleConnectState) -> Bool {
        return state == .disconnectFromSys ||
            state == .timeout ||
            state == .serviceFail ||
            state == .charsFail ||
            state == .noDeviceFound
    }

    /**
     *  根据断连/失败状态调度下一次自动回连。
     *
     *  autoReconnectUseNativePassive 开启时直接交给 CoreBluetooth pending connect；
     *  否则使用退避 timer 主动触发 connect(easyConnect:)。
     */
    func scheduleReconnect(uuid: String, name: String, state: BleConnectState) {
        guard shouldScheduleReconnect(state: state) else {
            return
        }
        guard var task = reconnectTasks[reconnectKey(uuid: uuid)] ??
                reconnectTasks.values.first(where: { isSameConnectTarget(storedUuid: $0.uuid, storedName: $0.name, uuid: uuid, name: name) }) else {
            // 没有 armed task 说明业务尚未确认 connected，原生不能自行接管长期回连。
            return
        }
        guard let config = bleConfigs.first(where: { $0.name == task.belongConfig }), config.autoReconnect else {
            // 配置被移除或关闭后，旧任务只保留日志，不再调度。
            return
        }
        guard upgradeDevices?.contains(uuid) != true else {
            // OTA/升级态由升级流程控制连接，避免自动回连打断升级状态机。
            return
        }
        guard centralManager.state == .poweredOn else {
            task.pausedByBluetoothOff = true
            reconnectTasks[reconnectKey(uuid: task.uuid)] = task
            loggerD(msg: "autoReconnect: \(task.uuid), paused because bluetooth is unavailable")
            return
        }
        if config.autoReconnectUseNativePassive && state != .noDeviceFound {
            let key = reconnectKey(uuid: task.uuid)
            // passive pending connect 由系统持有，不需要本地 timer 并行触发。
            task.timer?.invalidate()
            task.timer = nil
            reconnectTasks[key] = task
            if findActiveConnectRequest(uuid: task.uuid, name: task.name) != nil {
                loggerD(msg: "autoReconnect: \(task.uuid)-\(task.name), active request exists, defer native pending connect, reason=\(state.rawValue)")
                // 前台连接/恢复连接已经拥有该 peripheral 的 CoreBluetooth connect 所有权。
                // 这里必须真正 defer；否则会创建第二个 pending connect，导致回调归属混乱。
                return
            }
            // CoreBluetooth pending connect is the mechanism that lets State Restoration wake the process later.
            // A short scan/connect timeout would cancel the only system-owned rendezvous point.
            loggerD(msg: "autoReconnect: \(task.uuid), start native pending connect, reason=\(state.rawValue)")
            DispatchQueue.main.async { [weak self] in
                self?.beginReconnectAttempt(uuid: task.uuid)
            }
            return
        }
        // noDeviceFound 通常表示没有可用于 CoreBluetooth pending connect 的 peripheral
        // cache。此时不再启动显式扫描，也不能立刻递归重试；按固定防抖等下一轮系统恢复机会。
        task.timer?.invalidate()
        // nextAttempt 只用于日志，不决定是否停止。持续回连只能被用户/业务取消、
        // 配置关闭、reset/release 或进程死亡终止。
        let nextAttempt = nextReconnectAttemptCount(task.attempt)
        let delay = passiveReconnectDebounceMs / 1000
        task.timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.beginReconnectAttempt(uuid: task.uuid)
        }
        reconnectTasks[reconnectKey(uuid: task.uuid)] = task
        loggerD(msg: "autoReconnect: \(task.uuid), schedule attempt \(nextAttempt) after \(Int(delay * 1000))ms, reason=\(state.rawValue)")
    }

    /**
     *  计算下一次尝试序号。
     *
     *  iOS 的 Int 上限很高，但自动回连可能持续运行数小时甚至数天；这里做饱和处理，
     *  保证 attempt 只作为日志/退避参数，不会无限增长到影响后续计算。
     */
    func nextReconnectAttemptCount(_ current: Int) -> Int {
        return min(current + 1, 1_000_000)
    }

    /**
     *  执行一次自动回连尝试。
     *
     *  这里复用 connect(easyConnect:) 是为了让主动连接、自动回连、restoration 最终都进入同一套 GATT pipeline。
     */
    func beginReconnectAttempt(uuid: String) {
        let key = reconnectKey(uuid: uuid)
        guard var task = reconnectTasks[key] else {
            // 任务可能已被用户 disconnect/remove 取消，忽略旧 timer 回调。
            return
        }
        guard let config = bleConfigs.first(where: { $0.name == task.belongConfig }), config.autoReconnect else {
            return
        }
        guard centralManager.state == .poweredOn else {
            // poweredOff 期间不消耗 attempt，等待状态恢复后继续。
            task.pausedByBluetoothOff = true
            reconnectTasks[key] = task
            return
        }
        // attempt 只用于退避和日志，不再作为停止条件。自动回连是业务 connected 后建立的
        // 持续意图，不能因为设备离开较久或多次 timeout 被 native 主动放弃。
        task.attempt = nextReconnectAttemptCount(task.attempt)
        task.timer?.invalidate()
        task.timer = nil
        reconnectTasks[key] = task
        loggerD(msg: "autoReconnect: \(task.uuid)-\(task.name), attempt \(task.attempt), nativePassive=\(config.autoReconnectUseNativePassive)")
        // autoReconnect 已经持有稳定 CoreBluetooth identity；重连尝试不再进入显式
        // scan-then-connect，避免扫描 timeout 取消系统 pending connect / State Restoration 入口。
        var request = BleEasyConnect(
            configName: task.belongConfig,
            uuid: task.uuid,
            name: task.name,
            afterUpgrade: false,
            directConnect: true,
            time: Date().timeIntervalSince1970
        )
        request.bleConfig = config
        connect(easyConnect: request)
    }

    /**
     *  判断当前连接是否由自动回连触发。
     *
     *  主动连接和自动回连共用 connect(easyConnect:)，该判断用于区分 timeout/scan 策略。
     */
    func isAutoReconnectAttempt(uuid: String, name: String) -> Bool {
        return reconnectTasks.values.contains { task in
            task.attempt > 0 &&
            isSameConnectTarget(storedUuid: task.uuid, storedName: task.name, uuid: uuid, name: name)
        }
    }

    /**
     *  判断当前连接是否是 iOS native passive reconnect。
     *
     *  passive reconnect 不能被短扫描 timeout 取消，否则 State Restoration 的系统唤醒点会丢失。
     */
    func isNativePassiveReconnectAttempt(uuid: String, name: String, config: BleConfig) -> Bool {
        return config.autoReconnectUseNativePassive && isAutoReconnectAttempt(uuid: uuid, name: name)
    }

    /**
     *  发起 CoreBluetooth 连接。
     *
     *  autoReconnect=true 时传入系统自动回连选项；false 时保持前台主动连接的明确请求语义。
     */
    func connectPeripheral(_ peripheral: CBPeripheral, autoReconnect: Bool) {
        if autoReconnect {
            centralManager.connect(
                peripheral,
                options: ["CBConnectPeripheralOptionEnableAutoReconnect": true]
            )
        } else {
            centralManager.connect(peripheral)
        }
    }
}
