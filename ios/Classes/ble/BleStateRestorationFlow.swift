//
//  BleStateRestorationFlow.swift
//  flutter_ezw_ble
//
//  Replays CoreBluetooth restored peripherals after plugin configs are ready.
//  Restoration is treated as a native physical-link recovery path and always
//  enters the same GATT readiness pipeline as a normal foreground connect.
//

import CoreBluetooth
import Foundation

/// restored peripheral 没有授权 owner 时必须拒绝；只有配置尚未初始化才允许暂存重放。
enum BleStateRestorationReplayDecision: Equatable {
    case deferUntilConfigsReady
    case restore
    case rejectUnauthorized
}

enum BleStateRestorationAuthorization {
    static func config(
        persistedTarget: BleReconnectTarget?,
        runtimeTask: BleReconnectTask?,
        configs: [BleConfig]
    ) -> BleConfig? {
        let ownerConfigName = persistedTarget?.belongConfig ?? runtimeTask?.belongConfig
        guard let ownerConfigName else { return nil }
        return configs.first { $0.name == ownerConfigName && $0.autoReconnect }
    }

    static func replayDecision(
        configsInitialized: Bool,
        hasAuthorizedConfig: Bool
    ) -> BleStateRestorationReplayDecision {
        if hasAuthorizedConfig { return .restore }
        return configsInitialized ? .rejectUnauthorized : .deferUntilConfigsReady
    }
}

/**
 *  iOS State Restoration 恢复流程。
 *
 *  该扩展只处理 restored peripheral 如何找回配置和进入 GATT pipeline，
 *  不在 willRestoreState 回调中执行任何 Dart 业务认证。
 */
extension BleManager {
    /**
     *  结束本次冷启动 restoration 认领窗口。
     *
     *  当前设备的 activation 已先从 pending 集合移除匹配对象；剩余对象只能属于
     *  历史设备或歧义身份，必须 fail-closed 并取消系统物理连接。
     */
    func finalizeStateRestorationClaims() {
        // 1、一次性 drain，保证重复收尾幂等且不会取消稍后进入的新 restoration 回调。
        let unclaimedPeripherals = restorationCoordinator.drainPendingPeripherals()
        // 2、未认领对象不得进入业务 Gate；若系统仍连接或正在连接，显式取消物理链路。
        unclaimedPeripherals.forEach { peripheral in
            let uuid = peripheral.identifier.uuidString
            let name = peripheral.name ?? ""
            if peripheral.state != .disconnected {
                centralManager.cancelPeripheralConnection(peripheral)
            }
            recordAutoReconnectEvent(
                type: "ios_restore_unclaimed",
                uuid: uuid,
                name: name,
                detail: "startup current targets did not claim peripheral"
            )
            loggerD(msg: "stateRestoration: finalize unclaimed uuid=\(uuid), name=\(name), state=\(peripheral.state.rawValue)")
        }
        loggerD(msg: "stateRestoration: claim window finalized, unclaimed=\(unclaimedPeripherals.count)")
    }

    /**
     *  为 restored peripheral 找回 BleConfig。
     *
     *  只有明确 persisted/runtime owner 且其配置仍启用 autoReconnect 才允许恢复。
     */
    func findRestoredBleConfig(peripheral: CBPeripheral) -> BleConfig? {
        let uuid = peripheral.identifier.uuidString
        let name = peripheral.name ?? ""
        let target = persistedReconnectTarget(
            uuid: uuid,
            name: name
        )
        let runtimeTask = reconnectTasks.values.first { task in
            task.uuid.caseInsensitiveCompare(uuid) == .orderedSame ||
                (target != nil && task.belongConfig == target?.belongConfig && task.name == target?.name)
        }
        if let config = BleStateRestorationAuthorization.config(
            persistedTarget: target,
            runtimeTask: runtimeTask,
            configs: bleConfigs
        ) {
            return config
        }
        if let target, hasInitializedBleConfigs {
            // 目标配置被删除/禁用后，restoration 不能凭单配置或旧 active request 猜测复活。
            loggerE(msg: "stateRestoration: unauthorized/stale target config=\(target.belongConfig), uuid=\(target.uuid), remove target")
            removePersistedReconnectTarget(uuid: target.uuid, name: target.name)
        }
        return nil
    }

    /// 当前 restored peripheral 是否仍有明确 persisted/runtime owner，仅用于 replay 决策。
    private func hasAuthorizedRestorationOwner(_ peripheral: CBPeripheral) -> Bool {
        let target = persistedReconnectTarget(
            uuid: peripheral.identifier.uuidString,
            name: peripheral.name ?? ""
        )
        let task = reconnectTasks.values.first {
            $0.uuid.caseInsensitiveCompare(peripheral.identifier.uuidString) == .orderedSame
        }
        return BleStateRestorationAuthorization.config(
            persistedTarget: target,
            runtimeTask: task,
            configs: bleConfigs
        ) != nil
    }

    /**
     *  在 initConfigs 后重放 pending restored peripherals。
     *
     *  willRestoreState 可能早于 initConfigs，必须等配置存在后才能知道该走哪套私有服务。
     */
    func flushPendingRestoredPeripherals() {
        // 1、只有配置初始化完成后才消费暂存 peripheral，避免无 owner 误恢复。
        guard restorationCoordinator.hasPendingPeripherals else {
            return
        }
        // 2、逐个 replay；如果仍匹配不到配置，restorePeripheral 会按授权策略重新暂存或拒绝。
        restorationCoordinator.drainPendingPeripherals().forEach { peripheral in
            restorePeripheral(peripheral, source: "pending-after-initConfigs")
        }
    }

    /**
     *  恢复一个 CoreBluetooth restored peripheral。
     *
     *  restored peripheral 只表示系统恢复了物理对象，不代表私有服务/notify/业务认证已经 ready。
     */
    func restorePeripheral(_ peripheral: CBPeripheral, source: String) {
        // 1、State Restoration 只恢复系统 peripheral 对象，不代表业务 GATT 已 ready。
        peripheral.delegate = self
        let uuid = peripheral.identifier.uuidString
        let name = peripheral.name ?? ""
        // 1.1、先记录 native 事件，便于 Dart 恢复后补读 State Restoration 发生过什么。
        recordAutoReconnectEvent(
            type: "ios_restore_peripheral",
            uuid: uuid,
            name: name,
            detail: source
        )
        loggerD(msg: "stateRestoration: restore peripheral source=\(source), uuid=\(uuid), name=\(name), state=\(peripheral.state.rawValue), services=\(peripheral.services?.count ?? 0)")
        // 2、按 persisted/runtime owner 授权配置；无授权时延后或 fail-closed。
        guard let bleConfig = findRestoredBleConfig(peripheral: peripheral) else {
            switch BleStateRestorationAuthorization.replayDecision(
                configsInitialized: hasInitializedBleConfigs,
                hasAuthorizedConfig: hasAuthorizedRestorationOwner(peripheral)
            ) {
            case .deferUntilConfigsReady:
                restorationCoordinator.enqueue(peripheral)
                loggerD(msg: "stateRestoration: \(uuid)-\(name), defer until initConfigs")
            case .rejectUnauthorized:
                if peripheral.state != .disconnected {
                    centralManager.cancelPeripheralConnection(peripheral)
                }
                recordAutoReconnectEvent(
                    type: "ios_restore_rejected",
                    uuid: uuid,
                    name: name,
                    detail: "missing persisted/authorized autoReconnect owner"
                )
                loggerE(msg: "stateRestoration: \(uuid)-\(name), reject unauthorized restored peripheral")
            case .restore:
                // findRestoredBleConfig 与同一授权策略共享输入，理论上不可达；fail closed。
                loggerE(msg: "stateRestoration: \(uuid)-\(name), authorized config lookup mismatch")
            }
            return
        }
        // 3、授权后把 restored peripheral 接入统一 admission/GATT pipeline；旧 UUID 会先迁移。
        // persisted owner 可能仍是旧 UUID A，而 restoration/辅助扫描已给出新 UUID B。
        // 先补建长期 task，再复用同一原子迁移逻辑，保证 B 终态仍能继续自动回连。
        if let target = persistedReconnectTarget(uuid: uuid, name: name) {
            let targetKey = reconnectKey(uuid: target.uuid)
            let restoredTask = reconnectTasks[targetKey] ?? BleReconnectTask(
                belongConfig: target.belongConfig,
                uuid: target.uuid,
                name: target.name,
                source: .autoReconnect
            )
            reconnectTasks[targetKey] = restoredTask
            _ = migrateReconnectTaskIdentityIfNeeded(restoredTask, to: peripheral)
        }
        // 构造 active request 是为了让后续 didConnect/didDiscover 回调能复用现有连接状态机。
        var request = BleEasyConnect(
            configName: bleConfig.name,
            uuid: uuid,
            name: name.isEmpty ? (persistedReconnectTarget(uuid: uuid)?.name ?? "") : name,
            afterUpgrade: false,
            directConnect: true,
            time: Date().timeIntervalSince1970
        )
        request.bleConfig = bleConfig
        upsertActiveConnectRequest(request)
        // 同一个 restored peripheral 可能已在旧缓存中，先去重再放入新的恢复上下文。
        connectedDevices.removeAll { device in
            device.peripheral.identifier == peripheral.identifier ||
                (!name.isEmpty && device.peripheral.name == name)
        }
        connectedDevices.append(BleConnectedDevice(belongConfig: bleConfig, peripheral: peripheral))
        _ = registerConnectionAttempt(
            peripheral: peripheral,
            config: bleConfig,
            deviceName: request.name,
            afterUpgrade: false,
            source: .stateRestoration
        )
        if peripheral.state == .connected {
            // 已连接只表示物理链路存在，仍必须进入 GATT readiness gate。
            enqueueRestoredPeripheralThroughGate(
                peripheral,
                config: bleConfig,
                deviceName: request.name
            )
        } else {
            // disconnected/connecting 只建立 CoreBluetooth pending connect，物理 callback 前
            // 不发 connecting，不启动 pipeline timeout。
            connectPeripheralAfterCancellationBarrier(peripheral, autoReconnect: true)
        }
    }
}
