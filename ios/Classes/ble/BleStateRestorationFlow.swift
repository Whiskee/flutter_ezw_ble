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
     *  优先使用进行中的连接/连接缓存，其次使用持久化 reconnect target；只有单配置时才允许兜底。
     */
    func findRestoredBleConfig(peripheral: CBPeripheral) -> BleConfig? {
        if let config = findBleConfig(
            uuid: peripheral.identifier.uuidString,
            name: peripheral.name ?? ""
        ) {
            return config
        }
        if let target = persistedReconnectTarget(
            uuid: peripheral.identifier.uuidString,
            name: peripheral.name ?? ""
        ) {
            // 持久化目标保存 belongConfig，解决 restoration 早于 Dart 业务上下文的问题。
            guard let config = bleConfigs.first(where: { $0.name == target.belongConfig }) else {
                // 配置可能被用户删除/改名。State Restoration 发生在启动早期，不能用
                // 强解包让 App crash；清理过期目标后等待 Dart 重新写入有效配置。
                loggerE(msg: "stateRestoration: stale reconnect target config=\(target.belongConfig), uuid=\(target.uuid), remove target")
                removePersistedReconnectTarget(uuid: target.uuid, name: target.name)
                return nil
            }
            return config
        }
        // State Restoration can run before Dart has replayed configs. Falling back
        // is only safe in the single-config case because no device family ambiguity exists.
        if bleConfigs.count == 1 {
            loggerD(msg: "stateRestoration: fallback to single config \(bleConfigs.first?.name ?? ""), uuid=\(peripheral.identifier.uuidString)")
            return bleConfigs.first
        }
        return nil
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
            // 配置未准备好时不能猜测私有服务，继续缓存等待 initConfigs。
            restorationCoordinator.enqueue(peripheral)
            loggerE(msg: "stateRestoration: \(uuid)-\(name), wait for initConfigs to match BleConfig")
            return
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
        if peripheral.state == .connected {
            // 已连接只表示物理链路存在，仍必须进入 GATT readiness gate。
            handleAlreadyConnected(
                peripheral: peripheral,
                bleConfig: bleConfig,
                deviceName: name,
                tag: "stateRestoration"
            )
        } else {
            // disconnected/connecting 都交还给 CoreBluetooth pending connect，不用短 timeout 抢占系统恢复。
            handleConnectState(uuid: uuid, name: name, state: .connecting, tag: "stateRestoration")
            connectPeripheral(peripheral, autoReconnect: true)
        }
    }
}
