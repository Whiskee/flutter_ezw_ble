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
    private var automaticPairingRecoveryScanWindow: TimeInterval {
        BlePeerPairingRecoveryPolicy.scanWindow(for: .autoReconnect)
    }
    private var manualPairingRecoveryScanWindow: TimeInterval {
        BlePeerPairingRecoveryPolicy.scanWindow(for: .manualReconnect)
    }
    private var pairingRecoveryRetryDelay: TimeInterval {
        BlePeerPairingRecoveryPolicy.retryDelay
    }

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
     *  原生自动回连可能早于 Dart 订阅 EventChannel，因此事件先进入持久化缓冲。
     */
    func recordAutoReconnectEvent(type: String, uuid: String = "", name: String = "", detail: String = "") {
        reconnectStore.recordEvent(type: type, uuid: uuid, name: name, detail: detail)
    }

    /**
     *  查询持久化回连目标。
     *
     *  原生回连只能拿到 CBPeripheral 时，必须通过持久化目标找回 belongConfig。
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
        let persistedTarget = reconnectStore.target(uuid: uuid, name: name)
        if let persistedTarget {
            clearStoppedPeerPairingRecovery(
                belongConfig: persistedTarget.belongConfig,
                name: name.isEmpty ? persistedTarget.name : name
            )
        }
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
        reconnectStore.clearSecurityRecoveryRecords()
        stoppedPeerPairingRecoveryKeys.removeAll()
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
        generation: Int64? = nil,
        attemptGeneration: Int64? = nil
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
        if businessConnected,
           let generation = generation,
           let attemptGeneration = attemptGeneration,
           generation > 0,
           attemptGeneration > 0 {
            // connected 释放 admission 后仍需保留最后一次被 Dart 接受的
            // session/attempt exact pair。poweredOff 或 didDisconnect 只有恢复完整对，
            // 才不会被上层 exact-attempt guard 当成迟到回调。
            task.lastConnectedGeneration = generation
            task.lastConnectedAttemptGeneration = attemptGeneration
            task.sessionGeneration = generation
        }
        task.attempt = 0
        task.pausedByBluetoothOff = false
        // 业务已重新认证后，前一轮 Code 14 的一次性恢复约束可以安全清除；之后继续使用
        // 系统长期 pending connect，保持正常自动回连的低功耗语义。
        if businessConnected {
            task.pairingRecoveryState = .normal
            task.hasAttemptedPairingRecovery = false
            task.securityGateFailureCount = 0
            clearStoppedPeerPairingRecovery(
                belongConfig: config.name,
                name: device.peripheral.name ?? task.name
            )
        }
        task.timer?.invalidate()
        task.timer = nil
        reconnectTasks[key] = task
        loggerD(msg: "autoReconnect: \(uuid), task armed for \(config.name)")
    }

    /// 必须在 poweredOff 清空 admission 之前冻结终态来源与 generation。
    /// connecting 端点取当前 admission；已业务 connected 端点取 task 保存的最后成功代。
    func bluetoothOffConnectionSnapshots() -> [BleTransportOffConnectionSnapshot] {
        // 1、在 poweredOff 清空 admission 前遍历业务连接和当前 admission 快照。
        var snapshots: [BleTransportOffConnectionSnapshot] = []
        var capturedEndpointKeys = Set<String>()

        // 2、优先使用 admission generation，其次使用业务已连接 task 保存的 generation。
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
            guard let generation = admission?.sessionGeneration ?? task?.lastConnectedGeneration,
                  let attemptGeneration = admission?.generation ?? task?.lastConnectedAttemptGeneration,
                  generation > 0,
                  attemptGeneration > 0 else {
                loggerE(msg: "bluetooth off: \(uuid)-\(name), skip terminal without accepted generation")
                continue
            }
            // 3、只上报大于 0 的 generation，确保 Dart epoch guard 能接受系统断连终态。
            snapshots.append(BleTransportOffConnectionSnapshot(
                uuid: uuid,
                name: name,
                source: admission?.source ?? .autoReconnect,
                generation: generation,
                attemptGeneration: attemptGeneration
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
                generation: admission.sessionGeneration,
                attemptGeneration: admission.generation
            ))
            capturedEndpointKeys.insert(key)
        }
        return snapshots
    }

    /// 从 Dart 绑定缓存补种 task，不需要先构造 live CBPeripheral。
    @discardableResult
    func armReconnectTarget(
        _ target: BleReconnectTarget,
        source: BleConnectSource,
        sessionGeneration: Int64 = 0
    ) -> BleReconnectTask? {
        // A cold-start automatic arm must honor the durable fifth-failure latch
        // before it recreates either a reconnect target or a CoreBluetooth owner.
        if source != .manualReconnect,
           reconnectStore.securityRecoveryRecord(
               belongConfig: target.belongConfig,
               name: target.name
           )?.exhausted == true {
            loggerD(msg: "autoReconnect: \(target.uuid)-\(target.name), arm rejected reason=securityRecoveryExhaustedPersisted")
            return nil
        }
        let persistedCanonical = reconnectStore.target(uuid: "", name: target.name)
        let canonicalUuid = BleReconnectTargetIdentityPolicy.canonicalUuid(
            callerUuid: target.uuid,
            aliasCanonicalUuid: reconnectIdentityAliases.resolvedCanonical(uuid: target.uuid),
            persistedUuid: persistedCanonical?.uuid
        )
        let effectiveTarget = BleReconnectTarget(
            belongConfig: target.belongConfig,
            uuid: canonicalUuid,
            name: target.name,
            expectedMacSuffix: target.expectedMacSuffix
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
        if source != .manualReconnect,
           let persistedRecovery = reconnectStore.securityRecoveryRecord(
               belongConfig: effectiveTarget.belongConfig,
               name: effectiveTarget.name
           ) {
            // Process recreation restores the monotonic episode budget; a new
            // Dart batch cannot silently turn attempt 4 back into attempt 0.
            task.securityGateFailureCount = max(
                task.securityGateFailureCount,
                persistedRecovery.failureCount
            )
        }
        let previousSessionGeneration = task.sessionGeneration
        task.name = effectiveTarget.name.isEmpty ? task.name : effectiveTarget.name
        task.source = BleReconnectSourcePolicy.onArm(
            current: task.source,
            incoming: source,
            businessConnected: false
        )
        // Session 只能向前推进。旧 Dart batch 的迟到 activation 不能把已安装 owner
        // 降回更小代次，否则 CoreBluetooth 成功回调会再次被上层 epoch guard 拒绝。
        if sessionGeneration > task.sessionGeneration {
            task.sessionGeneration = sessionGeneration
            // 新 recovery batch 必须淘汰旧 5 秒 timer，并从完整扫描窗口重新开始。
            if task.pairingRecoveryState == .waitingFreshAdvertisementRetry {
                task.pairingRecoveryState = .awaitingFreshAdvertisement
            }
        }
        task.attempt = 0
        task.pausedByBluetoothOff = false
        let preservesCurrentRecoveryWait = source != .manualReconnect &&
            task.pairingRecoveryState == .waitingFreshAdvertisementRetry &&
            task.sessionGeneration == previousSessionGeneration
        if !preservesCurrentRecoveryWait {
            task.timer?.invalidate()
            task.timer = nil
        }
        reconnectTasks[key] = task
        reconnectStore.upsert(target: effectiveTarget)
        return task
    }

    /// Code 14 停止标记只使用稳定 config+完整名称，不使用可能被 CoreBluetooth
    /// 重新分配的 UUID。空身份不能进入集合，避免多个未知设备互相覆盖。
    private func peerPairingRecoveryKey(belongConfig: String, name: String) -> String? {
        let config = belongConfig.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let deviceName = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !config.isEmpty, !deviceName.isEmpty else { return nil }
        return "\(config)|\(deviceName)"
    }

    private func hasStoppedPeerPairingRecovery(_ target: BleReconnectTarget) -> Bool {
        guard let key = peerPairingRecoveryKey(
            belongConfig: target.belongConfig,
            name: target.name
        ) else {
            return false
        }
        return stoppedPeerPairingRecoveryKeys.contains(key) ||
            reconnectStore.securityRecoveryRecord(
                belongConfig: target.belongConfig,
                name: target.name
            )?.exhausted == true
    }

    private func clearStoppedPeerPairingRecovery(belongConfig: String, name: String) {
        guard let key = peerPairingRecoveryKey(belongConfig: belongConfig, name: name) else {
            return
        }
        stoppedPeerPairingRecoveryKeys.remove(key)
        reconnectStore.removeSecurityRecoveryRecord(
            belongConfig: belongConfig,
            name: name
        )
    }

    /// 结束当前 Code 14 恢复 owner，但保留一个无资源的身份标记。后续自动 activation
    /// 会被拒绝；下一次手动 activation 会消费该事实去等待新广告，而不是直接弹 720。
    private func stopPeerPairingRecoveryTask(_ task: BleReconnectTask, reason: String) {
        let key = reconnectKey(uuid: task.uuid)
        task.timer?.invalidate()
        cancelPairingRecoveryDiscovery(key: key)
        reconnectTasks.removeValue(forKey: key)
        if let identityKey = peerPairingRecoveryKey(
            belongConfig: task.belongConfig,
            name: task.name
        ) {
            stoppedPeerPairingRecoveryKeys.insert(identityKey)
        }
        purgeStaleScanCache(uuid: task.uuid, name: task.name)
        connectionAdmissionGate.retireInactiveEndpoint(task.uuid)
        loggerD(msg: "autoReconnect: \(task.uuid)-\(task.name), peer pairing attempt stopped reason=\(reason)")
    }

    /// 旧入口仅 arm 长期意图，不打开 CoreBluetooth connect。
    func armAutoReconnectTargets(_ targets: [BleReconnectTarget]) {
        targets.forEach { _ = armReconnectTarget($0, source: .autoReconnect) }
    }

    /// 所有目标立即建立/复用 pending 直连；物理 callback 前不发 connecting。
    func activateAutoReconnectTargets(
        _ targets: [BleReconnectTarget],
        source: BleConnectSource = .autoReconnect,
        sessionGeneration: Int64 = 0
    ) -> [BleReconnectActivationResult] {
        // 1、逐目标校验配置和身份，保持一次 activation 的目标快照稳定。
        return targets.map { target in
            // 1.1、关闭 autoReconnect 或缺少稳定 identity 时只返回结果，不创建 GATT。
            guard let config = bleConfigs.first(where: { $0.name == target.belongConfig }),
                  config.autoReconnect else {
                loggerE(msg: "autoReconnect activation rejected: config=\(target.belongConfig), reason=invalidConfig")
                return BleReconnectActivationResult(
                    target: target,
                    state: .rejected,
                    reason: "invalidConfig",
                    source: source,
                    sessionGeneration: sessionGeneration
                )
            }
            let trimmedUuid = target.uuid.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedName = target.name.trimmingCharacters(in: .whitespacesAndNewlines)
            // 1.2、一次性自动恢复已经结束后不再后台重建 owner。只有下一次手动
            // 点击可以开始新 attempt；这里返回 rejected 只结束当前 batch，不触发 UI。
            let manualTakesOverStoppedRecovery =
                source == .manualReconnect && hasStoppedPeerPairingRecovery(target)
            let hasPersistedSecurityExhaustion = reconnectStore.securityRecoveryRecord(
                belongConfig: target.belongConfig,
                name: trimmedName
            )?.exhausted == true
            if source == .manualReconnect {
                // Manual click starts a fresh user-visible attempt. It consumes
                // any silent automatic stop marker and resets the 5403 budget
                // before a new exact generation is admitted.
                clearStoppedPeerPairingRecovery(
                    belongConfig: target.belongConfig,
                    name: trimmedName
                )
            }
            if source != .manualReconnect, hasStoppedPeerPairingRecovery(target) {
                let rejectionReason = hasPersistedSecurityExhaustion
                    ? "securityRecoveryExhaustedPersisted"
                    : "peerPairingRecoveryStopped"
                loggerD(msg: "autoReconnect activation rejected: config=\(target.belongConfig), name=\(trimmedName), reason=\(rejectionReason)")
                return BleReconnectActivationResult(
                    target: target,
                    state: .rejected,
                    reason: rejectionReason,
                    source: source,
                    sessionGeneration: sessionGeneration
                )
            }
            // 1.3、冷启动缓存里只有完整名称时，active 窗口可先接管系统已连接对象。
            // 这保留普通后台 BLE / ANCS 连接能力，但不再依赖跨进程
            // escrow 或 claim 窗口。
            let systemConnectedPeripheral: CBPeripheral? = {
                guard trimmedUuid.isEmpty,
                      allowsSynchronousCoreBluetoothLookup else {
                    return nil
                }
                return findPeripheralFromConnected(
                    uuid: trimmedUuid,
                    name: trimmedName,
                    serviceUUIDs: config.privateServices.map { $0.serviceUUID },
                    requireUniqueMatch: true
                )
            }()
            if let resolvedPeripheral = systemConnectedPeripheral {
                let resolvedUuid = resolvedPeripheral.identifier.uuidString
                let resolvedName = trimmedName.isEmpty
                    ? (resolvedPeripheral.name ?? "")
                    : trimmedName
                let resolvedTarget = BleReconnectTarget(
                    belongConfig: target.belongConfig,
                    uuid: resolvedUuid,
                    name: resolvedName,
                    expectedMacSuffix: target.expectedMacSuffix
                )
                guard var task = armReconnectTarget(
                    resolvedTarget,
                    source: source,
                    sessionGeneration: sessionGeneration
                ) else {
                    return BleReconnectActivationResult(
                        target: target,
                        state: .rejected,
                        reason: "nativeArmRejectedAfterSystemConnected",
                        source: source,
                        sessionGeneration: sessionGeneration
                    )
                }
                if source == .manualReconnect {
                    task.securityGateFailureCount = 0
                    task.pairingRecoveryState = .normal
                    task.hasAttemptedPairingRecovery = false
                    reconnectTasks[reconnectKey(uuid: task.uuid)] = task
                }
                // 将系统已连接 peripheral 放入内部缓存，后续 beginDirectReconnectAttempt
                // 无论当前是 connected/connecting/disconnected 都复用同一 Gate/GATT 流程。
                scanResultTemp.removeAll {
                    $0.0.uuid.caseInsensitiveCompare(resolvedUuid) == .orderedSame
                }
                scanResultTemp.append((
                    BleDevice(
                        belongConfig: target.belongConfig,
                        name: resolvedName,
                        uuid: resolvedUuid,
                        sn: resolvedName,
                        mac: "",
                        rssi: 0
                    ),
                    resolvedPeripheral
                ))
                let resolutionSource = "systemConnected"
                loggerD(msg: "autoReconnect system-connected claim: config=\(target.belongConfig), requestedUuid=\(trimmedUuid), resolvedUuid=\(resolvedUuid), name=\(resolvedName), state=\(resolvedPeripheral.state.rawValue), sessionGeneration=\(task.sessionGeneration)")
                activateArmedReconnectTask(task, source: source)
                return BleReconnectActivationResult(
                    // ack 保留 Dart 原始 target identity，避免 batch 在回执期把 name-key
                    // 突然切成 uuid-key；resolvedUuid 作为独立字段供上层记录和回填。
                    target: target,
                    state: .resolved,
                    reason: "systemConnectedPeripheralClaimed",
                    source: source,
                    sessionGeneration: task.sessionGeneration,
                    resolvedUuid: resolvedUuid,
                    resolutionSource: resolutionSource
                )
            }
            if trimmedUuid.isEmpty {
                guard !trimmedName.isEmpty else {
                    loggerE(msg: "autoReconnect activation rejected: config=\(target.belongConfig), reason=emptyIdentity")
                    return BleReconnectActivationResult(
                        target: target,
                        state: .rejected,
                        reason: "emptyIdentity",
                        source: source,
                        sessionGeneration: sessionGeneration
                    )
                }
                let pendingKey = BlePendingReconnectIdentity(
                    belongConfig: target.belongConfig,
                    name: trimmedName,
                    expectedMacSuffix: target.expectedMacSuffix,
                    source: source,
                    sessionGeneration: sessionGeneration
                ).key
                let pending = BlePendingReconnectIdentity(
                    belongConfig: target.belongConfig,
                    name: trimmedName,
                    expectedMacSuffix: target.expectedMacSuffix,
                    source: BleReconnectSourcePolicy.onArm(
                        current: pendingReconnectIdentities[pendingKey]?.source ?? source,
                        incoming: source,
                        businessConnected: false
                    ),
                    sessionGeneration: sessionGeneration > 0
                        ? sessionGeneration
                        : pendingReconnectIdentities[pendingKey]?.sessionGeneration ?? 0
                )
                pendingReconnectIdentities[pending.key] = pending
                let pendingReason = allowsSynchronousCoreBluetoothLookup
                    ? "awaitingPeripheralIdentity"
                    : "appInactiveDeferred"
                loggerD(msg: "autoReconnect identityPending: config=\(target.belongConfig), name=\(trimmedName), macSuffix=\(target.expectedMacSuffix), reason=\(pendingReason)")
                return BleReconnectActivationResult(
                    target: target,
                    state: .identityPending,
                    reason: pendingReason,
                    source: source,
                    sessionGeneration: sessionGeneration
                )
            }
            // 2、稳定 UUID 目标先 arm 长期 owner，再进入统一 activation。
            guard var task = armReconnectTarget(
                target,
                source: source,
                sessionGeneration: sessionGeneration
            ) else {
                return BleReconnectActivationResult(
                    target: target,
                    state: .rejected,
                    reason: "nativeArmRejected",
                    source: source,
                    sessionGeneration: sessionGeneration
                )
            }
            let manualTakesOverExistingFreshWait =
                source == .manualReconnect &&
                (task.pairingRecoveryState == .awaitingFreshAdvertisement ||
                    task.pairingRecoveryState == .waitingFreshAdvertisementRetry)
            if source == .manualReconnect {
                task.securityGateFailureCount = 0
                task.pairingRecoveryState = .normal
                task.hasAttemptedPairingRecovery = false
                reconnectTasks[reconnectKey(uuid: task.uuid)] = task
            }
            // 2.1、历史 Code 14，或仍在自动扫描/间隔等待中的 owner，被手动点击后都
            // 立即切换到新的手动新鲜广播窗口。不得等待自动 5 秒 timer，也不得复用
            // 旧 peripheral；只有这次手动物理 attempt 的真实 Code 14 才能返回 720。
            let takesOverFreshAdvertisementWait =
                manualTakesOverStoppedRecovery ||
                manualTakesOverExistingFreshWait ||
                task.pairingRecoveryState == .awaitingFreshAdvertisement ||
                task.pairingRecoveryState == .waitingFreshAdvertisementRetry
            if source == .manualReconnect,
               hasStoppedPeerPairingRecovery(target) || takesOverFreshAdvertisementWait {
                var freshTask = task
                freshTask.hasAttemptedPairingRecovery = true
                freshTask.securityGateFailureCount = 0
                freshTask.pairingRecoveryState = .awaitingFreshAdvertisement
                let freshKey = reconnectKey(uuid: freshTask.uuid)
                freshTask.timer?.invalidate()
                freshTask.timer = nil
                cancelPairingRecoveryDiscovery(key: freshKey)
                reconnectTasks[freshKey] = freshTask
                purgeStaleScanCache(uuid: freshTask.uuid, name: freshTask.name)
                startPairingRecoveryDiscoveryIfNeeded(freshTask)
                loggerD(msg: "autoReconnect: \(freshTask.uuid)-\(freshTask.name), manual attempt waits for fresh advertisement sessionGeneration=\(freshTask.sessionGeneration)")
                return BleReconnectActivationResult(
                    target: target,
                    state: .resolved,
                    reason: "freshPairingRecoveryStarted",
                    source: source,
                    sessionGeneration: freshTask.sessionGeneration
                )
            }
            // 3、复用已有 pending owner，或创建同一 Gate 管理的新 attempt。
            let deferredByAppInactivity = activateArmedReconnectTask(task, source: source)
            return BleReconnectActivationResult(
                target: target,
                state: .resolved,
                reason: deferredByAppInactivity ? "appInactiveDeferred" : "",
                source: source,
                sessionGeneration: task.sessionGeneration
            )
        }
    }

    /// 激活一个已经拥有稳定 UUID 的 task；MethodChannel 与扫描身份解析共用此顺序。
    @discardableResult
    private func activateArmedReconnectTask(
        _ task: BleReconnectTask,
        source: BleConnectSource
    ) -> Bool {
        let deferredByAppInactivity = shouldDeferReconnectForAppInactivity(task)
        // 1、已有 admission 时优先判断是否可安全复用当前 pending session。
        let key = reconnectKey(uuid: task.uuid)
        // 自动窗口之间的静默等待由 task.timer 独占。重复 activation 只确认 owner 仍在，
        // 不能提前开始扫描或 retrieve，也不能让共享扫描结果穿过等待门禁。
        if source != .manualReconnect,
           task.pairingRecoveryState == .waitingFreshAdvertisementRetry {
            return deferredByAppInactivity
        }
        if let current = currentConnectionAdmission(uuid: task.uuid) {
            let pendingTeardown = pendingConnectionAdmissionTeardowns[key]
            let currentIsPendingTeardown = pendingTeardown.map {
                $0.admission.generation == current.generation &&
                    $0.admission.sessionId == current.sessionId
            } == true
            if source == .manualReconnect,
               takeOverPeerPairingRecoveryManually(
                   task,
                   current: current,
                   currentIsPendingTeardown: currentIsPendingTeardown
               ) {
                beginReconnectAttempt(uuid: task.uuid)
                return deferredByAppInactivity
            }
            if task.sessionGeneration > current.sessionGeneration {
                // 1.1、更高 Dart session 不能只覆盖 task 元数据：当前 CoreBluetooth
                // admission 和后续回调仍封装旧 session。先建立 exact cancellation
                // barrier，再注册唯一 replacement；真正 connect 会等待旧终态释放。
                if !currentIsPendingTeardown,
                   let session = peripheralConnectionSessions[current.sessionId] {
                    deferConnectionAdmissionReleaseUntilPeripheralTerminal(
                        admission: current,
                        peripheral: session.peripheral,
                        deviceName: session.deviceName,
                        terminalState: .disconnectFromSys
                    )
                    centralManager.cancelPeripheralConnection(session.peripheral)
                }
                loggerD(msg: "autoReconnect: \(task.uuid)-\(task.name), session owner replacement old=\(current.sessionGeneration), incoming=\(task.sessionGeneration), pendingTeardown=\(currentIsPendingTeardown)")
                beginReconnectAttempt(uuid: task.uuid)
                return deferredByAppInactivity
            }
            if source != .manualReconnect || !currentIsPendingTeardown {
                if source == .manualReconnect {
                    // 1.2、手动请求只提升 source；仅超过替换阈值且从未物理接触才允许 barrier 替换。
                    // 默认仅提升同一 pending owner，避免手动点击引入第二条 GATT。
                    // 只有旧 owner 已超过 20 秒且从未收到物理回调，才先走 cancel
                    // barrier 后建立新 generation，给 CoreBluetooth 卡住的 pending 一个
                    // 有界恢复机会。
                    if let session = peripheralConnectionSessions[current.sessionId],
                       replaceStalePendingManualAttemptIfNeeded(session.peripheral) {
                        loggerD(msg: "autoReconnect: \(task.uuid)-\(task.name), manual stale pending replacement requested")
                        beginReconnectAttempt(uuid: task.uuid)
                        return deferredByAppInactivity
                    }
                    _ = promotePendingAttempt(uuid: task.uuid)
                }
                return false
            }
        }
        // 2、cancellation barrier 内的手动请求不能提升即将销毁的旧 session；继续创建
        // 新 generation，并由旧 didDisconnect/watchdog 释放后原子启动。
        beginReconnectAttempt(uuid: task.uuid)
        return deferredByAppInactivity
    }

    /// 手动点击接管正在使用新 peripheral 的自动恢复时，旧自动 admission 必须先进入
    /// cancellation barrier。旧 source 保持 automatic；新手动 attempt 等 CoreBluetooth
    /// teardown 后再连接，避免同一 peripheral 并行 connect 或把迟到 Code 14 误算成手动。
    private func takeOverPeerPairingRecoveryManually(
        _ task: BleReconnectTask,
        current: BleConnectionAdmission,
        currentIsPendingTeardown: Bool
    ) -> Bool {
        guard task.pairingRecoveryState == .foregroundRecoveryConnecting,
              current.source != .manualReconnect else {
            return false
        }
        if !currentIsPendingTeardown,
           let session = peripheralConnectionSessions[current.sessionId] {
            pendingPhysicalConnectWatchdogs.takeIfCurrent(current)?.cancel()
            deferConnectionAdmissionReleaseUntilPeripheralTerminal(
                admission: current,
                peripheral: session.peripheral,
                deviceName: session.deviceName,
                terminalState: .disconnectFromSys
            )
            centralManager.cancelPeripheralConnection(session.peripheral)
        }
        loggerD(msg: "autoReconnect: \(task.uuid)-\(task.name), manual takeover waits for automatic pairing recovery teardown sessionGeneration=\(task.sessionGeneration)")
        return true
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
        guard let task = armReconnectTarget(
            target,
            source: pending.source,
            sessionGeneration: pending.sessionGeneration
        ) else {
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
        // 用户硬取消/移除设备要同时清理无资源的 Code 14 身份标记；否则再次绑定
        // 同一设备时会被错误当成旧配对恢复。
        let persistedTarget = reconnectStore.target(uuid: uuid, name: name)
        if let persistedTarget {
            clearStoppedPeerPairingRecovery(
                belongConfig: persistedTarget.belongConfig,
                name: name.isEmpty ? persistedTarget.name : name
            )
        } else if !name.isEmpty {
            let suffix = "|\(name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
            stoppedPeerPairingRecoveryKeys = Set(
                stoppedPeerPairingRecoveryKeys.filter { !$0.hasSuffix(suffix) }
            )
        }
        // Exhaustion removes the reconnect target before publishing its final
        // state, so a later unbind may only have endpoint UUID/name available.
        reconnectStore.removeSecurityRecoveryRecord(uuid: uuid, name: name)
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
            // Code 14 恢复扫描属于该 owner；硬取消必须同时停止它实际拥有的
            // central scan，不能只丢 timer 后让扫描无限运行。
            cancelPairingRecoveryDiscovery(key: key)
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
        if pairingRecoveryScanTimers.values.contains(where: { $0.ownsScan }) {
            stopScan()
        }
        pairingRecoveryScanTimers.removeAll()
        reconnectTasks.removeAll()
        pendingReconnectIdentities.removeAll()
        stoppedPeerPairingRecoveryKeys.removeAll()
        reconnectIdentityAliases.reset()
    }

    /**
     *  蓝牙关闭时暂停自动回连任务。
     *
     *  poweredOff 不是最终失败，不能把任务标记为 noDeviceFound；等待 poweredOn 后继续调度。
     */
    func pauseReconnectTasksForBluetoothOff() {
        pausePeerPairingRecoveryForBluetoothOff()
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

    /// Bluetooth OFF 会销毁当前 CoreBluetooth attempt。Code 14 扫描/等待必须立即静默，
    /// 但 owner 与已消耗恢复事实继续保留；poweredOn 后从新的 10 秒窗口恢复。
    private func pausePeerPairingRecoveryForBluetoothOff() {
        let recoveryKeys = reconnectTasks.compactMap { key, task in
            task.pairingRecoveryState == .normal ? nil : key
        }
        recoveryKeys.forEach { key in
            cancelPairingRecoveryDiscovery(key: key)
            guard var current = reconnectTasks[key] else { return }
            current.timer?.invalidate()
            current.timer = nil
            current.pairingRecoveryState = .awaitingFreshAdvertisement
            reconnectTasks[key] = current
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

    /// 返回当前进程已持有的 peripheral；inactive 期间只允许复用这些对象，
    /// 禁止通过同步 CoreBluetooth retrieve 获取新对象。
    private func inMemoryReconnectPeripheral(_ task: BleReconnectTask) -> CBPeripheral? {
        if let connected = connectedDevices.first(where: { device in
            isSameConnectTarget(
                storedUuid: device.peripheral.identifier.uuidString,
                storedName: device.peripheral.name ?? "",
                uuid: task.uuid,
                name: task.name
            )
        })?.peripheral {
            return connected
        }
        if let sessionPeripheral = peripheralConnectionSessions.values.first(where: { session in
            isSameConnectTarget(
                storedUuid: session.admission.endpointId,
                storedName: session.deviceName,
                uuid: task.uuid,
                name: task.name
            )
        })?.peripheral {
            return sessionPeripheral
        }
        return scanResultTemp.first(where: { entry in
            isSameConnectTarget(
                storedUuid: entry.0.uuid,
                storedName: entry.0.name.isEmpty ? (entry.1.name ?? "") : entry.0.name,
                uuid: task.uuid,
                name: task.name
            )
        })?.1
    }

    /// inactive/background/terminating 只在没有内存 peripheral 时 defer。
    /// 这不是失败 attempt，不递增 retry，不发布 noDeviceFound，也不删除长期 owner。
    private func shouldDeferReconnectForAppInactivity(_ task: BleReconnectTask) -> Bool {
        !allowsSynchronousCoreBluetoothLookup && inMemoryReconnectPeripheral(task) == nil
    }

    /// 把 exact reconnect task 标记为等待前台；旧 generation 或已取消 owner 无法写回。
    private func deferReconnectTaskForAppInactivity(
        _ task: BleReconnectTask,
        context: String
    ) {
        let key = reconnectKey(uuid: task.uuid)
        guard var current = reconnectTasks[key],
              current.sessionGeneration == task.sessionGeneration,
              current.belongConfig == task.belongConfig else {
            loggerD(msg: "appLifecycle: ignore stale reconnect defer uuid=\(task.uuid), sessionGeneration=\(task.sessionGeneration), context=\(context)")
            return
        }
        current.timer?.invalidate()
        current.timer = nil
        current.deferredByAppInactivity = true
        reconnectTasks[key] = current
        loggerD(msg: "appLifecycle: reconnect deferred uuid=\(current.uuid), name=\(current.name), sessionGeneration=\(current.sessionGeneration), context=\(context)")
    }

    /// didBecomeActive 后补偿 name-only system-connected identity。每个快照在查询前后都
    /// 复验当前 owner，避免取消、替换 generation 或配置撤销后被旧补偿复活。
    private func resolveAppInactivePendingIdentities() {
        guard allowsSynchronousCoreBluetoothLookup else { return }
        let deferredPending = Array(pendingReconnectIdentities.values)
        for pending in deferredPending {
            guard let currentPending = pendingReconnectIdentities[pending.key],
                  currentPending.sessionGeneration == pending.sessionGeneration,
                  currentPending.belongConfig == pending.belongConfig,
                  currentPending.name == pending.name,
                  let config = bleConfigs.first(where: {
                      $0.name == pending.belongConfig && $0.autoReconnect
                  }),
                  let peripheral = findPeripheralFromConnected(
                      uuid: "",
                      name: pending.name,
                      serviceUUIDs: config.privateServices.map { $0.serviceUUID },
                      requireUniqueMatch: true
                  ),
                  let revalidated = pendingReconnectIdentities[pending.key],
                  revalidated.sessionGeneration == pending.sessionGeneration,
                  revalidated.source == pending.source,
                  revalidated.expectedMacSuffix == pending.expectedMacSuffix,
                  allowsSynchronousCoreBluetoothLookup else {
                continue
            }
            loggerD(msg: "appLifecycle: resolve deferred identity config=\(pending.belongConfig), name=\(pending.name), uuid=\(peripheral.identifier.uuidString), sessionGeneration=\(pending.sessionGeneration)")
            _ = resolvePendingReconnectIdentity(
                peripheral: peripheral,
                advertisedName: pending.name,
                belongConfig: pending.belongConfig,
                rssi: 0
            )
        }
    }

    /// didBecomeActive 后只恢复仍是当前 exact generation 的 UUID owner。task 已取消、
    /// session 已替换或 config 授权已撤销时直接跳过，不创建新 GATT attempt。
    private func resumeAppInactiveDeferredReconnects() {
        guard allowsSynchronousCoreBluetoothLookup else { return }
        let deferredTasks = reconnectTasks.values.filter { $0.deferredByAppInactivity }
        for deferred in deferredTasks {
            let key = reconnectKey(uuid: deferred.uuid)
            guard var current = reconnectTasks[key],
                  current.deferredByAppInactivity,
                  current.sessionGeneration == deferred.sessionGeneration,
                  current.belongConfig == deferred.belongConfig,
                  bleConfigs.contains(where: {
                      $0.name == current.belongConfig && $0.autoReconnect
                  }) else {
                continue
            }
            current.deferredByAppInactivity = false
            reconnectTasks[key] = current
            loggerD(msg: "appLifecycle: resume deferred reconnect uuid=\(current.uuid), name=\(current.name), sessionGeneration=\(current.sessionGeneration)")
            activateArmedReconnectTask(current, source: current.source)
        }
    }

    /// App 不再 active 时，Code 14 专用扫描和 5 秒 timer 都必须立即停下。owner、session
    /// 和恢复事实保持不变；didBecomeActive 只恢复仍通过 config/generation 复验的任务。
    private func pausePeerPairingRecoveryForAppInactivity(reason: String) {
        let recoveryKeys = reconnectTasks.compactMap { key, task in
            switch task.pairingRecoveryState {
            case .awaitingFreshAdvertisement, .waitingFreshAdvertisementRetry:
                return key
            case .normal, .foregroundRecoveryConnecting:
                return nil
            }
        }
        recoveryKeys.forEach { key in
            cancelPairingRecoveryDiscovery(key: key)
            guard var current = reconnectTasks[key] else { return }
            current.timer?.invalidate()
            current.timer = nil
            current.pairingRecoveryState = .awaitingFreshAdvertisement
            current.deferredByAppInactivity = true
            reconnectTasks[key] = current
            loggerD(msg: "freshAdvertisementRecoveryPaused owner=\(current.uuid), sessionGeneration=\(current.sessionGeneration), reason=\(reason)")
        }
    }

    /**
     *  App 即将回到前台时补偿恢复暂停任务。
     *
     *  iOS 后台期间 CoreBluetooth 状态回调可能早于 Dart 恢复完成，这里只触发原生任务检查。
     */
    @objc func handleAppWillEnterForeground() {
        resumeReconnectTasksIfBluetoothOn(reason: "willEnterForeground")
    }

    /// resign active 是退出/锁屏/系统遮挡的最早边界；立即关闭同步 XPC 查询门禁。
    @objc func handleAppWillResignActive() {
        allowsSynchronousCoreBluetoothLookup = false
        pausePeerPairingRecoveryForAppInactivity(reason: "willResignActive")
        loggerD(msg: "appLifecycle: synchronous CoreBluetooth lookup disabled reason=willResignActive")
    }

    /// background 再次 fail-close，覆盖通知乱序或冷启动恢复路径。
    @objc func handleAppDidEnterBackground() {
        allowsSynchronousCoreBluetoothLookup = false
        pausePeerPairingRecoveryForAppInactivity(reason: "didEnterBackground")
        loggerD(msg: "appLifecycle: synchronous CoreBluetooth lookup disabled reason=didEnterBackground")
    }

    /// 进程退出宽限期绝不允许同步 retrieve 阻塞主线程。
    @objc func handleAppWillTerminate() {
        allowsSynchronousCoreBluetoothLookup = false
        pausePeerPairingRecoveryForAppInactivity(reason: "willTerminate")
        loggerD(msg: "appLifecycle: synchronous CoreBluetooth lookup disabled reason=willTerminate")
    }

    /**
     *  App 激活后补偿恢复暂停任务。
     *
     *  与 willEnterForeground 互补，覆盖从 push / 普通打开进入 active 的不同路径。
     */
    @objc func handleAppDidBecomeActive() {
        allowsSynchronousCoreBluetoothLookup = true
        // name-only owner 先尝试接管 ANCS/system-connected identity，再恢复 UUID owner；
        // 两条路径都复用原有 pending/Gate，不增加 MethodChannel 状态或 retry。
        resolveAppInactivePendingIdentities()
        resumeAppInactiveDeferredReconnects()
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
        // 1、先确认终态属于可恢复类型，再加载长期 task/config。
        guard shouldScheduleReconnect(state: state) else {
            return
        }
        guard var task = reconnectTasks[reconnectKey(uuid: uuid)] ??
                reconnectTasks.values.first(where: { isSameConnectTarget(storedUuid: $0.uuid, storedName: $0.name, uuid: uuid, name: name) }) else {
            // 没有 armed task 说明业务尚未确认 connected，原生不能自行接管长期回连。
            return
        }
        // 2、终态后默认恢复 autoReconnect source；显式提升只保留当前 attempt 来源。
        if !preserveAttemptSource {
            task.source = BleReconnectSourcePolicy.afterTerminalAttempt()
        }
        guard let config = bleConfigs.first(where: { $0.name == task.belongConfig }), config.autoReconnect else {
            // 配置被移除或关闭后，旧任务只保留日志，不再调度。
            return
        }
        guard !upgradeStateRegistry.contains(uuid) else {
            // OTA/升级态由升级流程控制连接，避免自动回连打断升级状态机。
            return
        }
        // 3、蓝牙不可用只记录暂停，poweredOn 后继续，不取消长期 intent。
        guard centralManager.state == .poweredOn else {
            task.pausedByBluetoothOff = true
            reconnectTasks[reconnectKey(uuid: task.uuid)] = task
            loggerD(msg: "autoReconnect: \(task.uuid), paused because bluetooth is unavailable")
            return
        }
        if shouldDeferReconnectForAppInactivity(task) {
            deferReconnectTaskForAppInactivity(task, context: "scheduleReconnect \(state.rawValue)")
            return
        }
        // 4、已有 peripheral 时交给 CoreBluetooth pending connect；无 identity 时才防抖重试。
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
            // CoreBluetooth pending connect is the long-wait reconnect rendezvous.
            // A short scan/connect timeout would cancel the only system-owned pending point.
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
     *  这里复用直连/Gate 流程，让主动连接和自动回连最终进入同一套 GATT pipeline。
     */
    func beginReconnectAttempt(uuid: String) {
        // 1、校验 task/config/蓝牙状态，旧 timer 或取消后的回调直接失效。
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
        if shouldDeferReconnectForAppInactivity(task) {
            deferReconnectTaskForAppInactivity(task, context: "beginReconnectAttempt")
            return
        }
        // attempt 只用于退避和日志，不再作为停止条件。自动回连是业务 connected 后建立的
        // 持续意图，不能因为设备离开较久或多次 timeout 被 native 主动放弃。
        // 2、递增日志 attempt，不把次数作为长期 autoReconnect 的停止条件。
        task.attempt = nextReconnectAttemptCount(task.attempt)
        task.timer?.invalidate()
        task.timer = nil
        task.deferredByAppInactivity = false
        reconnectTasks[key] = task
        loggerD(msg: "autoReconnect: \(task.uuid)-\(task.name), attempt \(task.attempt), native pending connect")
        // 回连不再复用会发 connecting/启动短超时的前台 connect 路由。
        // 只从 CoreBluetooth 缓存/同时扫描结果取 peripheral，然后立即建立 pending 直连。
        beginDirectReconnectAttempt(task: task, config: config)
    }

    /// 构造一条不经扫描前置、不提前起超时的 CoreBluetooth pending connect。
    func beginDirectReconnectAttempt(task: BleReconnectTask, config: BleConfig) {
        // 1、先以真实物理连接状态短路，避免重复建立 GATT。
        // 不能只看业务缓存 isConnected：断连后 retrieve 可能保留同 UUID 的
        // 旧 CBPeripheral 实例。只有物理连接仍在时才短路，否则必须重建系统 pending connect。
        if let connected = businessConnectedCacheDevice(uuid: task.uuid) {
            armReconnectTask(device: connected, source: .autoReconnect, businessConnected: true)
            return
        }
        // 2、Code 14 后等待新广播阶段禁止 retrieve 旧 peripheral。5 秒间隔由专用
        // timer 唯一推进；任何其它重入都必须保持静默。
        if task.pairingRecoveryState == .waitingFreshAdvertisementRetry {
            return
        }
        if task.pairingRecoveryState == .awaitingFreshAdvertisement {
            startPairingRecoveryDiscoveryIfNeeded(task)
            return
        }
        let cachedPeripheral: CBPeripheral? = {
            // Code 14 后必须优先消费本轮 didDiscover 写入的 peripheral，而不是先从
            // retrievePeripherals 取回刚被 iOS 拒绝的旧缓存对象。
            if task.pairingRecoveryState == .foregroundRecoveryConnecting,
               let discovered = scanResultTemp.first(where: {
                   $0.0.uuid.caseInsensitiveCompare(task.uuid) == .orderedSame ||
                       (!task.name.isEmpty && ($0.0.name == task.name || $0.1.name == task.name))
               })?.1 {
                return discovered
            }
            if !allowsSynchronousCoreBluetoothLookup,
               let held = inMemoryReconnectPeripheral(task) {
                loggerD(msg: "appLifecycle: reuse in-memory peripheral while inactive uuid=\(held.identifier.uuidString), owner=\(task.uuid)")
                return held
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
               let retrieved = retrievePeripheralsWhenAppActive(
                   withIdentifiers: [identifier],
                   context: "auto reconnect by UUID"
               ).first {
                return retrieved
            }
            return scanResultTemp.first(where: {
                $0.0.uuid.caseInsensitiveCompare(task.uuid) == .orderedSame ||
                    (!task.name.isEmpty && ($0.0.name == task.name || $0.1.name == task.name))
            })?.1
        }()
        guard let peripheral = cachedPeripheral else {
            guard allowsSynchronousCoreBluetoothLookup else {
                deferReconnectTaskForAppInactivity(
                    task,
                    context: "beginDirectReconnectAttempt no in-memory peripheral"
                )
                return
            }
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
            source: activeTask.source,
            sessionGeneration: activeTask.sessionGeneration
        ) != nil else {
            return
        }
        let usesSystemAutoReconnect = activeTask.pairingRecoveryState != .foregroundRecoveryConnecting
        connectPeripheralAfterCancellationBarrier(
            peripheral,
            autoReconnect: usesSystemAutoReconnect
        )
        loggerD(msg: "autoReconnect: \(activeTask.uuid)-\(activeTask.name), native pending connect activated source=\(activeTask.source.rawValue), pairingRecovery=\(activeTask.pairingRecoveryState.rawValue), sessionGeneration=\(activeTask.sessionGeneration)")
    }

    /// 记录一次 Code 14。只有被动自动回连的首次失败允许一次新鲜广播恢复；
    /// 手动连接或恢复 attempt 再次失败都立即结束 owner，由下一次手动点击重建。
    @discardableResult
    func registerPeerPairingFailure(
        uuid: String,
        name: String,
        source: BleConnectSource
    ) -> BlePeerPairingFailureAction? {
        guard let key = reconnectTasks.first(where: { _, task in
            isSameConnectTarget(
                storedUuid: task.uuid,
                storedName: task.name,
                uuid: uuid,
                name: name
            )
        })?.key,
        var task = reconnectTasks[key] else {
            return nil
        }
        if source == .manualReconnect || task.hasAttemptedPairingRecovery {
            if source != .manualReconnect && task.hasAttemptedPairingRecovery {
                loggerE(msg: "freshPeripheralStillRejectedPairing owner=\(task.uuid), sessionGeneration=\(task.sessionGeneration)")
            }
            stopPeerPairingRecoveryTask(
                task,
                reason: source == .manualReconnect
                    ? "manualCode14"
                    : "automaticRecoveryCode14"
            )
            return .stopAttempt
        }
        task.hasAttemptedPairingRecovery = true
        task.pairingRecoveryState = .awaitingFreshAdvertisement
        reconnectTasks[key] = task
        // 删除本轮命中的广告缓存，确保恢复连接确实等待 error 之后的新广告。
        purgeStaleScanCache(uuid: task.uuid, name: task.name)
        loggerD(msg: "autoReconnect: \(task.uuid)-\(task.name), peer pairing reset; wait fresh advertisement before recovery")
        return .retryFreshAdvertisement
    }

    /// 新鲜 peripheral 若出现非 Code 14 的物理失败，说明本轮没有再次证明配对信息失配。
    /// 清除专用阶段后交回普通 persistent autoReconnect；不得写 stopped marker。
    func resetPeerPairingRecoveryAfterNonPairingFailure(
        uuid: String,
        name: String
    ) {
        guard let key = reconnectTasks.first(where: { _, task in
            isSameConnectTarget(
                storedUuid: task.uuid,
                storedName: task.name,
                uuid: uuid,
                name: name
            )
        })?.key,
        var task = reconnectTasks[key],
        task.pairingRecoveryState == .foregroundRecoveryConnecting else {
            return
        }
        task.timer?.invalidate()
        task.timer = nil
        task.pairingRecoveryState = .normal
        task.hasAttemptedPairingRecovery = false
        reconnectTasks[key] = task
        purgeStaleScanCache(uuid: task.uuid, name: task.name)
        loggerD(msg: "autoReconnect: \(task.uuid)-\(task.name), non-Code14 terminal exits fresh peripheral recovery; security gate budget preserved=\(task.securityGateFailureCount)")
    }

    /// Records a real iOS 5403 protected-write security failure for the active
    /// endpoint. Attempts 1...4 reuse the existing fresh-advertisement recovery;
    /// attempt 5 silently retires this automatic owner and lets Dart stop UI noise.
    @discardableResult
    func registerSecurityGateFailure(
        uuid: String,
        name: String,
        source: BleConnectSource
    ) -> BlePeerPairingFailureAction? {
        guard let key = reconnectTasks.first(where: { _, task in
            isSameConnectTarget(
                storedUuid: task.uuid,
                storedName: task.name,
                uuid: uuid,
                name: name
            )
        })?.key,
        var task = reconnectTasks[key] else {
            return nil
        }
        let action = BlePeerPairingRecoveryPolicy.actionAfterSecurityGateFailure(
            source: source,
            failureCount: task.securityGateFailureCount + 1
        )
        if action == .stopAttempt {
            stopPeerPairingRecoveryTask(task, reason: "manualSecurityGateFailure")
            return .stopAttempt
        }
        let persistedFailureCount = reconnectStore.securityRecoveryRecord(
            belongConfig: task.belongConfig,
            name: task.name
        )?.failureCount ?? 0
        task.securityGateFailureCount = min(
            max(task.securityGateFailureCount, persistedFailureCount) + 1,
            BlePeerPairingRecoveryPolicy.maxSecurityGateAttempts
        )
        let failureCount = task.securityGateFailureCount
        // Persist before any cancellation or owner mutation so a process exit
        // cannot reopen an already consumed attempt on the next cold start.
        reconnectStore.upsertSecurityRecoveryRecord(
            belongConfig: task.belongConfig,
            name: task.name,
            uuid: task.uuid,
            failureCount: failureCount
        )
        let automaticAction = BlePeerPairingRecoveryPolicy.actionAfterSecurityGateFailure(
            source: source,
            failureCount: failureCount
        )
        if automaticAction == .securityRecoveryExhausted {
            loggerE(msg: "securityRecoveryExhausted owner=\(task.uuid), sessionGeneration=\(task.sessionGeneration), attempts=\(failureCount)")
            // The durable stop record remains after the physical target is
            // retired; only success, manual activation, unbind, or target reset
            // may clear it.
            reconnectStore.remove(uuid: task.uuid, name: task.name)
            stopPeerPairingRecoveryTask(task, reason: "securityRecoveryExhausted")
            return .securityRecoveryExhausted
        }
        task.hasAttemptedPairingRecovery = true
        task.pairingRecoveryState = .awaitingFreshAdvertisement
        reconnectTasks[key] = task
        purgeStaleScanCache(uuid: task.uuid, name: task.name)
        loggerD(msg: "autoReconnect: \(task.uuid)-\(task.name), security gate failure \(failureCount)/\(BlePeerPairingRecoveryPolicy.maxSecurityGateAttempts); wait fresh advertisement")
        return .retryFreshAdvertisement
    }

    /// Passing 5403 proves the current automatic episode has repaired security.
    /// Reset the budget without touching unrelated reconnect ownership.
    func resetSecurityGateRecoveryAfterSuccess(uuid: String, name: String) {
        guard let key = reconnectTasks.first(where: { _, task in
            isSameConnectTarget(
                storedUuid: task.uuid,
                storedName: task.name,
                uuid: uuid,
                name: name
            )
        })?.key,
        var task = reconnectTasks[key],
        task.securityGateFailureCount != 0 ||
            task.pairingRecoveryState != .normal ||
            task.hasAttemptedPairingRecovery else {
            return
        }
        task.securityGateFailureCount = 0
        task.pairingRecoveryState = .normal
        task.hasAttemptedPairingRecovery = false
        reconnectTasks[key] = task
        clearStoppedPeerPairingRecovery(
            belongConfig: task.belongConfig,
            name: task.name
        )
        loggerD(msg: "autoReconnect: \(task.uuid)-\(task.name), security gate recovery reset after success")
    }

    /// 取消某个 owner 的配对恢复扫描。只有该 owner 自己启动的扫描才允许停止，
    /// 避免抢占 Discovery/其它恢复批次共享的 central scan。
    func cancelPairingRecoveryDiscovery(key: String) {
        guard let entry = pairingRecoveryScanTimers.removeValue(forKey: key) else { return }
        entry.timer.invalidate()
        if entry.ownsScan {
            stopScan()
        }
    }

    /// 自动窗口 miss 后只保留 owner 并等待 5 秒；timer 回调必须复验 config、session、
    /// 蓝牙和 App active。等待阶段使用独立状态，明确禁止消费共享扫描结果。
    private func schedulePairingRecoveryRetry(_ task: BleReconnectTask) {
        let key = reconnectKey(uuid: task.uuid)
        guard var current = reconnectTasks[key],
              current.sessionGeneration == task.sessionGeneration,
              current.belongConfig == task.belongConfig,
              current.source != .manualReconnect,
              current.pairingRecoveryState == .awaitingFreshAdvertisement else {
            return
        }
        current.timer?.invalidate()
        current.pairingRecoveryState = .waitingFreshAdvertisementRetry
        let expectedSessionGeneration = current.sessionGeneration
        let expectedConfig = current.belongConfig
        current.timer = Timer.scheduledTimer(
            withTimeInterval: pairingRecoveryRetryDelay,
            repeats: false
        ) { [weak self] _ in
            guard let self = self,
                  var resumed = self.reconnectTasks[key],
                  resumed.sessionGeneration == expectedSessionGeneration,
                  resumed.belongConfig == expectedConfig,
                  resumed.source != .manualReconnect,
                  resumed.pairingRecoveryState == .waitingFreshAdvertisementRetry,
                  self.bleConfigs.contains(where: {
                      $0.name == expectedConfig && $0.autoReconnect
                  }) else {
                return
            }
            resumed.timer = nil
            guard self.centralManager.state == .poweredOn else {
                resumed.pausedByBluetoothOff = true
                resumed.pairingRecoveryState = .awaitingFreshAdvertisement
                self.reconnectTasks[key] = resumed
                return
            }
            guard self.allowsSynchronousCoreBluetoothLookup else {
                resumed.deferredByAppInactivity = true
                resumed.pairingRecoveryState = .awaitingFreshAdvertisement
                self.reconnectTasks[key] = resumed
                return
            }
            resumed.pairingRecoveryState = .awaitingFreshAdvertisement
            self.reconnectTasks[key] = resumed
            self.startPairingRecoveryDiscoveryIfNeeded(resumed)
        }
        reconnectTasks[key] = current
        loggerD(msg: "freshAdvertisementRetryScheduled owner=\(current.uuid), sessionGeneration=\(current.sessionGeneration), scanWindow=\(Int(automaticPairingRecoveryScanWindow))s, retryDelay=\(Int(pairingRecoveryRetryDelay))s")
    }

    /// 在已有扫描上共享窗口；只有本任务主动开的扫描，超时才允许停止，避免抢占其他业务扫描。
    private func startPairingRecoveryDiscoveryIfNeeded(_ task: BleReconnectTask) {
        let key = reconnectKey(uuid: task.uuid)
        guard pairingRecoveryScanTimers[key] == nil,
              let current = reconnectTasks[key],
              current.sessionGeneration == task.sessionGeneration,
              current.belongConfig == task.belongConfig,
              current.pairingRecoveryState == .awaitingFreshAdvertisement,
              bleConfigs.contains(where: {
                  $0.name == current.belongConfig && $0.autoReconnect
              }) else {
            return
        }
        guard centralManager.state == .poweredOn else {
            var paused = current
            paused.pausedByBluetoothOff = true
            reconnectTasks[key] = paused
            return
        }
        guard allowsSynchronousCoreBluetoothLookup else {
            deferReconnectTaskForAppInactivity(
                current,
                context: "peer pairing recovery scan"
            )
            return
        }
        let ownsScan = !centralManager.isScanning
        if ownsScan {
            startScan()
        }
        let scanWindow = current.source == .manualReconnect
            ? manualPairingRecoveryScanWindow
            : automaticPairingRecoveryScanWindow
        let expectedSessionGeneration = current.sessionGeneration
        let timer = Timer.scheduledTimer(withTimeInterval: scanWindow, repeats: false) { [weak self] _ in
            guard let self = self,
                  let activeEntry = self.pairingRecoveryScanTimers[key],
                  activeEntry.sessionGeneration == expectedSessionGeneration,
                  let current = self.reconnectTasks[key],
                  current.sessionGeneration == expectedSessionGeneration,
                  current.pairingRecoveryState == .awaitingFreshAdvertisement else {
                return
            }
            self.pairingRecoveryScanTimers.removeValue(forKey: key)
            if activeEntry.ownsScan {
                self.stopScan()
            }
            switch BlePeerPairingRecoveryPolicy.actionAfterWindowMiss(
                source: current.source
            ) {
            case .retryAfterDelay:
                // 自动 miss 不是连接终态：不删除 owner、不发 Flutter 状态，也不制造
                // attempt 0；只在本 owner 的静默间隔后重新打开窗口。
                self.loggerD(msg: "freshAdvertisementWindowMissed owner=\(current.uuid), sessionGeneration=\(current.sessionGeneration), scanWindow=\(Int(scanWindow))s")
                self.schedulePairingRecoveryRetry(current)
            case .finishManualAttempt:
                // 手动扫描未命中沿用原有 noDeviceFound 失败路径，且不能伪装成 Code 14。
                self.stopPeerPairingRecoveryTask(current, reason: "manualFreshAdvertisementTimeout")
                self.handleConnectState(
                    uuid: current.uuid,
                    name: current.name,
                    state: .noDeviceFound,
                    source: current.source,
                    generation: current.sessionGeneration,
                    suppressReconnectSchedule: true,
                    tag: "manual peer pairing recovery scan timeout"
                )
            }
        }
        pairingRecoveryScanTimers[key] = (timer, ownsScan, expectedSessionGeneration)
        loggerD(msg: "autoReconnect: \(current.uuid)-\(current.name), start peer pairing recovery scan ownsScan=\(ownsScan), sessionGeneration=\(expectedSessionGeneration), window=\(Int(scanWindow))s")
    }

    /// 仅精确名称/配置命中的新广告可以解除 Code 14 恢复门禁；这样附近同型号设备不会抢占 owner。
    @discardableResult
    func resumePeerPairingRecoveryIfMatched(
        peripheral: CBPeripheral,
        advertisedName: String,
        belongConfig: String,
        advertisedMac: String,
        rssi: Int
    ) -> Bool {
        guard allowsSynchronousCoreBluetoothLookup,
              centralManager.state == .poweredOn,
              let entry = reconnectTasks.first(where: { key, task in
            task.pairingRecoveryState == .awaitingFreshAdvertisement &&
                !task.deferredByAppInactivity &&
                !task.pausedByBluetoothOff &&
                pairingRecoveryScanTimers[key]?.sessionGeneration == task.sessionGeneration &&
                task.belongConfig == belongConfig &&
                !task.name.isEmpty &&
                task.name == advertisedName
        }), var task = reconnectTasks[entry.key] else {
            return false
        }
        // 完整广播名是主身份；当持久 target 和本次广告都能提供 MAC 时，再用
        // 后缀做附加校验。任一侧缺失时不伪造约束，保持历史 R1 广播兼容。
        let expectedMacSuffix = reconnectStore
            .target(uuid: task.uuid, name: task.name)?
            .expectedMacSuffix
            .filter(\.isHexDigit)
            .uppercased() ?? ""
        let normalizedAdvertisedMac = advertisedMac
            .filter(\.isHexDigit)
            .uppercased()
        if !expectedMacSuffix.isEmpty,
           !normalizedAdvertisedMac.isEmpty,
           !normalizedAdvertisedMac.hasSuffix(expectedMacSuffix) {
            loggerD(msg: "autoReconnect: \(task.uuid)-\(task.name), ignore fresh advertisement with mismatched mac suffix")
            return false
        }
        if let scanEntry = pairingRecoveryScanTimers.removeValue(forKey: entry.key) {
            scanEntry.timer.invalidate()
            if scanEntry.ownsScan {
                stopScan()
            }
        }
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
        task.pairingRecoveryState = .foregroundRecoveryConnecting
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
            source: .autoReconnect,
            sessionGeneration: task.sessionGeneration
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
                name: peripheralName,
                expectedMacSuffix: reconnectStore
                    .target(uuid: task.uuid, name: task.name)?
                    .expectedMacSuffix ?? ""
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
            // iOS 17 以下仍保留普通 pending connect；下次 App 启动会通过冷启动流程重新激活。
            centralManager.connect(peripheral)
        }
    }
}
