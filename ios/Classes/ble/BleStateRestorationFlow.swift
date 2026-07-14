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
        guard restorationCoordinator.hasPendingPeripherals else {
            return
        }
        // drain 后逐个 replay；如果仍匹配不到配置，restorePeripheral 会负责重新 enqueue。
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
        peripheral.delegate = self
        let uuid = peripheral.identifier.uuidString
        let name = peripheral.name ?? ""
        // 先记录 native 事件，便于 Dart 恢复后补读 State Restoration 发生过什么。
        recordAutoReconnectEvent(
            type: "ios_restore_peripheral",
            uuid: uuid,
            name: name,
            detail: source
        )
        loggerD(msg: "stateRestoration: restore peripheral source=\(source), uuid=\(uuid), name=\(name), state=\(peripheral.state.rawValue), services=\(peripheral.services?.count ?? 0)")
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
