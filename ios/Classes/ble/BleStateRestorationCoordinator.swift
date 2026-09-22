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
    /// escrow 期间系统对该 peripheral 发出过 `peerConnected` connection event 的时刻；
    /// claim 时对象仍为 `.connecting` 说明 restored pending 请求可能已不再绑定该链路。
    var peerConnectedObservedAt: Date? = nil
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
    /// 入队单调序号：finalize 只允许收口「认领窗口快照」内的对象。
    private var escrowSequence: Int64 = 0
    /// 每个 endpoint 的入队序号（同 identifier 替换时保留原序号，仍属同一逻辑对象）。
    private var entrySequences: [String: Int64] = [:]
    /// 认领窗口快照：每次 activation 把已知 escrow 纳入窗口；窗口后新入队对象
    /// （如 connectionEvent 持续交来的系统连接）不被迟到的 finalize 债务误取消。
    private var claimWindowSequence: Int64?
    /// central 尚未 poweredOn 时不得直接 connect；记下 endpoint 等 poweredOn 后补偿 rearm。
    private var powerOnRearmDeferrals: Set<String> = []
    /// escrow 期间收到系统 `peerConnected` 但对象仍非 `.connected` 的 endpoint 及时刻。
    private var peerConnectedObservations: [String: Date] = [:]

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
            escrowSequence += 1
            entrySequences[peripheral.identifier.uuidString] = escrowSequence
        }
        return stateMachine.stage(
            endpointId: peripheral.identifier.uuidString,
            peripheralState: peripheral.state
        )
    }

    /// 该 identifier 是否已在 escrow 中（connection event 只对已托管或当前目标对象有意义）。
    func contains(uuid: String) -> Bool {
        pendingPeripherals.contains {
            $0.identifier.uuidString.caseInsensitiveCompare(uuid) == .orderedSame
        }
    }

    /// activation 开始时把当前已知 escrow 全部纳入认领窗口；重复调用只会扩大窗口。
    func markClaimWindowSnapshot() {
        claimWindowSequence = max(claimWindowSequence ?? 0, escrowSequence)
    }

    /// 记录 escrow 期间的系统 `peerConnected` 证据；只对仍在 escrow 的对象登记。
    func notePeerConnectedObservation(uuid: String, at date: Date = Date()) {
        guard pendingPeripherals.contains(where: {
            $0.identifier.uuidString.caseInsensitiveCompare(uuid) == .orderedSame
        }) else {
            return
        }
        peerConnectedObservations[uuid] = date
    }

    /// 系统 `peerDisconnected` 或 escrow terminal 后，旧的 peerConnected 证据不得再驱动 claim 宽限。
    func clearPeerConnectedObservation(uuid: String) {
        peerConnectedObservations.removeValue(forKey: uuid)
    }

    /// 记录一个等待 poweredOn 的 rearm 债务；重复登记幂等。
    func deferPowerOnRearm(uuid: String) {
        powerOnRearmDeferrals.insert(uuid)
    }

    /// poweredOn 后取出仍在 escrow 中的 rearm 债务对象；不在 escrow 的债务直接丢弃。
    func takePowerOnRearmDeferrals() -> [CBPeripheral] {
        let uuids = powerOnRearmDeferrals
        powerOnRearmDeferrals.removeAll()
        return pendingPeripherals.filter { uuids.contains($0.identifier.uuidString) }
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
        // 链路已终止，此前的 peerConnected 证据随之失效。
        peerConnectedObservations.removeValue(forKey: peripheral.identifier.uuidString)
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
        entrySequences.removeAll()
        powerOnRearmDeferrals.removeAll()
        peerConnectedObservations.removeAll()
        stateMachine.reset()
        return peripherals
    }

    /**
     *  只取出「认领窗口快照」内的未认领对象，窗口后新入队的 escrow 保留。
     *
     *  finalize 是冷启动认领批次的收口债务；connectionEvent 在窗口建立后持续交来的
     *  系统连接对象属于下一轮 activation 的输入，不得被迟到的 finalize 误取消。
     *  从未建立窗口（本 runtime 无任何 activation）时按全量 drain 收口。
     */
    func drainClaimWindowPeripherals() -> [CBPeripheral] {
        guard let windowSequence = claimWindowSequence else {
            return drainPendingPeripherals()
        }
        let drained = pendingPeripherals.filter {
            (entrySequences[$0.identifier.uuidString] ?? 0) <= windowSequence
        }
        let drainedIds = Set(drained.map { $0.identifier.uuidString })
        pendingPeripherals.removeAll { drainedIds.contains($0.identifier.uuidString) }
        drainedIds.forEach {
            entrySequences.removeValue(forKey: $0)
            powerOnRearmDeferrals.remove($0)
            peerConnectedObservations.removeValue(forKey: $0)
        }
        stateMachine.remove(endpointIds: drainedIds)
        return drained
    }

    /**
     *  为当前 Dart recovery target 精确认领一个 restored peripheral。
     *
     *  1、优先使用非空 CoreBluetooth UUID；UUID 未命中时只允许完整设备名唯一匹配。
     *  2、名称兜底额外要求 peripheral 名称命中目标 config 的 nameFilters（与扫描
     *     管线同一 contains 语义），防止历史同名设备被跨 config 认领。
     *  3、唯一匹配后立即从 pending 集合移除，保证同一 peripheral 只能被一个 owner 消费。
     *  4、同名多候选时 fail-closed，交回常规扫描解析，避免误连历史设备。
     */
    func claimPendingPeripheral(
        uuid: String,
        name: String,
        nameFilters: [String] = []
    ) -> BleStateRestorationEscrowClaim? {
        // 1、规范化输入，避免空格导致已知 UUID 或完整名称无法匹配。
        let normalizedUuid = uuid.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        // 2、UUID 是 iOS peripheral 的最强身份；系统重启后 identifier 可能变化，只有
        // UUID 完全未命中时才允许以完整名称继续匹配，并仍要求最终候选唯一。
        var matches = pendingPeripherals.enumerated().filter { _, peripheral in
            !normalizedUuid.isEmpty &&
                peripheral.identifier.uuidString.caseInsensitiveCompare(normalizedUuid) == .orderedSame
        }
        if matches.isEmpty, !normalizedName.isEmpty {
            matches = pendingPeripherals.enumerated().filter { _, peripheral in
                guard let peripheralName = peripheral.name?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                    peripheralName == normalizedName else {
                    return false
                }
                // 名称兜底必须同时满足目标 config 的 nameFilters；未提供过滤器时
                // 保持完整名称精确匹配的既有语义。
                guard !nameFilters.isEmpty else { return true }
                return nameFilters.contains { peripheralName.contains($0) }
            }
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
        let peerConnectedObservedAt = peerConnectedObservations
            .removeValue(forKey: peripheral.identifier.uuidString)
        return BleStateRestorationEscrowClaim(
            peripheral: peripheral,
            state: state,
            peerConnectedObservedAt: peerConnectedObservedAt
        )
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
        removedIds.forEach {
            entrySequences.removeValue(forKey: $0)
            powerOnRearmDeferrals.remove($0)
            peerConnectedObservations.removeValue(forKey: $0)
        }
        stateMachine.remove(endpointIds: removedIds)
        return removed
    }

    /// reset/clean 会使本次 runtime restoration session 全部失效。
    @discardableResult
    func clearPendingPeripherals() -> [CBPeripheral] {
        // 1、reset/clean 直接丢弃本轮 restoration 债务，不允许旧对象复活连接。
        let peripherals = pendingPeripherals
        pendingPeripherals.removeAll()
        entrySequences.removeAll()
        powerOnRearmDeferrals.removeAll()
        peerConnectedObservations.removeAll()
        claimWindowSequence = nil
        stateMachine.reset()
        return peripherals
    }
}
