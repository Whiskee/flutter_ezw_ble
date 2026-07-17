import CoreBluetooth
import Foundation

/// 一次真实物理连接回调等待进入全局 GATT pipeline 的身份。
struct BleConnectionAdmission: Equatable {
    let endpointId: String
    let generation: Int64
    let sessionId: Int64
    let source: BleConnectSource
}

/// Gate 排队期间保留的 CoreBluetooth session context。
struct BlePeripheralConnectionSession {
    var admission: BleConnectionAdmission
    let peripheral: CBPeripheral
    let config: BleConfig
    let deviceName: String
    let afterUpgrade: Bool
    /// 仅用于识别从未收到 CoreBluetooth 物理回调的陈旧 pending connect。已收到
    /// didConnect/contactDevice 后，即使业务 GATT 流程仍在进行，也绝不能由手动点击替换。
    let pendingConnectStartedAt: Date
    var hasObservedPhysicalContact: Bool = false
}

/// 非 CoreBluetooth 终态先记录 teardown 债务；只有 didFail/didDisconnect 或 watchdog
/// 确认后才释放全局 Gate 并启动下一 endpoint。
struct BlePendingConnectionAdmissionTeardown {
    let admission: BleConnectionAdmission
    let peripheral: CBPeripheral
    let deviceName: String
    let terminalState: BleConnectState
}

/// pre-didConnect watchdog 只负责选择超时后的资源策略，不改变 Flutter 的一分钟 UI 超时。
enum BlePendingPhysicalConnectWatchdogMode: Equatable {
    /// CoreBluetooth 的自动回连请求必须长期 pending；watchdog 只能观测，不能取消重建。
    case observeLongLivedAutoReconnect
    /// 普通前台连接允许有界回收，避免无长期 owner 时 admission 永久占用。
    case recycleForegroundAttempt

    static func resolve(autoReconnect: Bool) -> BlePendingPhysicalConnectWatchdogMode {
        autoReconnect ? .observeLongLivedAutoReconnect : .recycleForegroundAttempt
    }
}

/**
 * pre-didConnect 阶段 watchdog 的 attempt-scoped 注册表。
 *
 * CoreBluetooth 的回调不携带业务 generation；同一 peripheral 取消后会立刻创建下一代。
 * 注册表必须同时匹配 endpoint/generation/session，确保旧 timer 永远不能取消新一代连接。
 */
final class BlePendingPhysicalConnectWatchdogRegistry {
    private struct Entry {
        let admission: BleConnectionAdmission
        let workItem: DispatchWorkItem
    }

    private var entries: [String: Entry] = [:]
    private let lock = NSLock()

    /// 注册最新 attempt，调用方负责取消被替换的旧 work item。
    @discardableResult
    func replace(
        admission: BleConnectionAdmission,
        workItem: DispatchWorkItem
    ) -> DispatchWorkItem? {
        let key = endpointKey(admission.endpointId)
        guard !key.isEmpty else { return workItem }
        lock.lock()
        let replaced = entries.updateValue(
            Entry(admission: admission, workItem: workItem),
            forKey: key
        )?.workItem
        lock.unlock()
        return replaced
    }

    /// 只有 exact generation/session 才能消费 timeout 或成功回调。
    func takeIfCurrent(_ admission: BleConnectionAdmission) -> DispatchWorkItem? {
        let key = endpointKey(admission.endpointId)
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[key], entry.admission == admission else {
            return nil
        }
        entries.removeValue(forKey: key)
        return entry.workItem
    }

    /// 用户取消、配置撤销等 endpoint-scoped teardown 必须同步撤销 timer owner。
    func remove(endpointIds: Set<String>) -> [DispatchWorkItem] {
        let keys = Set(endpointIds.map(endpointKey).filter { !$0.isEmpty })
        lock.lock()
        defer { lock.unlock() }
        return keys.compactMap { key in
            entries.removeValue(forKey: key)?.workItem
        }
    }

    /// reset / 蓝牙关闭时原子失效所有 attempt。
    func removeAll() -> [DispatchWorkItem] {
        lock.lock()
        defer { lock.unlock() }
        let workItems = entries.values.map(\.workItem)
        entries.removeAll()
        return workItems
    }

    private func endpointKey(_ endpointId: String) -> String {
        endpointId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

/**
 * 辅助扫描确认设备重新可见后，为 exact admission 安装一次受控恢复定时器。
 *
 * 该定时器不扩展扫描预算，也不周期性重建连接；它只防止 CoreBluetooth 已长期
 * pending、设备已重新广播却始终没有 didConnect 的单次卡死。所有消费都要求
 * endpoint/generation/session 完全一致，旧可见性提示不能碰到后续连接代次。
 */
final class BleVisiblePendingRecoveryWatchdogRegistry {
    private struct Entry {
        let admission: BleConnectionAdmission
        let workItem: DispatchWorkItem
    }

    private var entries: [String: Entry] = [:]
    private let lock = NSLock()

    @discardableResult
    func replace(
        admission: BleConnectionAdmission,
        workItem: DispatchWorkItem
    ) -> DispatchWorkItem? {
        let key = endpointKey(admission.endpointId)
        guard !key.isEmpty else { return workItem }
        lock.lock()
        let replaced = entries.updateValue(
            Entry(admission: admission, workItem: workItem),
            forKey: key
        )?.workItem
        lock.unlock()
        return replaced
    }

    func takeIfCurrent(_ admission: BleConnectionAdmission) -> DispatchWorkItem? {
        let key = endpointKey(admission.endpointId)
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[key], entry.admission == admission else {
            return nil
        }
        entries.removeValue(forKey: key)
        return entry.workItem
    }

    func remove(endpointIds: Set<String>) -> [DispatchWorkItem] {
        let keys = Set(endpointIds.map(endpointKey).filter { !$0.isEmpty })
        lock.lock()
        defer { lock.unlock() }
        return keys.compactMap { entries.removeValue(forKey: $0)?.workItem }
    }

    func removeAll() -> [DispatchWorkItem] {
        lock.lock()
        defer { lock.unlock() }
        let workItems = entries.values.map(\.workItem)
        entries.removeAll()
        return workItems
    }

    private func endpointKey(_ endpointId: String) -> String {
        endpointId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

/// CoreBluetooth cancel 回调不带 attempt id；该 disposition 只消费取消债务，绝不直接
/// 终止当前 generation。
enum BlePeripheralCancellationCallbackDisposition: Equatable {
    /// 正常收到当前仍在阻塞新连接的 cancel 终态。
    case activeBarrier(Int64)
    /// watchdog 已经放行过新连接后，迟到的旧 cancel 终态。
    case timedOutBarrier
    /// 当前 endpoint 没有未消费的 cancel。
    case none
}

/// timed-out cancel debt 与新代真实断连共用无 token 回调时的保守处理策略。
enum BleTimedOutCancellationDebtAction: Equatable {
    /// 新 generation 仍在途：不误杀它，按 exact admission 重新驱动。
    case redriveCurrentAttempt
    /// 新 generation 已业务 connected：不能把真实系统断连当旧债务吞掉。
    case handleCurrentDisconnect
    /// 当前没有任何 owner，纯消费旧 cancel callback。
    case consumeStaleCallback
}

enum BleTimedOutCancellationDebtPolicy {
    static func action(
        hasCurrentAdmission: Bool,
        isBusinessConnected: Bool
    ) -> BleTimedOutCancellationDebtAction {
        if hasCurrentAdmission {
            return .redriveCurrentAttempt
        }
        if isBusinessConnected {
            return .handleCurrentDisconnect
        }
        return .consumeStaleCallback
    }
}

/**
 * 同一 CBPeripheral 复用时的取消代次状态机。
 *
 * active token 会阻塞下一次 `central.connect`；watchdog 超时后只累加一个饱和 debt
 * counter 并允许新连接继续。迟到 callback 始终先消费 debt，因此旧 callback 不会
 * 被错当成当前 generation 的连接失败。counter 让同 endpoint 长期漏回调时仍保持
 * 常数内存；所有 active token 操作都做 exact 匹配，旧 watchdog 不能释放后续 barrier。
 */
final class BlePeripheralCancellationBarrierGate {
    private var sequence: Int64 = 0
    private var activeTokens: [String: Int64] = [:]
    private var timedOutDebtCounts: [String: Int] = [:]

    /// 重复 cancel 同一个尚未完成的硬件操作时复用 token，避免制造不存在的 callback 债务。
    func begin(endpointId: String) -> (token: Int64, isNew: Bool)? {
        let key = endpointKey(endpointId)
        guard !key.isEmpty else { return nil }
        if let token = activeTokens[key] {
            return (token, false)
        }
        sequence += 1
        activeTokens[key] = sequence
        return (sequence, true)
    }

    func isBlocking(endpointId: String) -> Bool {
        activeTokens[endpointKey(endpointId)] != nil
    }

    /// 只有 exact watchdog token 可以放行；放行后用一个饱和 counter 记录迟到 callback 债务。
    func timeout(endpointId: String, token: Int64) -> Bool {
        let key = endpointKey(endpointId)
        guard activeTokens[key] == token else { return false }
        activeTokens.removeValue(forKey: key)
        let current = timedOutDebtCounts[key] ?? 0
        timedOutDebtCounts[key] = current == Int.max ? Int.max : current + 1
        return true
    }

    /// callback 按 cancel 发起顺序消费：先 timed-out debt，再当前 active barrier。
    func consumeCallback(endpointId: String) -> BlePeripheralCancellationCallbackDisposition {
        let key = endpointKey(endpointId)
        if let debtCount = timedOutDebtCounts[key], debtCount > 0 {
            if debtCount == 1 {
                timedOutDebtCounts.removeValue(forKey: key)
            } else {
                timedOutDebtCounts[key] = debtCount - 1
            }
            return .timedOutBarrier
        }
        guard let token = activeTokens.removeValue(forKey: key) else {
            return .none
        }
        return .activeBarrier(token)
    }

    func reset() {
        sequence += 1
        activeTokens.removeAll()
        timedOutDebtCounts.removeAll()
    }

    /// 配置撤销/硬取消会终止 endpoint 的所有旧 cancel 债务；未来重新授权必须建立新 barrier。
    func discard(endpointIds: Set<String>) {
        let keys = Set(endpointIds.map(endpointKey).filter { !$0.isEmpty })
        keys.forEach {
            activeTokens.removeValue(forKey: $0)
            timedOutDebtCounts.removeValue(forKey: $0)
        }
    }

    /// XCTest 只读观测：无论同 endpoint 超时多少次，状态始终只有一个 counter slot。
    var timedOutDebtEndpointCountForTesting: Int {
        timedOutDebtCounts.count
    }

    /// XCTest 只读观测：验证迟到 callback 逐笔优先消费 debt。
    func timedOutDebtCountForTesting(endpointId: String) -> Int {
        timedOutDebtCounts[endpointKey(endpointId)] ?? 0
    }

    private func endpointKey(_ endpointId: String) -> String {
        endpointId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

/**
 * cancellation barrier 后等待执行的最新连接意图。
 *
 * CoreBluetooth 的 cancel 回调不携带 generation；同 endpoint 在旧链路 teardown 期间
 * 可能连续收到多次手动连接请求。这里按 endpoint 只保留最新意图，并提供原子 take
 * 语义，保证 didDisconnect 与 watchdog 竞态时最多启动一次新 generation。
 */
final class BleDeferredPeripheralReconnectRegistry {
    private var options: [String: Bool] = [:]
    private let lock = NSLock()

    func deferConnection(endpointId: String, autoReconnect: Bool) {
        let key = endpointKey(endpointId)
        guard !key.isEmpty else { return }
        lock.lock()
        options[key] = autoReconnect
        lock.unlock()
    }

    func take(endpointId: String) -> Bool? {
        let key = endpointKey(endpointId)
        lock.lock()
        defer { lock.unlock() }
        return options.removeValue(forKey: key)
    }

    func contains(endpointId: String) -> Bool {
        let key = endpointKey(endpointId)
        lock.lock()
        defer { lock.unlock() }
        return options[key] != nil
    }

    func remove(endpointIds: Set<String>) {
        let keys = Set(endpointIds.map(endpointKey).filter { !$0.isEmpty })
        guard !keys.isEmpty else { return }
        lock.lock()
        keys.forEach { options.removeValue(forKey: $0) }
        lock.unlock()
    }

    func removeAll() {
        lock.lock()
        options.removeAll()
        lock.unlock()
    }

    private func endpointKey(_ endpointId: String) -> String {
        endpointId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

/// attempt-scoped source 迁移规则，避免一次手动点击永久污染长期自动回连。
enum BleReconnectSourcePolicy {
    static func onArm(
        current: BleConnectSource,
        incoming: BleConnectSource,
        businessConnected: Bool
    ) -> BleConnectSource {
        if incoming == .manualReconnect || current != .manualReconnect || businessConnected {
            return incoming
        }
        return current
    }

    static func afterTerminalAttempt() -> BleConnectSource {
        .autoReconnect
    }

    /// 蓝牙关闭会失效旧 Gate/session，恢复时 manual 不得泄漏到新 attempt。
    static func afterTransportReset() -> BleConnectSource {
        .autoReconnect
    }
}

/// 物理连接回调提交给 Gate 后的同步判定。
enum BleConnectionAdmissionDecision: Equatable {
    case granted
    case queued
    case stale
    case suspended
    case duplicate
    case invalidIdentity
}

///
/// iOS 全局 BLE 连接准入 Gate 的纯状态机。
///
/// automatic 节点按 CoreBluetooth callback FIFO；manual 节点只提升等待队列，绝不抢占
/// active owner。generation + sessionId 一起阻断 restoration/旧 peripheral 的迟到回调。
final class BleConnectionAdmissionGate {
    private var latestGenerations: [String: Int64] = [:]
    private var manualQueue: [BleConnectionAdmission] = []
    private var automaticQueue: [BleConnectionAdmission] = []
    private var active: BleConnectionAdmission?
    private var suspended = false
    private let lock = NSLock()

    /// 注册最新尝试代次，并移除同 endpoint 尚未执行的旧排队节点。
    func registerAttempt(endpointId: String, generation: Int64) {
        lock.lock()
        defer { lock.unlock() }
        guard !endpointId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let key = endpointKey(endpointId)
        if let current = latestGenerations[key], generation < current {
            return
        }
        latestGenerations[key] = generation
        manualQueue.removeAll { endpointKey($0.endpointId) == key && $0.generation < generation }
        automaticQueue.removeAll { endpointKey($0.endpointId) == key && $0.generation < generation }
    }

    /// 按真实物理 callback 到达顺序提交；首个节点立即成为 owner。
    func onPhysicalConnected(_ admission: BleConnectionAdmission) -> BleConnectionAdmissionDecision {
        lock.lock()
        defer { lock.unlock() }
        guard !admission.endpointId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .invalidIdentity
        }
        if suspended { return .suspended }
        guard latestGenerations[endpointKey(admission.endpointId)] == admission.generation else {
            return .stale
        }
        if active?.sameSession(as: admission) == true ||
            manualQueue.contains(where: { $0.sameSession(as: admission) }) ||
            automaticQueue.contains(where: { $0.sameSession(as: admission) }) {
            return .duplicate
        }
        guard active == nil else {
            if admission.source == .manualReconnect {
                manualQueue.append(admission)
            } else {
                automaticQueue.append(admission)
            }
            return .queued
        }
        active = admission
        return .granted
    }

    /// 仅 exact active session 可以完成；返回随后获得准入的节点。
    func complete(_ admission: BleConnectionAdmission) -> BleConnectionAdmission? {
        lock.lock()
        defer { lock.unlock() }
        guard active?.sameSession(as: admission) == true else { return nil }
        active = nil
        removeLatestGenerationIfOwned(by: admission)
        return grantNext()
    }

    /// 手动点击只提升同一个 pending session，不创建重复 CoreBluetooth connect。
    func promote(endpointId: String, generation: Int64, sessionId: Int64) {
        lock.lock()
        defer { lock.unlock() }
        guard let index = automaticQueue.firstIndex(where: {
            $0.matches(endpointId: endpointId, generation: generation, sessionId: sessionId)
        }) else { return }
        let current = automaticQueue.remove(at: index)
        manualQueue.append(
            BleConnectionAdmission(
                endpointId: current.endpointId,
                generation: current.generation,
                sessionId: current.sessionId,
                source: .manualReconnect
            )
        )
    }

    /// 真取消 endpoint 的 active/queued owner；active 被移除时返回下一位 owner。
    func cancelEndpoint(_ endpointId: String) -> BleConnectionAdmission? {
        cancelEndpoints(Set([endpointId]))
    }

    /// 配置撤销必须一次性移除整批 endpoint，再从仍获授权的队列选下一 owner。
    /// 逐个 cancel 会在批处理中途短暂 grant 同样即将被撤销的 waiter。
    func cancelEndpoints(_ endpointIds: Set<String>) -> BleConnectionAdmission? {
        lock.lock()
        defer { lock.unlock() }
        let keys = Set(endpointIds.map(endpointKey).filter { !$0.isEmpty })
        guard !keys.isEmpty else { return nil }
        keys.forEach { latestGenerations.removeValue(forKey: $0) }
        manualQueue.removeAll { keys.contains(endpointKey($0.endpointId)) }
        automaticQueue.removeAll { keys.contains(endpointKey($0.endpointId)) }
        guard active.map({ keys.contains(endpointKey($0.endpointId)) }) == true else { return nil }
        active = nil
        return grantNext()
    }

    /// reset/clean 在蓝牙仍开启时使所有旧 generation 失效，同时保持 Gate 可立即注册新尝试。
    func invalidateAllAndReset() {
        lock.lock()
        latestGenerations.removeAll()
        active = nil
        manualQueue.removeAll()
        automaticQueue.removeAll()
        suspended = false
        lock.unlock()
    }

    /// 只取消 exact session，不影响同 endpoint 已注册的更新 generation。
    func cancelSession(_ admission: BleConnectionAdmission) -> BleConnectionAdmission? {
        lock.lock()
        defer { lock.unlock() }
        manualQueue.removeAll { $0.sameSession(as: admission) }
        automaticQueue.removeAll { $0.sameSession(as: admission) }
        guard active?.sameSession(as: admission) == true else {
            removeLatestGenerationIfOwned(by: admission)
            return nil
        }
        active = nil
        removeLatestGenerationIfOwned(by: admission)
        return grantNext()
    }

    /// UUID owner 迁移后清除旧 endpoint 的 generation 槽；active/queued endpoint 不允许误删。
    func retireInactiveEndpoint(_ endpointId: String) {
        lock.lock()
        defer { lock.unlock() }
        let key = endpointKey(endpointId)
        guard active.map({ endpointKey($0.endpointId) == key }) != true,
              !manualQueue.contains(where: { endpointKey($0.endpointId) == key }),
              !automaticQueue.contains(where: { endpointKey($0.endpointId) == key }) else {
            return
        }
        latestGenerations.removeValue(forKey: key)
    }

    /// 蓝牙关闭会原子失效所有 owner/queue；旧 callback 恢复后也不能再次准入。
    func suspendAndReset() {
        lock.lock()
        defer { lock.unlock() }
        suspended = true
        // current/session 会被 Manager 同步清空；保留历史 endpoint 反而造成 identity 漂移泄漏。
        latestGenerations.removeAll()
        active = nil
        manualQueue.removeAll()
        automaticQueue.removeAll()
    }

    /// 蓝牙恢复只解除暂停；每个 endpoint 仍需注册新 generation。
    func resume() {
        lock.lock()
        suspended = false
        lock.unlock()
    }

    /// XCTest 只读观测：终态/迁移后历史 UUID 不得在线性表中残留。
    var trackedEndpointCountForTesting: Int {
        lock.lock()
        defer { lock.unlock() }
        return latestGenerations.count
    }

    private func grantNext() -> BleConnectionAdmission? {
        let next: BleConnectionAdmission?
        if !manualQueue.isEmpty {
            next = manualQueue.removeFirst()
        } else if !automaticQueue.isEmpty {
            next = automaticQueue.removeFirst()
        } else {
            next = nil
        }
        active = next
        return next
    }

    private func endpointKey(_ endpointId: String) -> String {
        endpointId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func removeLatestGenerationIfOwned(by admission: BleConnectionAdmission) {
        let key = endpointKey(admission.endpointId)
        guard latestGenerations[key] == admission.generation,
              active.map({ endpointKey($0.endpointId) == key }) != true,
              !manualQueue.contains(where: { endpointKey($0.endpointId) == key }),
              !automaticQueue.contains(where: { endpointKey($0.endpointId) == key }) else {
            return
        }
        latestGenerations.removeValue(forKey: key)
    }
}

private extension BleConnectionAdmission {
    func sameSession(as other: BleConnectionAdmission) -> Bool {
        matches(endpointId: other.endpointId, generation: other.generation, sessionId: other.sessionId)
    }

    func matches(endpointId: String, generation: Int64, sessionId: Int64) -> Bool {
        self.endpointId.caseInsensitiveCompare(endpointId) == .orderedSame &&
            self.generation == generation &&
            self.sessionId == sessionId
    }
}
