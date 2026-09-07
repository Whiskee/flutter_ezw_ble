//
//  BleStateRestorationFlow.swift
//  flutter_ezw_ble
//
//  Holds CoreBluetooth restored peripherals until the current account claims
//  them through auto-reconnect activation.
//

import CoreBluetooth
import Foundation

/**
 *  iOS State Restoration 恢复流程。
 *
 *  该扩展只维持 claim 前的 CoreBluetooth 物理 escrow。当前账号 target
 *  通过 activation 精确认领后，才由自动回连协调器进入 GATT pipeline。
 */
extension BleManager {
    /// 当前账号持久化 reconnect target 或进程内 reconnect owner 才是 restoration 的合法目标。
    /// iOS 通知转发走 ANCS：旧眼镜的右腿在切换设备后仍由系统持有链路并会被系统自动重连，
    /// 本 central 按私有服务注册的 connection event 会把它再次交来；非目标对象只能忽略，
    /// 绝不能为它补 pending connect，否则旧眼镜永远跟着 SR 一起回来（2026-09-07 真机）。
    func isStateRestorationTarget(_ peripheral: CBPeripheral) -> Bool {
        let uuid = peripheral.identifier.uuidString
        let name = peripheral.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if reconnectStore.target(uuid: uuid, name: name) != nil {
            return true
        }
        return reconnectTasks.values.contains { task in
            isSameConnectTarget(storedUuid: task.uuid, storedName: task.name, uuid: uuid, name: name)
        }
    }

    /// `willRestoreState` 的唯一入口：只建立物理 escrow，不提前创建业务 admission。
    func escrowStateRestorationPeripheral(_ peripheral: CBPeripheral, source: String) {
        if source == "connectionEvent",
           !isStateRestorationTarget(peripheral),
           !restorationCoordinator.contains(uuid: peripheral.identifier.uuidString) {
            // 系统为非当前目标（如旧眼镜的 ANCS 右腿、办公室里其它 G2）建立的链路
            // 不是本进程的 restoration 输入：不托管、不设 delegate、不 rearm。
            recordAutoReconnectEvent(
                type: "ios_connection_event_ignored",
                uuid: peripheral.identifier.uuidString,
                name: peripheral.name ?? "",
                detail: "reason=notRestorationTarget, state=\(peripheral.state.rawValue)"
            )
            loggerD(msg: "stateRestoration: ignore connection event for non-target uuid=\(peripheral.identifier.uuidString), name=\(peripheral.name ?? ""), state=\(peripheral.state.rawValue)")
            return
        }
        peripheral.delegate = self
        let action = restorationCoordinator.enqueue(peripheral)
        recordAutoReconnectEvent(
            type: "ios_restore_escrow",
            uuid: peripheral.identifier.uuidString,
            name: peripheral.name ?? "",
            detail: "source=\(source), state=\(peripheral.state.rawValue), action=\(action)"
        )
        loggerD(msg: "stateRestoration: escrow uuid=\(peripheral.identifier.uuidString), name=\(peripheral.name ?? ""), state=\(peripheral.state.rawValue), action=\(action)")
        if action == .rearm {
            rearmStateRestorationEscrow(peripheral, reason: "willRestoreState disconnected")
        }
        // 系统 peerConnected 却仍是 `.connecting` 的 restored 对象：链路可能属于 ANCS /
        // 设置页等其它 owner，claim 后必须给 didConnect 一个有界宽限，而不是无限 keepPending。
        if source == "connectionEvent", action == .keepPending {
            restorationCoordinator.notePeerConnectedObservation(uuid: peripheral.identifier.uuidString)
        }
    }

    /// claim 前到达的 didConnect 只保留物理链路，不发现服务、不上报 noBleConfigFound。
    func handleStateRestorationEscrowDidConnect(_ peripheral: CBPeripheral) -> Bool {
        guard restorationCoordinator.didConnect(peripheral) == .holdConnected else {
            return false
        }
        recordAutoReconnectEvent(
            type: "ios_restore_escrow_connected",
            uuid: peripheral.identifier.uuidString,
            name: peripheral.name ?? "",
            detail: "awaiting current-target claim"
        )
        loggerD(msg: "stateRestoration: escrow connected uuid=\(peripheral.identifier.uuidString), hold before claim")
        return true
    }

    /// claim 前的 terminal 继续维持 CoreBluetooth 长期等待，不触发 Dart/GATT/AUTH。
    func handleStateRestorationEscrowTerminal(
        _ peripheral: CBPeripheral,
        systemIsReconnecting: Bool,
        reason: String
    ) -> Bool {
        let action = restorationCoordinator.didTerminate(
            peripheral,
            systemIsReconnecting: systemIsReconnecting
        )
        guard action != .ignore else { return false }
        if action == .rearm {
            rearmStateRestorationEscrow(peripheral, reason: reason)
        } else {
            loggerD(msg: "stateRestoration: escrow keep system pending uuid=\(peripheral.identifier.uuidString), reason=\(reason)")
        }
        return true
    }

    /// escrow 只调用 CoreBluetooth connect；正式 admission 必须等 Dart target claim。
    private func rearmStateRestorationEscrow(_ peripheral: CBPeripheral, reason: String) {
        // 只为当前账号的目标补 pending connect。willRestoreState 也可能交还旧眼镜的
        // ANCS 右腿（已 .disconnected）：为它 connect 只会让本 central 再次抱住旧设备，
        // 随后每次 finalize 都要 cancel、下次重启又被交还。非目标留在 escrow 等 finalize 丢弃。
        guard isStateRestorationTarget(peripheral) else {
            recordAutoReconnectEvent(
                type: "ios_restore_escrow_rearm_skipped",
                uuid: peripheral.identifier.uuidString,
                name: peripheral.name ?? "",
                detail: "reason=notRestorationTarget, source=\(reason)"
            )
            loggerD(msg: "stateRestoration: skip rearm for non-target uuid=\(peripheral.identifier.uuidString), name=\(peripheral.name ?? ""), reason=\(reason)")
            return
        }
        // willRestoreState 早于 centralManagerDidUpdateState(poweredOn) 是常态；
        // 未 poweredOn 时提交 connect 依赖未承诺的系统行为，挂起等 poweredOn 补偿。
        guard centralManager.state == .poweredOn else {
            restorationCoordinator.deferPowerOnRearm(uuid: peripheral.identifier.uuidString)
            loggerD(msg: "stateRestoration: escrow rearm deferred until poweredOn uuid=\(peripheral.identifier.uuidString), reason=\(reason), state=\(centralManager.state.rawValue)")
            return
        }
        connectPeripheral(peripheral, autoReconnect: true)
        recordAutoReconnectEvent(
            type: "ios_restore_escrow_rearm",
            uuid: peripheral.identifier.uuidString,
            name: peripheral.name ?? "",
            detail: reason
        )
        loggerD(msg: "stateRestoration: escrow rearm uuid=\(peripheral.identifier.uuidString), reason=\(reason)")
    }

    /// poweredOn 后补偿执行此前被挂起的 escrow rearm；不在 escrow 的债务已被丢弃。
    func rearmDeferredStateRestorationEscrowsAfterPowerOn() {
        restorationCoordinator.takePowerOnRearmDeferrals().forEach { peripheral in
            rearmStateRestorationEscrow(peripheral, reason: "poweredOn compensation")
        }
    }

    /// hard cancel/config revoke 精确清除 escrow，并以 cancellation barrier 阻止迟到 didConnect。
    func cancelStateRestorationEscrow(uuid: String, name: String, reason: String) {
        cancelStateRestorationEscrowPeripherals(
            restorationCoordinator.removePendingPeripherals(uuid: uuid, name: name),
            reason: reason
        )
    }

    /// hard reset/clean 清除全部 escrow；startup preserve reset 不调用此入口。
    func cancelAllStateRestorationEscrow(reason: String) {
        cancelStateRestorationEscrowPeripherals(
            restorationCoordinator.clearPendingPeripherals(),
            reason: reason
        )
    }

    private func cancelStateRestorationEscrowPeripherals(
        _ peripherals: [CBPeripheral],
        reason: String
    ) {
        peripherals.forEach { peripheral in
            // escrow map 已先撤销，barrier 负责隔离此前 pending connect 的迟到成功回调。
            beginPeripheralCancellationBarrier(peripheral)
            if peripheral.state != .disconnected {
                centralManager.cancelPeripheralConnection(peripheral)
            }
            loggerD(msg: "stateRestoration: escrow cancelled uuid=\(peripheral.identifier.uuidString), reason=\(reason)")
        }
    }

    /// 只报告当前 runtime 是否持有待认领 escrow，不触发 claim、GATT 或业务事件。
    func hasPendingStateRestoration() -> Bool {
        restorationCoordinator.hasPendingPeripherals
    }

    /**
     *  结束本次冷启动 restoration 认领窗口。
     *
     *  当前设备的 activation 已先从 pending 集合移除匹配对象；剩余对象只能属于
     *  历史设备或歧义身份，必须 fail-closed 并取消系统物理连接。
     */
    func finalizeStateRestorationClaims() {
        // 1、只收口「认领窗口快照」内的对象：窗口后经 connectionEvent 持续交来的
        // 系统连接属于下一轮 activation 输入，迟到的 finalize 债务不得误取消它们。
        let unclaimedPeripherals = restorationCoordinator.drainClaimWindowPeripherals()
        // 2、未认领对象不得进入业务 Gate；若系统仍连接或正在连接，显式取消物理链路。
        unclaimedPeripherals.forEach { peripheral in
            let uuid = peripheral.identifier.uuidString
            let name = peripheral.name ?? ""
            // 即使当前显示 disconnected，旧 pending connect 仍可能迟到 didConnect。
            beginPeripheralCancellationBarrier(peripheral)
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
     *  在 initConfigs 后重放 pending restored peripherals。
     *
     *  willRestoreState 可能早于 initConfigs，必须等配置存在后才能知道该走哪套私有服务。
     */
    func flushPendingRestoredPeripherals() {
        // 配置就绪仍不代表当前账号 owner 已就绪。保留 escrow，等待
        // activateAutoReconnectTargets 逐端点精确认领，禁止按 config 类型提前恢复历史设备。
        guard restorationCoordinator.hasPendingPeripherals else { return }
        loggerD(msg: "stateRestoration: pending-after-initConfigs, wait exact current-target claim")
    }

    /// 兼容内部旧调用名；restored peripheral 仍只能进入 claim 前 escrow。
    func restorePeripheral(_ peripheral: CBPeripheral, source: String) {
        // 兼容内部旧调用名，但语义已经收紧为 escrow；正式业务恢复只能由当前 target claim。
        escrowStateRestorationPeripheral(peripheral, source: source)
    }
}
