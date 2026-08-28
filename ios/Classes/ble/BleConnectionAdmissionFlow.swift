import CoreBluetooth
import Foundation

/// 陈旧 pre-didConnect request 的受控替换来源；来源只影响准入边界与日志，
/// 不改变原 reconnect task 的业务 source/generation 归属。
enum BleStalePendingReplacementTrigger: String {
    case manualReconnect
    case visibleAutoReconnect
}

/**
 * iOS CoreBluetooth 连接的全局准入流程。
 *
 * 物理 connect 可以同时 pending，但 service/characteristic/notify/业务鉴权从
 * `didConnect` 起只允许一个 endpoint 运行。Gate 排队时间不计入 connectTimeout。
 */
extension BleManager {
    private var peripheralCancellationBarrierTimeout: TimeInterval { 2.0 }
    // UI 的一分钟展示与 native 长期回连解耦；这里的一分钟只观察自动回连，
    // 普通前台连接才允许回收静默的 pre-didConnect attempt。
    private var pendingPhysicalConnectWatchdogTimeout: TimeInterval { 60.0 }
    // 手动接管正常应只提升 pending owner；超过一个辅助扫描窗口仍无任何物理回调时，
    // 才允许通过 cancellation barrier 替换卡住的 CoreBluetooth pending connect。
    private var manualPendingReplacementThreshold: TimeInterval { 20.0 }

    /// 同一 CoreBluetooth UUID 在本进程内只能有一个连接缓存 owner。iOS 在蓝牙恢复、
    /// retrieve 后可能返回新的 CBPeripheral 实例，不能再用对象引用判重，
    /// 否则旧实例的 `isConnected=true` 会把实际已经断开的回连短路掉。
    func connectionCacheIndexes(uuid: String, name: String = "") -> [Int] {
        guard uuid.isNotEmpty || name.isNotEmpty else { return [] }
        return connectedDevices.indices.filter { index in
            let device = connectedDevices[index]
            if uuid.isNotEmpty {
                return device.peripheral.identifier.uuidString == uuid
            }
            return device.peripheral.name == name
        }
    }

    /// 只有业务缓存和 CoreBluetooth 都确认 connected 时，才允许跳过新的 pending connect。
    /// 物理状态已断开的陈旧条目会先失效，保证断连后的长期 autoReconnect 一定能继续下发。
    func businessConnectedCacheDevice(uuid: String) -> BleConnectedDevice? {
        let indexes = connectionCacheIndexes(uuid: uuid)
        guard indexes.isNotEmpty else { return nil }

        var staleConnectedIndexes: [Int] = []
        var physicallyConnectedDevice: BleConnectedDevice?
        for index in indexes {
            let device = connectedDevices[index]
            if device.isConnected, device.peripheral.state == .connected {
                if physicallyConnectedDevice == nil {
                    physicallyConnectedDevice = device
                }
            } else if device.isConnected {
                staleConnectedIndexes.append(index)
            }
        }

        for index in staleConnectedIndexes {
            var stale = connectedDevices[index]
            stale.isConnected = false
            stale.isBleFlowCompleted = false
            stale.readCharsNotify = 0
            stale.notifiedReadCharUUIDs.removeAll()
            connectedDevices[index] = stale
        }
        if indexes.count > 1 || staleConnectedIndexes.isNotEmpty {
            loggerD(msg: "connection cache: \(uuid), entries=\(indexes.count), staleBusinessConnected=\(staleConnectedIndexes.count), physicalConnected=\(physicallyConnectedDevice != nil)")
        }
        return physicallyConnectedDevice
    }

    /// 新一代 pending connect 只能保留当前 peripheral 的缓存。先按稳定 UUID 替换，防止
    /// retrieve 返回的新对象与旧对象并存，让终态更新第一个条目、回连短路命中另一个条目。
    func replaceConnectionCache(
        peripheral: CBPeripheral,
        config: BleConfig,
        reason: String
    ) {
        let uuid = peripheral.identifier.uuidString
        let removedCount = connectionCacheIndexes(uuid: uuid).count
        connectedDevices.removeAll { $0.peripheral.identifier.uuidString == uuid }
        connectedDevices.append(BleConnectedDevice(belongConfig: config, peripheral: peripheral))
        if removedCount > 0 {
            loggerD(msg: "connection cache: \(uuid), replace entries=\(removedCount), reason=\(reason)")
        }
    }

    /// central.connect 发出后开始 attempt-scoped watchdog；自动回连必须保留系统长期请求。
    func startPendingPhysicalConnectWatchdog(
        _ peripheral: CBPeripheral,
        admission: BleConnectionAdmission,
        autoReconnect: Bool
    ) {
        let mode = BlePendingPhysicalConnectWatchdogMode.resolve(
            autoReconnect: autoReconnect
        )
        let workItem = DispatchWorkItem { [weak self, weak peripheral] in
            guard let self = self, let peripheral = peripheral else { return }
            self.expirePendingPhysicalConnectWatchdog(
                peripheral,
                expectedAdmission: admission,
                mode: mode
            )
        }
        pendingPhysicalConnectWatchdogs
            .replace(admission: admission, workItem: workItem)?
            .cancel()
        DispatchQueue.main.asyncAfter(
            deadline: .now() + pendingPhysicalConnectWatchdogTimeout,
            execute: workItem
        )
        loggerD(msg: "admission gate: \(admission.endpointId), start pending physical watchdog generation=\(admission.generation), mode=\(mode)")
    }

    /// 只允许 exact generation/session 处理超时；自动回连超时只消费观察 timer。
    private func expirePendingPhysicalConnectWatchdog(
        _ peripheral: CBPeripheral,
        expectedAdmission: BleConnectionAdmission,
        mode: BlePendingPhysicalConnectWatchdogMode
    ) {
        guard pendingPhysicalConnectWatchdogs.takeIfCurrent(expectedAdmission) != nil,
              let admission = currentConnectionAdmission(expectedAdmission),
              let session = peripheralConnectionSessions[admission.sessionId],
              session.peripheral === peripheral else {
            return
        }
        if peripheral.state == .connected {
            // 极端情况下 CoreBluetooth 状态已更新但 delegate 回调丢失，直接交给同一 Gate。
            loggerD(msg: "admission gate: \(admission.endpointId), pending watchdog observed connected generation=\(admission.generation)")
            enqueuePhysicalConnectionThroughGate(peripheral)
            return
        }

        switch mode {
        case .observeLongLivedAutoReconnect:
            // CoreBluetooth 会在设备重新进入范围后完成同一个 pending connect；每分钟
            // cancel/reconnect 会重置系统 rendezvous，造成刚开屏蔽箱仍需再等一轮。
            loggerD(msg: "admission gate: \(admission.endpointId), auto reconnect pending beyond watchdog; keep CoreBluetooth request generation=\(admission.generation)")
            return
        case .recycleForegroundAttempt:
            loggerD(msg: "admission gate: \(admission.endpointId), foreground pending physical connect watchdog elapsed")
        }

        // 普通前台 attempt 先移除 request，再建立 cancellation barrier。有长期 owner
        // 时由既有调度器继续自动回连；无 owner 时只清理本代，不会偷偷恢复回连。
        removeActiveConnectRequest(uuid: admission.endpointId, name: session.deviceName)
        deferConnectionAdmissionReleaseUntilPeripheralTerminal(
            admission: admission,
            peripheral: peripheral,
            deviceName: session.deviceName,
            terminalState: .disconnectFromSys
        )
        centralManager.cancelPeripheralConnection(peripheral)
        loggerD(msg: "admission gate: \(admission.endpointId), pending watchdog cleanup generation=\(admission.generation), state=\(peripheral.state.rawValue)")
    }

    func hasPeripheralCancellationBarrier(_ peripheral: CBPeripheral) -> Bool {
        peripheralCancellationBarrierGate.isBlocking(
            endpointId: peripheral.identifier.uuidString
        )
    }

    /// 发出 hard cancel 前建立 barrier，阻止同 CBPeripheral 的新 attempt 被旧终态回调误杀。
    func beginPeripheralCancellationBarrier(_ peripheral: CBPeripheral) {
        let key = reconnectKey(uuid: peripheral.identifier.uuidString)
        guard let barrier = peripheralCancellationBarrierGate.begin(
            endpointId: peripheral.identifier.uuidString
        ) else {
            return
        }
        guard barrier.isNew else {
            loggerD(msg: "admission gate: \(peripheral.identifier.uuidString), reuse cancellation barrier=\(barrier.token)")
            return
        }
        let workItem = DispatchWorkItem { [weak self, weak peripheral] in
            guard let self = self, let peripheral = peripheral else { return }
            self.expirePeripheralCancellationBarrier(
                peripheral,
                token: barrier.token
            )
        }
        peripheralCancellationWatchdogs[key]?.workItem.cancel()
        peripheralCancellationWatchdogs[key] = (barrier.token, workItem)
        DispatchQueue.main.asyncAfter(
            deadline: .now() + peripheralCancellationBarrierTimeout,
            execute: workItem
        )
        loggerD(msg: "admission gate: \(peripheral.identifier.uuidString), begin cancellation barrier=\(barrier.token)")
    }

    /// 新 connect 在 barrier 存在时只记录意图，等旧 didFail/didDisconnect 后再真正发起。
    func connectPeripheralAfterCancellationBarrier(
        _ peripheral: CBPeripheral,
        autoReconnect: Bool
    ) {
        guard !peripheralCancellationBarrierGate.isBlocking(
            endpointId: peripheral.identifier.uuidString
        ) else {
            deferredPeripheralReconnectRegistry.deferConnection(
                endpointId: peripheral.identifier.uuidString,
                autoReconnect: autoReconnect
            )
            loggerD(msg: "admission gate: \(peripheral.identifier.uuidString), defer connect behind cancellation barrier")
            return
        }
        guard let admission = currentConnectionAdmission(
            uuid: peripheral.identifier.uuidString
        ) else {
            loggerE(msg: "admission gate: \(peripheral.identifier.uuidString), refuse unowned connect")
            return
        }
        drivePeripheralConnection(
            peripheral,
            expectedAdmission: admission,
            autoReconnect: autoReconnect,
            remainingStateChecks: 10,
            reason: "normal/deferred connect"
        )
    }

    /// watchdog 只允许 exact token 放行；旧 work item 永远不能释放后续 barrier。
    private func expirePeripheralCancellationBarrier(
        _ peripheral: CBPeripheral,
        token: Int64
    ) {
        let key = reconnectKey(uuid: peripheral.identifier.uuidString)
        guard peripheralCancellationBarrierGate.timeout(
            endpointId: peripheral.identifier.uuidString,
            token: token
        ) else {
            return
        }
        if peripheralCancellationWatchdogs[key]?.token == token {
            peripheralCancellationWatchdogs.removeValue(forKey: key)
        }
        loggerD(msg: "admission gate: \(peripheral.identifier.uuidString), cancellation barrier=\(token) watchdog elapsed")
        completePendingConnectionAdmissionTeardown(peripheral, reason: "cancellation watchdog")
        startDeferredPeripheralConnection(peripheral)
    }

    /// 旧 cancel 终态只消费 token/debt，不进入 UUID 状态机。
    @discardableResult
    func consumePeripheralCancellationBarrier(_ peripheral: CBPeripheral) -> Bool {
        let key = reconnectKey(uuid: peripheral.identifier.uuidString)
        switch peripheralCancellationBarrierGate.consumeCallback(
            endpointId: peripheral.identifier.uuidString
        ) {
        case .activeBarrier(let token):
            if peripheralCancellationWatchdogs[key]?.token == token {
                peripheralCancellationWatchdogs.removeValue(forKey: key)?.workItem.cancel()
            }
            loggerD(msg: "admission gate: \(peripheral.identifier.uuidString), consumed active cancellation callback=\(token)")
            completePendingConnectionAdmissionTeardown(peripheral, reason: "CoreBluetooth terminal callback")
            startDeferredPeripheralConnection(peripheral)
            return true
        case .timedOutBarrier:
            loggerD(msg: "admission gate: \(peripheral.identifier.uuidString), consumed stale cancellation callback debt")
            let hasCurrentAdmission = currentConnectionAdmission(
                uuid: peripheral.identifier.uuidString
            ) != nil
            let isBusinessConnected = connectedDevices.contains { device in
                device.peripheral === peripheral && device.isConnected
            }
            switch BleTimedOutCancellationDebtPolicy.action(
                hasCurrentAdmission: hasCurrentAdmission,
                isBusinessConnected: isBusinessConnected
            ) {
            case .redriveCurrentAttempt:
                // 无 token callback 也可能是真当前代失败；保守保留 generation 并重驱，避免停连。
                redriveCurrentConnectionAfterCancellationDebt(peripheral)
                return true
            case .handleCurrentDisconnect:
                // 业务 connected 已释放 admission 后，任何真实 disconnected 都必须继续清理并回连。
                return false
            case .consumeStaleCallback:
                return true
            }
        case .none:
            return false
        }
    }

    /// 非 CoreBluetooth 终态必须先 cancel 外设并持有 Gate，避免旧链路 teardown 与下一
    /// endpoint 的 discoverServices/CCCD 在 HCI 上重叠。
    func deferConnectionAdmissionReleaseUntilPeripheralTerminal(
        admission: BleConnectionAdmission,
        peripheral: CBPeripheral,
        deviceName: String,
        terminalState: BleConnectState,
        preserveSecurityGateRecovery: Bool = false
    ) {
        guard currentConnectionAdmission(admission) != nil else { return }
        let key = reconnectKey(uuid: admission.endpointId)
        pendingConnectionAdmissionTeardowns[key] = BlePendingConnectionAdmissionTeardown(
            admission: admission,
            peripheral: peripheral,
            deviceName: deviceName,
            terminalState: terminalState,
            preserveSecurityGateRecovery: preserveSecurityGateRecovery
        )
        beginPeripheralCancellationBarrier(peripheral)
    }

    /// exact teardown ack/watchdog 才能释放 owner；释放之后补调度长期回连。
    @discardableResult
    func completePendingConnectionAdmissionTeardown(
        _ peripheral: CBPeripheral,
        reason: String
    ) -> Bool {
        let key = reconnectKey(uuid: peripheral.identifier.uuidString)
        guard let pending = pendingConnectionAdmissionTeardowns[key],
              pending.peripheral === peripheral else {
            return false
        }
        pendingConnectionAdmissionTeardowns.removeValue(forKey: key)
        let current = currentConnectionAdmission(uuid: pending.admission.endpointId)
        let hasReplacementGeneration = current.map {
            $0.generation != pending.admission.generation ||
                $0.sessionId != pending.admission.sessionId
        } == true
        let hasDeferredReplacement = deferredPeripheralReconnectRegistry.contains(
            endpointId: pending.admission.endpointId
        )
        if currentConnectionAdmission(pending.admission) != nil {
            releaseConnectionAdmissionAndStartNext(
                pending.admission,
                invalidateEndpoint: true
            )
        } else {
            // 手动连接可在旧 cancel barrier 内先注册新 generation。旧终态只释放
            // exact session，不能按 endpoint 把刚注册的新 owner 一并取消。
            peripheralConnectionSessions.removeValue(forKey: pending.admission.sessionId)
            if let next = connectionAdmissionGate.cancelSession(pending.admission) {
                startGrantedGattPipeline(next)
            }
        }
        if !hasReplacementGeneration && !hasDeferredReplacement {
            // scheduleReconnect 会把 active request 视为仍有连接 owner 并选择 defer。
            // 旧 admission 已在上面释放，因此必须先清掉同一旧 request；否则 cancel
            // callback/watchdog 恰好同步到达时会形成 admission/request 都不存在、长期
            // autoReconnect task 却不再驱动的零 owner 死区。
            removeActiveConnectRequest(
                uuid: pending.admission.endpointId,
                name: pending.deviceName
            )
            if !pending.preserveSecurityGateRecovery {
                resetPeerPairingRecoveryAfterNonPairingFailure(
                    uuid: pending.admission.endpointId,
                    name: pending.deviceName
                )
            }
            scheduleReconnect(
                uuid: pending.admission.endpointId,
                name: pending.deviceName,
                state: pending.terminalState
            )
        }
        loggerD(msg: "admission gate: \(pending.admission.endpointId), teardown complete generation=\(pending.admission.generation), reason=\(reason)")
        return true
    }

    /// barrier 释放后启动最新 deferred generation；旧 generation 已由 exact admission guard 排除。
    private func startDeferredPeripheralConnection(_ peripheral: CBPeripheral) {
        guard let admission = currentConnectionAdmission(uuid: peripheral.identifier.uuidString),
              let session = peripheralConnectionSessions[admission.sessionId],
              session.peripheral === peripheral,
              let autoReconnect = deferredPeripheralReconnectRegistry.take(
                endpointId: peripheral.identifier.uuidString
              ) else {
            return
        }
        drivePeripheralConnection(
            peripheral,
            expectedAdmission: admission,
            autoReconnect: autoReconnect,
            remainingStateChecks: 10,
            reason: "cancellation barrier released"
        )
    }

    /// 迟到 callback 可能也对应当前 pending connect 的真实失败；不终止当前 generation，
    /// 而是按 exact admission 重新驱动一次，保证回连不会因保守吞掉 callback 而停住。
    private func redriveCurrentConnectionAfterCancellationDebt(_ peripheral: CBPeripheral) {
        guard let admission = currentConnectionAdmission(uuid: peripheral.identifier.uuidString) else {
            return
        }
        let key = reconnectKey(uuid: admission.endpointId)
        let autoReconnect = admission.source == .autoReconnect ||
            reconnectTasks[key] != nil
        drivePeripheralConnection(
            peripheral,
            expectedAdmission: admission,
            autoReconnect: autoReconnect,
            remainingStateChecks: 10,
            reason: "stale cancellation callback debt"
        )
    }

    /// CoreBluetooth 可能在 cancel 后短暂保持 connecting/disconnecting。最多等待 1 秒，
    /// 之后仍会调用 connect 交还给系统去重，确保 deferred reconnect 有界前进。
    private func drivePeripheralConnection(
        _ peripheral: CBPeripheral,
        expectedAdmission: BleConnectionAdmission,
        autoReconnect: Bool,
        remainingStateChecks: Int,
        reason: String
    ) {
        guard let admission = currentConnectionAdmission(expectedAdmission),
              let session = peripheralConnectionSessions[admission.sessionId],
              session.peripheral === peripheral,
              !peripheralCancellationBarrierGate.isBlocking(endpointId: admission.endpointId) else {
            return
        }
        switch peripheral.state {
        case .connected:
            enqueuePhysicalConnectionThroughGate(peripheral)
        case .disconnected:
            connectPeripheral(peripheral, autoReconnect: autoReconnect)
            startPendingPhysicalConnectWatchdog(
                peripheral,
                admission: admission,
                autoReconnect: autoReconnect
            )
            loggerD(msg: "admission gate: \(admission.endpointId), drive generation=\(admission.generation), reason=\(reason)")
        case .connecting where remainingStateChecks > 0,
             .disconnecting where remainingStateChecks > 0:
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self, weak peripheral] in
                guard let self = self, let peripheral = peripheral else { return }
                self.drivePeripheralConnection(
                    peripheral,
                    expectedAdmission: admission,
                    autoReconnect: autoReconnect,
                    remainingStateChecks: remainingStateChecks - 1,
                    reason: reason
                )
            }
        default:
            connectPeripheral(peripheral, autoReconnect: autoReconnect)
            startPendingPhysicalConnectWatchdog(
                peripheral,
                admission: admission,
                autoReconnect: autoReconnect
            )
            loggerD(msg: "admission gate: \(admission.endpointId), force drive after state settle timeout, generation=\(admission.generation), reason=\(reason)")
        }
    }

    @discardableResult
    func registerConnectionAttempt(
        peripheral: CBPeripheral,
        config: BleConfig,
        deviceName: String,
        afterUpgrade: Bool,
        source: BleConnectSource,
        sessionGeneration: Int64 = 0
    ) -> BleConnectionAdmission? {
        // 1、校验稳定 peripheral identity；空 UUID 不进入 Gate。
        let endpointId = peripheral.identifier.uuidString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !endpointId.isEmpty else {
            loggerE(msg: "admission gate: reject blank peripheral identity")
            return nil
        }
        let key = reconnectKey(uuid: endpointId)
        // 2、递增全局 generation/session；Gate 只保留当前在途 endpoint。
        connectionAttemptGenerationSequence = connectionAttemptGenerationSequence == Int64.max
            ? Int64.max
            : connectionAttemptGenerationSequence + 1
        let generation = connectionAttemptGenerationSequence
        connectionSessionSequence += 1
        let admission = BleConnectionAdmission(
            endpointId: endpointId,
            generation: generation,
            sessionId: connectionSessionSequence,
            source: source,
            sessionGeneration: sessionGeneration > 0 ? sessionGeneration : generation
        )
        // A reused CBPeripheral may retain discovered characteristics, but a
        // successful protected write never crosses a physical attempt boundary.
        securityGateAttempts.cancel(endpointIds: [endpointId])
        // 3、先登记 Gate，再写 current/session 映射，保证随后物理回调可精确归属。
        connectionAdmissionGate.registerAttempt(endpointId: endpointId, generation: generation)
        currentConnectionAdmissions[key] = admission
        startNativeTrace(endpointId: endpointId)
        peripheralConnectionSessions[admission.sessionId] = BlePeripheralConnectionSession(
            admission: admission,
            peripheral: peripheral,
            config: config,
            deviceName: deviceName,
            afterUpgrade: afterUpgrade,
            pendingConnectStartedAt: Date()
        )
        return admission
    }

    func currentConnectionAdmission(uuid: String) -> BleConnectionAdmission? {
        currentConnectionAdmissions[reconnectKey(uuid: uuid)]
    }

    func currentConnectionAdmission(_ expected: BleConnectionAdmission) -> BleConnectionAdmission? {
        guard let current = currentConnectionAdmission(uuid: expected.endpointId),
              current.generation == expected.generation,
              current.sessionId == expected.sessionId else {
            return nil
        }
        return current
    }

    /// pipeline callback 必须同时匹配 generation/session/peripheral 对象身份。
    func isCurrentConnectionPipeline(_ peripheral: CBPeripheral) -> Bool {
        guard let admission = currentConnectionAdmission(uuid: peripheral.identifier.uuidString),
              let session = peripheralConnectionSessions[admission.sessionId] else {
            loggerD(msg: "admission gate: \(peripheral.identifier.uuidString), stale pipeline callback ignored")
            return false
        }
        let isCurrent = session.peripheral === peripheral &&
            session.admission.generation == admission.generation &&
            session.admission.sessionId == admission.sessionId
        if !isCurrent {
            loggerD(msg: "admission gate: \(peripheral.identifier.uuidString), peripheral/session identity mismatch")
        }
        return isCurrent
    }

    /// 真实物理连接回调的唯一入口；只在此刻发 source-tagged contactDevice。
    func enqueuePhysicalConnectionThroughGate(_ peripheral: CBPeripheral) {
        // 1、校验 current admission、session 和 CBPeripheral 对象身份，旧 callback 直接关闭。
        guard let admission = currentConnectionAdmission(uuid: peripheral.identifier.uuidString),
              var session = peripheralConnectionSessions[admission.sessionId],
              session.peripheral === peripheral else {
            loggerD(msg: "admission gate: \(peripheral.identifier.uuidString), unowned physical callback ignored")
            centralManager.cancelPeripheralConnection(peripheral)
            return
        }
        // 2、记录真实物理接触并取消观察 watchdog；之后手动点击只可以提升 Gate 优先级，不能取消
        // 已建立的链路并重开 GATT；这也是区别“陈旧 pending”与正常慢连接的边界。
        session.hasObservedPhysicalContact = true
        peripheralConnectionSessions[admission.sessionId] = session
        recordNativeTrace(
            uuid: admission.endpointId,
            stage: "connect",
            result: "success",
            causeDomain: "CoreBluetooth"
        )
        pendingPhysicalConnectWatchdogs.takeIfCurrent(admission)?.cancel()
        visiblePendingRecoveryWatchdogs.takeIfCurrent(admission)?.cancel()
        // 3、把 contact 交给 Gate；只有 granted 才开始 GATT/service pipeline。
        switch connectionAdmissionGate.onPhysicalConnected(admission) {
        case .granted:
            handleConnectState(
                uuid: admission.endpointId,
                name: session.deviceName,
                state: .contactDevice,
                source: admission.source,
                tag: "admission granted"
            )
            startGrantedGattPipeline(admission)
        case .queued:
            handleConnectState(
                uuid: admission.endpointId,
                name: session.deviceName,
                state: .contactDevice,
                source: admission.source,
                tag: "admission queued"
            )
            loggerD(msg: "admission gate: \(admission.endpointId), queued generation=\(admission.generation)")
        case .duplicate:
            loggerD(msg: "admission gate: \(admission.endpointId), duplicate physical callback ignored")
        default:
            peripheralConnectionSessions.removeValue(forKey: admission.sessionId)
            centralManager.cancelPeripheralConnection(peripheral)
        }
    }

    /// Gate owner 唯一允许启动 service discovery，此刻才开始连接超时。
    func startGrantedGattPipeline(_ expected: BleConnectionAdmission) {
        // 1、重新校验 exact admission/session/peripheral，防止旧 owner 获得 pipeline。
        guard let admission = currentConnectionAdmission(expected),
              let session = peripheralConnectionSessions[expected.sessionId] else {
            releaseOrphanedConnectionAdmission(expected, reason: "missing session at grant")
            return
        }
        guard session.peripheral.identifier.uuidString.caseInsensitiveCompare(admission.endpointId) == .orderedSame else {
            releaseOrphanedConnectionAdmission(expected, reason: "peripheral identity mismatch at grant")
            return
        }
        // 2、安装 delegate、替换缓存并从此刻开始业务连接超时。
        let peripheral = session.peripheral
        peripheral.delegate = self
        connectedDevices.removeAll { device in
            device.peripheral.identifier == peripheral.identifier ||
                (!session.deviceName.isEmpty && device.peripheral.name == session.deviceName)
        }
        connectedDevices.append(BleConnectedDevice(belongConfig: session.config, peripheral: peripheral))
        startConnectingCountdown(
            currentConfig: session.config,
            uuid: admission.endpointId,
            name: session.deviceName,
            afterUpgrade: session.afterUpgrade,
            admission: admission
        )
        handleConnectState(
            uuid: admission.endpointId,
            name: peripheral.name ?? session.deviceName,
            state: .searchService,
            source: admission.source,
            tag: "admission pipeline"
        )
        let services = session.config.privateServices.map { $0.serviceUUID }
        let cachedServices = peripheral.services ?? []
        let cachedPrivateServices = cachedServices.filter { service in
            session.config.privateServices.contains { $0.serviceUUID == service.uuid }
        }
        loggerD(msg: "admission gate: \(admission.endpointId), start services cached=\(cachedPrivateServices.count)/\(session.config.privateServices.count)")
        // 3、优先复用完整缓存服务，否则发起 service discovery。
        if cachedPrivateServices.count == session.config.privateServices.count {
            processDiscoveredServices(peripheral: peripheral, error: nil, tag: "admission cached")
        } else {
            peripheral.discoverServices(services)
        }
    }

    @discardableResult
    func releaseConnectionAdmission(
        _ expected: BleConnectionAdmission,
        invalidateEndpoint: Bool
    ) -> BleConnectionAdmission? {
        // 1、只释放当前 exact admission，并取消该代次所有 watchdog。
        guard let current = currentConnectionAdmission(expected) else { return nil }
        pendingPhysicalConnectWatchdogs.takeIfCurrent(current)?.cancel()
        visiblePendingRecoveryWatchdogs.takeIfCurrent(current)?.cancel()
        currentConnectionAdmissions.removeValue(forKey: reconnectKey(uuid: current.endpointId))
        peripheralConnectionSessions.removeValue(forKey: current.sessionId)
        businessConnectionLeases.remove(endpointKey: reconnectKey(uuid: current.endpointId))
        securityGateAttempts.cancel(admission: current)
        // 2、根据终态是完成还是硬取消，选择 complete 或 cancelEndpoint 推进 Gate。
        return invalidateEndpoint
            ? connectionAdmissionGate.cancelEndpoint(current.endpointId)
            : connectionAdmissionGate.complete(current)
    }

    func releaseConnectionAdmissionAndStartNext(
        _ admission: BleConnectionAdmission,
        invalidateEndpoint: Bool
    ) {
        if let next = releaseConnectionAdmission(admission, invalidateEndpoint: invalidateEndpoint) {
            startGrantedGattPipeline(next)
        }
    }

    func completeBusinessConnectionAdmission(uuid: String) {
        guard let admission = currentConnectionAdmission(uuid: uuid) else { return }
        releaseConnectionAdmissionAndStartNext(admission, invalidateEndpoint: false)
    }

    func releaseOrphanedConnectionAdmission(_ admission: BleConnectionAdmission, reason: String) {
        if currentConnectionAdmission(admission) != nil {
            releaseConnectionAdmissionAndStartNext(admission, invalidateEndpoint: true)
        } else if let next = connectionAdmissionGate.cancelSession(admission) {
            peripheralConnectionSessions.removeValue(forKey: admission.sessionId)
            startGrantedGattPipeline(next)
        }
        loggerE(msg: "admission gate: \(admission.endpointId), orphan released reason=\(reason)")
    }

    /// 手动点击只提升已存在的 pending session，不抢占 active，不新建 peripheral connect。
    @discardableResult
    func promotePendingAttempt(uuid: String) -> Bool {
        // 1、找到同一 pending session；不存在时由 coordinator 创建新 attempt。
        let key = reconnectKey(uuid: uuid)
        guard let current = currentConnectionAdmissions[key],
              var session = peripheralConnectionSessions[current.sessionId] else {
            return false
        }
        // 2、更新 current/session source，再提升 Gate 等待优先级，不重建 CoreBluetooth connect。
        let promoted = BleConnectionAdmission(
            endpointId: current.endpointId,
            generation: current.generation,
            sessionId: current.sessionId,
            source: .manualReconnect,
            sessionGeneration: current.sessionGeneration
        )
        currentConnectionAdmissions[key] = promoted
        session.admission = promoted
        peripheralConnectionSessions[current.sessionId] = session
        connectionAdmissionGate.promote(
            endpointId: current.endpointId,
            generation: current.generation,
            sessionId: current.sessionId
        )
        return true
    }

    /// 辅助扫描只上报“长期 owner 的目标重新可见”。这里不直接重建连接：先核对
    /// reconnect task、exact admission 与 peripheral identity；若 CoreBluetooth 已经
    /// 显示 connected，则补交 Gate，其他情况只安装一次到原 pending 起点 +20 秒的恢复。
    @discardableResult
    func reconcileVisibleAutoReconnectTarget(uuid: String, name: String) -> Bool {
        guard centralManager.state == .poweredOn,
              let task = reconnectTasks.values.first(where: {
                  isSameConnectTarget(
                      storedUuid: $0.uuid,
                      storedName: $0.name,
                      uuid: uuid,
                      name: name
                  )
              }),
              let admission = currentConnectionAdmission(uuid: task.uuid),
              let session = peripheralConnectionSessions[admission.sessionId],
              session.peripheral.identifier.uuidString.caseInsensitiveCompare(task.uuid) == .orderedSame,
              !session.hasObservedPhysicalContact else {
            return false
        }

        let peripheral = session.peripheral
        if peripheral.state == .connected {
            loggerD(msg: "admission gate: \(admission.endpointId), visible hint observed connected generation=\(admission.generation)")
            enqueuePhysicalConnectionThroughGate(peripheral)
            return true
        }
        guard !hasPeripheralCancellationBarrier(peripheral) else {
            return false
        }
        scheduleVisiblePendingRecovery(
            peripheral,
            expectedAdmission: admission,
            pendingConnectStartedAt: session.pendingConnectStartedAt
        )
        return true
    }

    /// 同一 admission 始终只保留一个 work item，deadline 基于原 pending 起点计算，
    /// 因此重复广告不会延后恢复，也不会形成周期性 cancel/connect。
    private func scheduleVisiblePendingRecovery(
        _ peripheral: CBPeripheral,
        expectedAdmission: BleConnectionAdmission,
        pendingConnectStartedAt: Date
    ) {
        let elapsed = Date().timeIntervalSince(pendingConnectStartedAt)
        let remaining = max(0, manualPendingReplacementThreshold - elapsed)
        let workItem = DispatchWorkItem { [weak self, weak peripheral] in
            guard let self = self, let peripheral = peripheral,
                  self.visiblePendingRecoveryWatchdogs.takeIfCurrent(expectedAdmission) != nil,
                  let admission = self.currentConnectionAdmission(expectedAdmission),
                  let session = self.peripheralConnectionSessions[admission.sessionId],
                  session.peripheral === peripheral,
                  !session.hasObservedPhysicalContact else {
                return
            }
            if peripheral.state == .connected {
                self.enqueuePhysicalConnectionThroughGate(peripheral)
                return
            }
            guard self.replaceStalePendingAttemptIfNeeded(
                peripheral,
                trigger: .visibleAutoReconnect
            ) else {
                return
            }
            // replacement 已建立 cancellation barrier；beginReconnectAttempt 会保留
            // 原 task source，并注册新 generation 等待旧终态/看门狗后再 connect。
            self.beginReconnectAttempt(uuid: admission.endpointId)
        }
        visiblePendingRecoveryWatchdogs
            .replace(admission: expectedAdmission, workItem: workItem)?
            .cancel()
        DispatchQueue.main.asyncAfter(
            deadline: .now() + remaining,
            execute: workItem
        )
        let remainingDescription = String(format: "%.1f", remaining)
        loggerD(msg: "admission gate: \(expectedAdmission.endpointId), visible pending recovery armed generation=\(expectedAdmission.generation), delay=\(remainingDescription)s")
    }

    /// 手动连接的受控逃逸口：仅替换超过阈值、从未收到物理连接回调且未处于取消
    /// barrier 的 pending owner。正常 autoReconnect 继续长期交给 CoreBluetooth，不能因
    /// 每次点击被重置；这里的 cancel 也必须先建立 barrier，确保旧 callback 不会污染新代。
    @discardableResult
    func replaceStalePendingManualAttemptIfNeeded(_ peripheral: CBPeripheral) -> Bool {
        replaceStalePendingAttemptIfNeeded(
            peripheral,
            trigger: .manualReconnect
        )
    }

    /// exact admission 的通用陈旧 pending 替换边界。可见性恢复与手动接管共享同一
    /// 20 秒/no-contact/barrier 条件，避免两套逻辑分别制造 CoreBluetooth 竞态。
    @discardableResult
    func replaceStalePendingAttemptIfNeeded(
        _ peripheral: CBPeripheral,
        trigger: BleStalePendingReplacementTrigger
    ) -> Bool {
        guard let admission = currentConnectionAdmission(uuid: peripheral.identifier.uuidString),
              let session = peripheralConnectionSessions[admission.sessionId],
              session.peripheral === peripheral,
              !session.hasObservedPhysicalContact,
              peripheral.state != .connected,
              !hasPeripheralCancellationBarrier(peripheral) else {
            return false
        }
        let elapsed = Date().timeIntervalSince(session.pendingConnectStartedAt)
        guard elapsed >= manualPendingReplacementThreshold else {
            return false
        }

        // 先取消旧 watchdog 和旧 owner，再由调用方在同一 barrier 后注册新 generation。
        // completion 的 exact admission guard 会只释放旧 session，deferred registry 则保证
        // 新 central.connect 必须等 didFail/didDisconnect 或 barrier watchdog 后才真正执行。
        pendingPhysicalConnectWatchdogs.takeIfCurrent(admission)?.cancel()
        visiblePendingRecoveryWatchdogs.takeIfCurrent(admission)?.cancel()
        deferConnectionAdmissionReleaseUntilPeripheralTerminal(
            admission: admission,
            peripheral: peripheral,
            deviceName: session.deviceName,
            terminalState: .disconnectFromSys
        )
        centralManager.cancelPeripheralConnection(peripheral)
        let elapsedDescription = String(format: "%.1f", elapsed)
        let replacementDescription = trigger == .manualReconnect
            ? "manual stale pending replacement"
            : "visible auto reconnect stale pending replacement"
        loggerD(msg: "admission gate: \(admission.endpointId), \(replacementDescription) trigger=\(trigger.rawValue), generation=\(admission.generation), elapsed=\(elapsedDescription)s")
        return true
    }

    /// 蓝牙关闭必须先取消全部 peripheral handle，再原子失效 Gate/generation。
    func suspendConnectionAdmissionGateForBluetoothOff() {
        // 1、先取消所有 peripheral handle，再原子失效 Gate、session、watchdog 和 barrier。
        let peripherals = peripheralConnectionSessions.values.map { $0.peripheral }
        var cancelled = Set<ObjectIdentifier>()
        for peripheral in peripherals where cancelled.insert(ObjectIdentifier(peripheral)).inserted {
            centralManager.cancelPeripheralConnection(peripheral)
        }
        connectionAdmissionGate.suspendAndReset()
        currentConnectionAdmissions.removeAll()
        peripheralConnectionSessions.removeAll()
        // Bluetooth OFF invalidates every exact prepare token while preserving
        // paused long-lived autoReconnect tasks for poweredOn recovery.
        businessConnectionLeases.clear()
        securityGateAttempts.removeAll()
        peripheralCancellationWatchdogs.values.forEach { $0.workItem.cancel() }
        peripheralCancellationWatchdogs.removeAll()
        pendingPhysicalConnectWatchdogs.removeAll().forEach { $0.cancel() }
        visiblePendingRecoveryWatchdogs.removeAll().forEach { $0.cancel() }
        peripheralCancellationBarrierGate.reset()
        deferredPeripheralReconnectRegistry.removeAll()
        pendingConnectionAdmissionTeardowns.removeAll()
    }

    func resumeConnectionAdmissionGateAfterBluetoothOn() {
        connectionAdmissionGate.resume()
    }

    /// reset/clean 在蓝牙仍开启时也要真取消全部 owner，然后恢复空 Gate。
    func cancelAllConnectionAdmissions(reason: String) {
        suspendConnectionAdmissionGateForBluetoothOff()
        connectionAdmissionGate.resume()
        loggerD(msg: "admission gate: cancel all, reason=\(reason)")
    }
}
