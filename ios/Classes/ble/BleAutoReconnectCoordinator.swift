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
    private var pairingRecoveryDiscoveryTimeout: TimeInterval { 20.0 }

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
        if let canonicalUuid = reconnectIdentityAliases.resolvedCanonical(uuid: uuid),
           canonicalUuid.caseInsensitiveCompare(uuid) != .orderedSame {
            reconnectStore.remove(uuid: canonicalUuid, name: name)
            reconnectIdentityAliases.removeAliases(canonicalUuid: canonicalUuid)
        } else {
            reconnectIdentityAliases.removeAliases(canonicalUuid: uuid)
        }
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
    func armReconnectTask(
        device: BleConnectedDevice,
        source: BleConnectSource = .autoReconnect,
        businessConnected: Bool = false,
        generation: Int64? = nil
    ) {
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
            name: device.peripheral.name ?? "",
            source: source
        )
        task.name = device.peripheral.name ?? task.name
        task.source = BleReconnectSourcePolicy.onArm(
            current: task.source,
            incoming: source,
            businessConnected: businessConnected
        )
        if businessConnected, let generation = generation, generation > 0 {
            // connected 释放 admission 后仍需保留最后一次被 Dart 接受的 epoch，
            // poweredOff 或普通 didDisconnect 才能发送同代终态，而不是 unknown/0。
            task.lastConnectedGeneration = generation
        }
        task.attempt = 0
        task.pausedByBluetoothOff = false
        // 业务已重新认证后，前一轮 Code 14 的一次性恢复约束可以安全清除；之后继续使用
        // 系统长期 pending connect，保持正常自动回连的低功耗语义。
        if businessConnected {
            task.requiresFreshAdvertisement = false
            task.requiresForegroundPairingRecovery = false
        }
        task.timer?.invalidate()
        task.timer = nil
        reconnectTasks[key] = task
        loggerD(msg: "autoReconnect: \(uuid), task armed for \(config.name)")
    }

    /// 必须在 poweredOff 清空 admission 之前冻结终态来源与 generation。
    /// connecting 端点取当前 admission；已业务 connected 端点取 task 保存的最后成功代。
    func bluetoothOffConnectionSnapshots() -> [BleTransportOffConnectionSnapshot] {
        var snapshots: [BleTransportOffConnectionSnapshot] = []
        var capturedEndpointKeys = Set<String>()

        for device in connectedDevices {
            let uuid = device.peripheral.identifier.uuidString
            let name = device.peripheral.name ?? ""
            let key = reconnectKey(uuid: uuid)
            let admission = currentConnectionAdmission(uuid: uuid)
            guard device.isConnected || admission != nil else { continue }

            let task = reconnectTasks[key] ?? reconnectTasks.values.first(where: {
                isSameConnectTarget(
                    storedUuid: $0.uuid,
                    storedName: $0.name,
                    uuid: uuid,
                    name: name
                )
            })
            guard let generation = admission?.generation ?? task?.lastConnectedGeneration,
                  generation > 0 else {
                loggerE(msg: "bluetooth off: \(uuid)-\(name), skip terminal without accepted generation")
                continue
            }
            snapshots.append(BleTransportOffConnectionSnapshot(
                uuid: uuid,
                name: name,
                source: admission?.source ?? .autoReconnect,
                generation: generation
            ))
            capturedEndpointKeys.insert(key)
        }

        // 正在 pending、尚未进入 connectedDevices 的端点同样需要结束 Dart 侧连接态。
        for admission in currentConnectionAdmissions.values {
            let key = reconnectKey(uuid: admission.endpointId)
            guard !capturedEndpointKeys.contains(key) else { continue }
            let session = peripheralConnectionSessions[admission.sessionId]
            snapshots.append(BleTransportOffConnectionSnapshot(
                uuid: admission.endpointId,
                name: session?.deviceName ?? "",
                source: admission.source,
                generation: admission.generation
            ))
            capturedEndpointKeys.insert(key)
        }
        return snapshots
    }

    /// 从 Dart 绑定缓存补种 task，不需要先构造 live CBPeripheral。
    @discardableResult
    func armReconnectTarget(
        _ target: BleReconnectTarget,
        source: BleConnectSource
    ) -> BleReconnectTask? {
        let persistedCanonical = reconnectStore.target(uuid: "", name: target.name)
        let canonicalUuid = BleReconnectTargetIdentityPolicy.canonicalUuid(
            callerUuid: target.uuid,
            aliasCanonicalUuid: reconnectIdentityAliases.resolvedCanonical(uuid: target.uuid),
            persistedUuid: persistedCanonical?.uuid
        )
        let effectiveTarget = BleReconnectTarget(
            belongConfig: target.belongConfig,
            uuid: canonicalUuid,
            name: target.name
        )
        guard let config = bleConfigs.first(where: { $0.name == effectiveTarget.belongConfig }),
              config.autoReconnect,
              !effectiveTarget.uuid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            loggerE(msg: "autoReconnect: \(effectiveTarget.uuid), invalid target/config=\(effectiveTarget.belongConfig)")
            return nil
        }
        if let persistedCanonical,
           persistedCanonical.uuid.caseInsensitiveCompare(canonicalUuid) != .orderedSame {
            // caller 的合法 B 身份替换同名 persisted A 时，同时迁移 alias 与内存 task。
            reconnectIdentityAliases.migrate(
                from: persistedCanonical.uuid,
                to: canonicalUuid
            )
        } else if canonicalUuid.caseInsensitiveCompare(target.uuid) != .orderedSame {
            reconnectIdentityAliases.bind(
                aliasUuid: target.uuid,
                canonicalUuid: canonicalUuid
            )
        }
        let key = reconnectKey(uuid: effectiveTarget.uuid)
        // 同名旧 task 与新 canonical 必须在同一个同步调用中替换，activate 后续只能拿到 B。
        let staleTaskKeys: [String] = reconnectTasks.compactMap { entry -> String? in
            let (storedKey, storedTask) = entry
            guard storedKey != key,
                  storedTask.belongConfig == effectiveTarget.belongConfig,
                  !effectiveTarget.name.isEmpty,
                  storedTask.name == effectiveTarget.name else {
                return nil
            }
            return storedKey
        }
        staleTaskKeys.forEach { staleKey in
            reconnectTasks[staleKey]?.timer?.invalidate()
            if let staleTask = reconnectTasks.removeValue(forKey: staleKey) {
                reconnectIdentityAliases.migrate(from: staleTask.uuid, to: canonicalUuid)
                connectionAdmissionGate.retireInactiveEndpoint(staleTask.uuid)
            }
        }
        var task = reconnectTasks[key] ?? BleReconnectTask(
            belongConfig: effectiveTarget.belongConfig,
            uuid: effectiveTarget.uuid,
            name: effectiveTarget.name,
            source: source
        )
        task.name = effectiveTarget.name.isEmpty ? task.name : effectiveTarget.name
        task.source = BleReconnectSourcePolicy.onArm(
            current: task.source,
            incoming: source,
            businessConnected: false
        )
        task.attempt = 0
        task.pausedByBluetoothOff = false
        task.timer?.invalidate()
        task.timer = nil
        reconnectTasks[key] = task
        reconnectStore.upsert(target: effectiveTarget)
        return task
    }

    /// 旧入口仅 arm 长期意图，不打开 CoreBluetooth connect。
    func armAutoReconnectTargets(_ targets: [BleReconnectTarget]) {
        targets.forEach { _ = armReconnectTarget($0, source: .autoReconnect) }
    }

    /// 所有目标立即建立/复用 pending 直连；物理 callback 前不发 connecting。
    func activateAutoReconnectTargets(
        _ targets: [BleReconnectTarget],
        source: BleConnectSource = .autoReconnect
    ) -> [BleReconnectActivationResult] {
        return targets.map { target in
            guard let config = bleConfigs.first(where: { $0.name == target.belongConfig }),
                  config.autoReconnect else {
                loggerE(msg: "autoReconnect activation rejected: config=\(target.belongConfig), reason=invalidConfig")
                return BleReconnectActivationResult(
                    target: target,
                    state: .rejected,
                    reason: "invalidConfig"
                )
            }
            let trimmedUuid = target.uuid.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedName = target.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedUuid.isEmpty {
                guard !trimmedName.isEmpty else {
                    loggerE(msg: "autoReconnect activation rejected: config=\(target.belongConfig), reason=emptyIdentity")
                    return BleReconnectActivationResult(
                        target: target,
                        state: .rejected,
                        reason: "emptyIdentity"
                    )
                }
                let pendingKey = BlePendingReconnectIdentity(
                    belongConfig: target.belongConfig,
                    name: trimmedName,
                    expectedMacSuffix: target.expectedMacSuffix,
                    source: source
                ).key
                let pending = BlePendingReconnectIdentity(
                    belongConfig: target.belongConfig,
                    name: trimmedName,
                    expectedMacSuffix: target.expectedMacSuffix,
                    source: BleReconnectSourcePolicy.onArm(
                        current: pendingReconnectIdentities[pendingKey]?.source ?? source,
                        incoming: source,
                        businessConnected: false
                    )
                )
                pendingReconnectIdentities[pending.key] = pending
                loggerD(msg: "autoReconnect identityPending: config=\(target.belongConfig), name=\(trimmedName), macSuffix=\(target.expectedMacSuffix)")
                return BleReconnectActivationResult(
                    target: target,
                    state: .identityPending,
                    reason: "awaitingPeripheralIdentity"
                )
            }
            guard let task = armReconnectTarget(target, source: source) else {
                return BleReconnectActivationResult(
                    target: target,
                    state: .rejected,
                    reason: "nativeArmRejected"
                )
            }
            activateArmedReconnectTask(task, source: source)
            return BleReconnectActivationResult(
                target: target,
                state: .resolved,
                reason: ""
            )
        }
    }

    /// 激活一个已经拥有稳定 UUID 的 task；MethodChannel 与扫描身份解析共用此顺序。
    private func activateArmedReconnectTask(_ task: BleReconnectTask, source: BleConnectSource) {
            let key = reconnectKey(uuid: task.uuid)
            if let current = currentConnectionAdmission(uuid: task.uuid) {
                let pendingTeardown = pendingConnectionAdmissionTeardowns[key]
                let currentIsPendingTeardown = pendingTeardown.map {
                    $0.admission.generation == current.generation &&
                        $0.admission.sessionId == current.sessionId
                } == true
                if source != .manualReconnect || !currentIsPendingTeardown {
                    if source == .manualReconnect {
                        // 默认仅提升同一 pending owner，避免手动点击引入第二条 GATT。
                        // 只有旧 owner 已超过 20 秒且从未收到物理回调，才先走 cancel
                        // barrier 后建立新 generation，给 CoreBluetooth 卡住的 pending 一个
                        // 有界恢复机会。
                        if let session = peripheralConnectionSessions[current.sessionId],
                           replaceStalePendingManualAttemptIfNeeded(session.peripheral) {
                            loggerD(msg: "autoReconnect: \(task.uuid)-\(task.name), manual stale pending replacement requested")
                            beginReconnectAttempt(uuid: task.uuid)
                            return
                        }
                        _ = promotePendingAttempt(uuid: task.uuid)
                    }
                    return
                }
            }
            // cancellation barrier 内的手动请求不能提升即将销毁的旧 session；继续创建
            // 新 generation，并由旧 didDisconnect/watchdog 释放后原子启动。
            beginReconnectAttempt(uuid: task.uuid)
    }

    /// 扫描仅为已声明的 name-only owner 补齐 UUID，不把普通空 manufacturer 广播暴露给 Dart。
    @discardableResult
    func resolvePendingReconnectIdentity(
        peripheral: CBPeripheral,
        advertisedName: String,
        belongConfig: String,
        rssi: Int
    ) -> Bool {
        guard let entry = pendingReconnectIdentities.first(where: {
            $0.value.matches(belongConfig: belongConfig, advertisedName: advertisedName)
        }) else {
            return false
        }
        let pending = entry.value
        pendingReconnectIdentities.removeValue(forKey: entry.key)
        let uuid = peripheral.identifier.uuidString
        let target = BleReconnectTarget(
            belongConfig: pending.belongConfig,
            uuid: uuid,
            name: advertisedName,
            expectedMacSuffix: pending.expectedMacSuffix
        )
        guard let task = armReconnectTarget(target, source: pending.source) else {
            loggerE(msg: "autoReconnect identity resolve rejected: config=\(belongConfig), name=\(advertisedName), uuid=\(uuid)")
            return true
        }
        // beginDirectReconnectAttempt 只消费 retrieve/scan cache；先写入内部 cache，
        // 但不走 emitMatchedScanResult，因此 mfrSize=0 不会成为普通扫描结果。
        scanResultTemp.removeAll { $0.0.uuid.caseInsensitiveCompare(uuid) == .orderedSame }
        scanResultTemp.append((
            BleDevice(
                belongConfig: belongConfig,
                name: advertisedName,
                uuid: uuid,
                sn: advertisedName,
                mac: "",
                rssi: rssi
            ),
            peripheral
        ))
        loggerD(msg: "autoReconnect identity resolved: config=\(belongConfig), name=\(advertisedName), uuid=\(uuid), source=\(pending.source.rawValue)")
        activateArmedReconnectTask(task, source: pending.source)
        return true
    }

    /**
     *  取消单个自动回连任务。
     *
     *  disconnect/remove 会调用这里；任务取消后，后续 stale callback 只能打日志，不能恢复连接。
     */
    func cancelReconnectTask(uuid: String, name: String = "") {
        if !name.isEmpty {
            pendingReconnectIdentities = pendingReconnectIdentities.filter {
                $0.value.name != name
            }
        }
        let canonicalUuid = reconnectIdentityAliases.resolvedCanonical(uuid: uuid)
        let matches = reconnectTasks.filter { _, task in
            (canonicalUuid != nil && task.uuid.caseInsensitiveCompare(canonicalUuid!) == .orderedSame) ||
                isSameConnectTarget(storedUuid: task.uuid, storedName: task.name, uuid: uuid, name: name)
        }
        for (key, task) in matches {
            // timer 必须先 invalidate，否则取消后仍可能触发一次 beginReconnectAttempt。
            task.timer?.invalidate()
            pairingRecoveryScanTimers.removeValue(forKey: key)?.timer.invalidate()
            reconnectTasks.removeValue(forKey: key)
            loggerD(msg: "autoReconnect: \(task.uuid)-\(task.name), task cancelled")
        }
    }

    /**
     *  取消所有自动回连任务。
     *
     *  这里只清理 runtime task/alias；是否删除 persisted owner 由调用入口显式决定。
     */
    func cancelAllReconnectTasks() {
        reconnectTasks.values.forEach { $0.timer?.invalidate() }
        pairingRecoveryScanTimers.values.forEach { $0.timer.invalidate() }
        pairingRecoveryScanTimers.removeAll()
        reconnectTasks.removeAll()
        pendingReconnectIdentities.removeAll()
        reconnectIdentityAliases.reset()
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
            task.source = BleReconnectSourcePolicy.afterTransportReset()
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
            scheduleReconnect(
                uuid: task.uuid,
                name: task.name,
                state: .disconnectFromSys,
                preserveAttemptSource: false
            )
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
    func scheduleReconnect(
        uuid: String,
        name: String,
        state: BleConnectState,
        preserveAttemptSource: Bool = false
    ) {
        guard shouldScheduleReconnect(state: state) else {
            return
        }
        guard var task = reconnectTasks[reconnectKey(uuid: uuid)] ??
                reconnectTasks.values.first(where: { isSameConnectTarget(storedUuid: $0.uuid, storedName: $0.name, uuid: uuid, name: name) }) else {
            // 没有 armed task 说明业务尚未确认 connected，原生不能自行接管长期回连。
            return
        }
        if !preserveAttemptSource {
            task.source = BleReconnectSourcePolicy.afterTerminalAttempt()
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
        if state != .noDeviceFound {
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
        loggerD(msg: "autoReconnect: \(task.uuid)-\(task.name), attempt \(task.attempt), native pending connect")
        // 回连不再复用会发 connecting/启动短超时的前台 connect 路由。
        // 只从 CoreBluetooth 缓存/同时扫描结果取 peripheral，然后立即建立 pending 直连。
        beginDirectReconnectAttempt(task: task, config: config)
    }

    /// 构造一条不经扫描前置、不提前起超时的 CoreBluetooth pending connect。
    func beginDirectReconnectAttempt(task: BleReconnectTask, config: BleConfig) {
        // 不能只看业务缓存 isConnected：断连后 retrieve/restoration 可能保留同 UUID 的
        // 旧 CBPeripheral 实例。只有物理连接仍在时才短路，否则必须重建系统 pending connect。
        if let connected = businessConnectedCacheDevice(uuid: task.uuid) {
            armReconnectTask(device: connected, source: .autoReconnect, businessConnected: true)
            return
        }
        if task.requiresFreshAdvertisement {
            startPairingRecoveryDiscoveryIfNeeded(task)
            return
        }
        let cachedPeripheral: CBPeripheral? = {
            // Code 14 后必须优先消费本轮 didDiscover 写入的 peripheral，而不是先从
            // retrievePeripherals 取回刚被 iOS 拒绝的旧缓存对象。
            if task.requiresForegroundPairingRecovery,
               let discovered = scanResultTemp.first(where: {
                   $0.0.uuid.caseInsensitiveCompare(task.uuid) == .orderedSame ||
                       (!task.name.isEmpty && ($0.0.name == task.name || $0.1.name == task.name))
               })?.1 {
                return discovered
            }
            // App 重装会让服务端/业务缓存中的 CoreBluetooth UUID 失效。若目标已被
            // iOS/ANCS 持有连接，它可能停止广播，必须在旧 UUID retrieve 和扫描缓存前
            // 通过配置私有服务 + ANCS 接管系统连接，再复用下方同一条 Gate/GATT 流程。
            if let systemConnected = findPeripheralFromConnected(
                uuid: task.uuid,
                name: task.name,
                serviceUUIDs: config.privateServices.map { $0.serviceUUID }
            ) {
                loggerD(msg: "autoReconnect: \(task.uuid)-\(task.name), system-connected identity takeover current=\(systemConnected.identifier.uuidString)")
                return systemConnected
            }
            if let identifier = UUID(uuidString: task.uuid),
               let retrieved = centralManager.retrievePeripherals(withIdentifiers: [identifier]).first {
                return retrieved
            }
            return scanResultTemp.first(where: {
                $0.0.uuid.caseInsensitiveCompare(task.uuid) == .orderedSame ||
                    (!task.name.isEmpty && ($0.0.name == task.name || $0.1.name == task.name))
            })?.1
        }()
        guard let peripheral = cachedPeripheral else {
            loggerD(msg: "autoReconnect: \(task.uuid)-\(task.name), no peripheral cache yet, wait concurrent scan/retrieve")
            scheduleReconnect(
                uuid: task.uuid,
                name: task.name,
                state: .noDeviceFound,
                preserveAttemptSource: true
            )
            return
        }

        // 辅助扫描可能按 name 找到 CoreBluetooth 重新分配 UUID 的同一设备。必须在任何
        // admission/request 写入前原子迁移 task key、task.uuid 和持久化目标。
        let activeTask = migrateReconnectTaskIdentityIfNeeded(
            task,
            to: peripheral
        )
        let key = reconnectKey(uuid: activeTask.uuid)
        if let current = currentConnectionAdmission(uuid: activeTask.uuid) {
            let pendingTeardown = pendingConnectionAdmissionTeardowns[key]
            let currentIsPendingTeardown = pendingTeardown.map {
                $0.admission.generation == current.generation &&
                    $0.admission.sessionId == current.sessionId
            } == true
            let isReplacementGeneration = pendingTeardown.map {
                $0.admission.generation != current.generation ||
                    $0.admission.sessionId != current.sessionId
            } == true
            // beginReconnectAttempt 也可能直接由其它入口以 manual source 调用。保持与
            // activation 的陈旧 pending 策略一致，避免绕过受控 replacement 边界。
            if activeTask.source == .manualReconnect,
               replaceStalePendingManualAttemptIfNeeded(peripheral) {
                loggerD(msg: "autoReconnect: \(activeTask.uuid)-\(activeTask.name), direct manual stale pending replacement requested")
            }
            let barrierBlocking = hasPeripheralCancellationBarrier(peripheral)

            if currentIsPendingTeardown {
                // 手动接管或辅助扫描的受控恢复都可能把当前 old admission 放入
                // teardown。此时必须继续注册下一代；新 connect 会被 barrier 扣住，
                // 直到旧 CoreBluetooth callback 或 watchdog 明确释放。
            } else if activeTask.source == .manualReconnect && barrierBlocking {
                if isReplacementGeneration ||
                    (pendingTeardown == nil && deferredPeripheralReconnectRegistry.contains(endpointId: activeTask.uuid)) {
                    // 重复手动点击复用已经注册的新 generation；registry 的 take 语义保证
                    // 旧 callback/watchdog 竞态时仍只会真正 connect 一次。
                    connectPeripheralAfterCancellationBarrier(peripheral, autoReconnect: true)
                    return
                }
                // current 仍是即将 teardown 的旧 session：禁止 promote，继续向下注册
                // 一个新 generation，旧回调只会 exact-release 旧 admission。
            } else {
                if activeTask.source == .manualReconnect {
                    _ = promotePendingAttempt(uuid: activeTask.uuid)
                }
                return
            }
        }

        var request = BleEasyConnect(
            configName: activeTask.belongConfig,
            uuid: peripheral.identifier.uuidString,
            name: activeTask.name,
            afterUpgrade: false,
            directConnect: true,
            time: Date().timeIntervalSince1970
        )
        request.bleConfig = config
        upsertActiveConnectRequest(request)
        peripheral.delegate = self
        replaceConnectionCache(
            peripheral: peripheral,
            config: config,
            reason: "auto reconnect pending"
        )
        guard registerConnectionAttempt(
            peripheral: peripheral,
            config: config,
            deviceName: activeTask.name,
            afterUpgrade: false,
            source: activeTask.source
        ) != nil else {
            return
        }
        let usesSystemAutoReconnect = !activeTask.requiresForegroundPairingRecovery
        connectPeripheralAfterCancellationBarrier(
            peripheral,
            autoReconnect: usesSystemAutoReconnect
        )
        loggerD(msg: "autoReconnect: \(activeTask.uuid)-\(activeTask.name), native pending connect activated source=\(activeTask.source.rawValue), pairingRecovery=\(activeTask.requiresForegroundPairingRecovery)")
    }

    /// Code 14 后只保留长期回连意图，不复用已失败的 pending connect。扫描窗口最多 20 秒；
    /// 超时后回退系统 pending connect，保证设备离开范围时自动回连不会被此恢复分支关闭。
    func preparePeerPairingRecovery(uuid: String, name: String) {
        guard let key = reconnectTasks.first(where: { _, task in
            isSameConnectTarget(
                storedUuid: task.uuid,
                storedName: task.name,
                uuid: uuid,
                name: name
            )
        })?.key,
        var task = reconnectTasks[key] else {
            return
        }
        task.requiresFreshAdvertisement = true
        task.requiresForegroundPairingRecovery = true
        reconnectTasks[key] = task
        // 删除本轮命中的广告缓存，确保恢复连接确实等待 error 之后的新广告。
        purgeStaleScanCache(uuid: task.uuid, name: task.name)
        loggerD(msg: "autoReconnect: \(task.uuid)-\(task.name), peer pairing reset; wait fresh advertisement before recovery")
    }

    /// 在已有扫描上共享窗口；只有本任务主动开的扫描，超时才允许停止，避免抢占其他业务扫描。
    private func startPairingRecoveryDiscoveryIfNeeded(_ task: BleReconnectTask) {
        let key = reconnectKey(uuid: task.uuid)
        guard pairingRecoveryScanTimers[key] == nil else { return }
        let ownsScan = !centralManager.isScanning
        if ownsScan {
            startScan()
        }
        let timer = Timer.scheduledTimer(withTimeInterval: pairingRecoveryDiscoveryTimeout, repeats: false) { [weak self] _ in
            guard let self = self,
                  let entry = self.pairingRecoveryScanTimers.removeValue(forKey: key),
                  var current = self.reconnectTasks[key],
                  current.requiresFreshAdvertisement else {
                return
            }
            current.requiresFreshAdvertisement = false
            // 没有拿到失败后的新广告时不能伪装成“已刷新”。回退为系统长期 pending
            // 让 State Restoration 继续拥有 rendezvous，下一次 Code 14 才会再次开启窗口。
            current.requiresForegroundPairingRecovery = false
            self.reconnectTasks[key] = current
            if entry.ownsScan {
                self.stopScan()
            }
            self.loggerD(msg: "autoReconnect: \(current.uuid)-\(current.name), peer pairing recovery scan timed out; resume system pending connect")
            self.beginReconnectAttempt(uuid: current.uuid)
        }
        pairingRecoveryScanTimers[key] = (timer, ownsScan)
        loggerD(msg: "autoReconnect: \(task.uuid)-\(task.name), start peer pairing recovery scan ownsScan=\(ownsScan)")
    }

    /// 仅精确名称/配置命中的新广告可以解除 Code 14 恢复门禁；这样附近同型号设备不会抢占 owner。
    @discardableResult
    func resumePeerPairingRecoveryIfMatched(
        peripheral: CBPeripheral,
        advertisedName: String,
        belongConfig: String,
        rssi: Int
    ) -> Bool {
        guard let entry = reconnectTasks.first(where: { _, task in
            task.requiresFreshAdvertisement &&
                task.belongConfig == belongConfig &&
                !task.name.isEmpty &&
                task.name == advertisedName
        }), var task = reconnectTasks[entry.key] else {
            return false
        }
        pairingRecoveryScanTimers.removeValue(forKey: entry.key)?.timer.invalidate()
        scanResultTemp.removeAll { info in
            info.0.uuid.caseInsensitiveCompare(peripheral.identifier.uuidString) == .orderedSame
        }
        scanResultTemp.append((
            BleDevice(
                belongConfig: belongConfig,
                name: advertisedName,
                uuid: peripheral.identifier.uuidString,
                sn: advertisedName,
                mac: "",
                rssi: rssi
            ),
            peripheral
        ))
        task = migrateReconnectTaskIdentityIfNeeded(task, to: peripheral)
        task.requiresFreshAdvertisement = false
        reconnectTasks[reconnectKey(uuid: task.uuid)] = task
        loggerD(msg: "autoReconnect: \(task.uuid)-\(task.name), peer pairing recovery discovered fresh peripheral; rebuild normal connect")
        beginReconnectAttempt(uuid: task.uuid)
        return true
    }

    /**
     * 接管 CoreBluetooth 已自动建立的 reconnect owner。
     *
     * `isReconnecting=true` 表示系统已经持有下一次物理连接，插件不能再次调用 connect。
     * 这里只重建 request/admission，使未来 didConnect 能进入统一 GATT Gate。
     */
    func adoptSystemAutoReconnect(_ peripheral: CBPeripheral, name: String) {
        let uuid = peripheral.identifier.uuidString
        guard var task = reconnectTasks[reconnectKey(uuid: uuid)] ?? reconnectTasks.values.first(where: {
            isSameConnectTarget(
                storedUuid: $0.uuid,
                storedName: $0.name,
                uuid: uuid,
                name: name
            )
        }),
        let config = bleConfigs.first(where: { $0.name == task.belongConfig }),
        config.autoReconnect,
        centralManager.state == .poweredOn else {
            // 用户硬取消或配置撤销后，系统旧 owner 也必须真的停止。
            centralManager.cancelPeripheralConnection(peripheral)
            loggerD(msg: "autoReconnect: \(uuid), reject system reconnect without authorized owner")
            return
        }
        if let current = currentConnectionAdmission(uuid: uuid) {
            startPendingPhysicalConnectWatchdog(
                peripheral,
                admission: current,
                autoReconnect: true
            )
            loggerD(msg: "autoReconnect: \(uuid), reuse system reconnect generation=\(current.generation)")
            return
        }

        task.attempt = nextReconnectAttemptCount(task.attempt)
        task.source = .autoReconnect
        task.timer?.invalidate()
        task.timer = nil
        reconnectTasks[reconnectKey(uuid: task.uuid)] = task

        var request = BleEasyConnect(
            configName: config.name,
            uuid: uuid,
            name: name.isEmpty ? task.name : name,
            afterUpgrade: false,
            directConnect: true,
            time: Date().timeIntervalSince1970
        )
        request.bleConfig = config
        upsertActiveConnectRequest(request)
        peripheral.delegate = self
        replaceConnectionCache(
            peripheral: peripheral,
            config: config,
            reason: "adopt system auto reconnect"
        )
        guard let admission = registerConnectionAttempt(
            peripheral: peripheral,
            config: config,
            deviceName: request.name,
            afterUpgrade: false,
            source: .autoReconnect
        ) else {
            return
        }
        startPendingPhysicalConnectWatchdog(
            peripheral,
            admission: admission,
            autoReconnect: true
        )
        loggerD(msg: "autoReconnect: \(uuid)-\(request.name), adopted CoreBluetooth system reconnect generation=\(admission.generation)")
    }

    /// 同名辅助扫描命中新 UUID 时迁移唯一 owner；source/attempt/timer/暂停态原样保留。
    func migrateReconnectTaskIdentityIfNeeded(
        _ task: BleReconnectTask,
        to peripheral: CBPeripheral
    ) -> BleReconnectTask {
        let peripheralUuid = peripheral.identifier.uuidString
        let peripheralName = peripheral.name ?? task.name
        guard let migrated = BleReconnectIdentityPolicy.migratedTask(
            task,
            peripheralUuid: peripheralUuid,
            peripheralName: peripheralName
        ) else {
            return task
        }
        let oldKey = reconnectKey(uuid: task.uuid)
        let newKey = reconnectKey(uuid: peripheralUuid)

        // 先构造完整新 task，再一次替换内存 owner；同 key 旧 timer 必须停掉，不能与迁移代并跑。
        reconnectTasks[newKey]?.timer?.invalidate()
        reconnectTasks.removeValue(forKey: oldKey)
        reconnectTasks[newKey] = migrated
        reconnectIdentityAliases.migrate(from: task.uuid, to: peripheralUuid)
        // Gate 与 generation 只保留当前 canonical UUID；旧回调因 current/session 缺失会失效。
        connectionAdmissionGate.retireInactiveEndpoint(task.uuid)
        reconnectStore.migrate(
            oldUuid: task.uuid,
            oldName: task.name,
            to: BleReconnectTarget(
                belongConfig: task.belongConfig,
                uuid: peripheralUuid,
                name: peripheralName
            )
        )
        loggerD(msg: "autoReconnect: migrate peripheral identity \(task.uuid) -> \(peripheralUuid), name=\(peripheralName)")
        return migrated
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
     *  发起 CoreBluetooth 连接。
     *
     *  autoReconnect=true 时传入系统自动回连选项；false 时保持前台主动连接的明确请求语义。
     */
    func connectPeripheral(_ peripheral: CBPeripheral, autoReconnect: Bool) {
        if autoReconnect, #available(iOS 17.0, *) {
            // 必须使用 SDK 常量；它的真实值是 kCBConnectOptionAutoReconnect，
            // 直接把符号名写成字符串会被 CoreBluetooth 当作未知 option 忽略。
            centralManager.connect(
                peripheral,
                options: [CBConnectPeripheralOptionEnableAutoReconnect: true]
            )
            loggerD(msg: "autoReconnect: \(peripheral.identifier.uuidString), CoreBluetooth system auto reconnect enabled")
        } else {
            // iOS 17 以下仍保留普通 pending connect；State Restoration 可继续持有该请求。
            centralManager.connect(peripheral)
        }
    }
}
