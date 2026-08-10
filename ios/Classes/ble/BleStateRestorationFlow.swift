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
    /// `willRestoreState` 的唯一入口：只建立物理 escrow，不提前创建业务 admission。
    func escrowStateRestorationPeripheral(_ peripheral: CBPeripheral, source: String) {
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
        connectPeripheral(peripheral, autoReconnect: true)
        recordAutoReconnectEvent(
            type: "ios_restore_escrow_rearm",
            uuid: peripheral.identifier.uuidString,
            name: peripheral.name ?? "",
            detail: reason
        )
        loggerD(msg: "stateRestoration: escrow rearm uuid=\(peripheral.identifier.uuidString), reason=\(reason)")
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
