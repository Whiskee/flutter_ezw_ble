//
//  BleStateRestorationCoordinator.swift
//  flutter_ezw_ble
//
//  Buffers CoreBluetooth restored peripherals until Dart has replayed configs.
//  `willRestoreState` can arrive before `initConfigs`, so restoration must be
//  staged instead of starting business recovery immediately.
//

import CoreBluetooth
import Foundation

/// State Restoration peripheral 在当前账号 target 尚未加载时的物理状态。
enum BleStateRestorationEscrowState: Equatable {
    /// CoreBluetooth 正在结束旧链路，等待 terminal callback 决定是否重挂。
    case idle
    /// CoreBluetooth 已持有长期 pending connect，不得重复启动 GATT 业务流程。
    case pending
    /// peripheral 物理已连接，但尚未获当前账号授权，不得发现服务或发送 AUTH。
    case connected
}

/// escrow 事件对 CoreBluetooth 的唯一动作，业务 Gate 在 claim 前始终不参与。
enum BleStateRestorationEscrowAction: Equatable {
    case ignore
    case keepPending
    case holdConnected
    case rearm
}

/// 可独立测试的 UUID 状态机；CBPeripheral 引用由 coordinator 另行持有。
final class BleStateRestorationEscrowStateMachine {
    private var states: [String: BleStateRestorationEscrowState] = [:]

    var countForTesting: Int { states.count }

    func stage(endpointId: String, peripheralState: CBPeripheralState) -> BleStateRestorationEscrowAction {
        switch peripheralState {
        case .connected:
            states[endpointId] = .connected
            return .holdConnected
        case .connecting:
            states[endpointId] = .pending
            return .keepPending
        case .disconnected:
            // willRestoreState 也可能交还已断开的对象；立即补一条长期 pending connect。
            states[endpointId] = .pending
            return .rearm
        case .disconnecting:
            states[endpointId] = .idle
            return .ignore
        @unknown default:
            states[endpointId] = .idle
            return .ignore
        }
    }

    func didConnect(endpointId: String) -> BleStateRestorationEscrowAction {
        guard states[endpointId] != nil else { return .ignore }
        states[endpointId] = .connected
        return .holdConnected
    }

    func didTerminate(endpointId: String, systemIsReconnecting: Bool) -> BleStateRestorationEscrowAction {
        guard states[endpointId] != nil else { return .ignore }
        states[endpointId] = .pending
        return systemIsReconnecting ? .keepPending : .rearm
    }

    func claim(endpointId: String) -> BleStateRestorationEscrowState? {
        states.removeValue(forKey: endpointId)
    }

    func remove(endpointIds: Set<String>) {
        endpointIds.forEach { states.removeValue(forKey: $0) }
    }

    func reset() {
        states.removeAll()
    }
}

/// 一个等待当前账号精确认领的 restored peripheral 快照。
struct BleStateRestorationEscrowClaim {
    let peripheral: CBPeripheral
    let state: BleStateRestorationEscrowState
}

/**
 *  iOS State Preservation / Restoration 的 pending peripheral 缓存器。
 *
 *  该对象只负责收集和去重 restored peripheral；具体匹配配置和恢复 GATT 流程交给
 *  BleStateRestorationFlow，避免在 willRestoreState 回调里直接执行业务连接。
 */
final class BleStateRestorationCoordinator {
    /// 等待当前账号 activation 精确认领的 restored peripherals。
    private var pendingPeripherals: [CBPeripheral] = []
    private let stateMachine = BleStateRestorationEscrowStateMachine()

    /**
     *  是否存在等待恢复的 peripheral。
     *
     *  BleManager 用它避免在每次 initConfigs / 生命周期事件里做无意义 drain。
     */
    var hasPendingPeripherals: Bool {
        !pendingPeripherals.isEmpty
    }

    /**
     *  缓存一个 restored peripheral。
     *
     *  CoreBluetooth 可能多次回放同一个 peripheral，按 identifier 去重可以避免重复 connectFinish。
     */
    @discardableResult
    func enqueue(_ peripheral: CBPeripheral) -> BleStateRestorationEscrowAction {
        // 1、按 CoreBluetooth identifier 去重，避免同一 restored peripheral 重复 replay。
        if let index = pendingPeripherals.firstIndex(where: { $0.identifier == peripheral.identifier }) {
            pendingPeripherals[index] = peripheral
        } else {
            pendingPeripherals.append(peripheral)
        }
        return stateMachine.stage(
            endpointId: peripheral.identifier.uuidString,
            peripheralState: peripheral.state
        )
    }

    /// 物理连接在 claim 前完成时只更新 escrow，不进入 GATT readiness。
    func didConnect(_ peripheral: CBPeripheral) -> BleStateRestorationEscrowAction {
        guard pendingPeripherals.contains(where: { $0.identifier == peripheral.identifier }) else {
            return .ignore
        }
        return stateMachine.didConnect(endpointId: peripheral.identifier.uuidString)
    }

    /// escrow terminal 每次只返回一个动作：系统已重连则保留，否则补一条 pending connect。
    func didTerminate(
        _ peripheral: CBPeripheral,
        systemIsReconnecting: Bool
    ) -> BleStateRestorationEscrowAction {
        guard pendingPeripherals.contains(where: { $0.identifier == peripheral.identifier }) else {
            return .ignore
        }
        return stateMachine.didTerminate(
            endpointId: peripheral.identifier.uuidString,
            systemIsReconnecting: systemIsReconnecting
        )
    }

    /**
     *  取出并清空 pending peripherals。
     *
     *  drain 语义保证每个 restored peripheral 只被 replay 一次，失败时由恢复流程决定是否重新 enqueue。
     */
    func drainPendingPeripherals() -> [CBPeripheral] {
        // 1、一次性取出并清空缓存；恢复流程决定失败后是否重新入队。
        let peripherals = pendingPeripherals
        pendingPeripherals.removeAll()
        stateMachine.reset()
        return peripherals
    }

    /**
     *  为当前 Dart recovery target 精确认领一个 restored peripheral。
     *
     *  1、优先使用非空 CoreBluetooth UUID；UUID 为空时只允许完整设备名唯一匹配。
     *  2、唯一匹配后立即从 pending 集合移除，保证同一 peripheral 只能被一个 owner 消费。
     *  3、同名多候选时 fail-closed，交回常规扫描解析，避免误连历史设备。
     */
    func claimPendingPeripheral(uuid: String, name: String) -> BleStateRestorationEscrowClaim? {
        // 1、规范化输入，避免空格导致已知 UUID 或完整名称无法匹配。
        let normalizedUuid = uuid.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        // 2、UUID 是 iOS peripheral 的最强身份；为空时才退化为完整名称匹配。
        let matches = pendingPeripherals.enumerated().filter { _, peripheral in
            if !normalizedUuid.isEmpty {
                return peripheral.identifier.uuidString.caseInsensitiveCompare(normalizedUuid) == .orderedSame
            }
            guard !normalizedName.isEmpty else { return false }
            return peripheral.name?.trimmingCharacters(in: .whitespacesAndNewlines) == normalizedName
        }
        // 3、只有唯一候选才能认领；歧义时不得猜测设备身份。
        guard matches.count == 1, let match = matches.first else {
            return nil
        }
        let peripheral = match.element
        guard let state = stateMachine.claim(endpointId: peripheral.identifier.uuidString) else {
            return nil
        }
        pendingPeripherals.remove(at: match.offset)
        return BleStateRestorationEscrowClaim(peripheral: peripheral, state: state)
    }

    /// 精确移除 hard-cancel/config revoke 命中的 escrow owner。
    func removePendingPeripherals(uuid: String, name: String) -> [CBPeripheral] {
        let normalizedUuid = uuid.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let removed = pendingPeripherals.filter { peripheral in
            (!normalizedUuid.isEmpty && peripheral.identifier.uuidString.caseInsensitiveCompare(normalizedUuid) == .orderedSame) ||
                (!normalizedName.isEmpty && peripheral.name?.trimmingCharacters(in: .whitespacesAndNewlines) == normalizedName)
        }
        let removedIds = Set(removed.map { $0.identifier.uuidString })
        pendingPeripherals.removeAll { removedIds.contains($0.identifier.uuidString) }
        stateMachine.remove(endpointIds: removedIds)
        return removed
    }

    /// reset/clean 会使本次 runtime restoration session 全部失效。
    @discardableResult
    func clearPendingPeripherals() -> [CBPeripheral] {
        // 1、reset/clean 直接丢弃本轮 restoration 债务，不允许旧对象复活连接。
        let peripherals = pendingPeripherals
        pendingPeripherals.removeAll()
        stateMachine.reset()
        return peripherals
    }
}
