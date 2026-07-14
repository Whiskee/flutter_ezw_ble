//
//  BleReconnectStore.swift
//  flutter_ezw_ble
//
//  Persists reconnect targets and native reconnect/restoration events across
//  app lifecycle transitions. The data is intentionally small and identity-only;
//  GATT services and business auth are rebuilt after each physical reconnect.
//

import CoreBluetooth
import Foundation

/**
 *  运行时自动回连任务。
 *
 *  该任务只描述“应该继续尝试恢复物理链路”的意图，不代表私有服务或业务认证已恢复。
 */
struct BleReconnectTask {
    /// 目标所属配置，用于重建 BleEasyConnect。
    let belongConfig: String
    /// CoreBluetooth peripheral identifier。
    var uuid: String
    /// 设备名作为 UUID 缺失/变化时的辅助匹配字段。
    var name: String
    /// 已执行的自动回连尝试次数，用于退避和最大次数限制。
    var attempt: Int = 0
    /// 非 passive 模式下的 backoff timer。
    var timer: Timer?
    /// 蓝牙关闭期间暂停任务，poweredOn 后由系统状态回调恢复。
    var pausedByBluetoothOff: Bool = false
    /// 当前 pending attempt 来源；manual 只能影响本轮，终态后恢复 auto。
    var source: BleConnectSource = .autoReconnect
    /// 最近一次业务 connected 对应的 generation；Gate 释放后的系统断连复用它发送同代终态。
    var lastConnectedGeneration: Int64?
    /// iOS Code 14 表示对端已清除配对信息。此标记要求下一次尝试先等待一条新的目标广播，
    /// 禁止立即复用刚被系统拒绝的 CoreBluetooth peripheral cache。
    var requiresFreshAdvertisement: Bool = false
    /// 配对信息失配后的首轮恢复使用普通 connect，而非 iOS 17 的 system auto-reconnect
    /// option；长期 autoReconnect owner 仍保留，业务 connected 后再恢复系统 pending 策略。
    var requiresForegroundPairingRecovery: Bool = false
}

/// 发送系统终态时使用的连接来源与代次，二者必须作为同一快照一起继承。
struct BleTerminalConnectionMetadata: Equatable {
    let source: BleConnectSource
    let generation: Int64
}

/// 解析无 attempt token 的 CoreBluetooth 终态应该归属的已接受连接代次。
enum BleTerminalConnectionMetadataPolicy {
    static func resolve(
        state: BleConnectState,
        currentAdmission: BleConnectionAdmission?,
        reconnectTask: BleReconnectTask?,
        isBusinessConnected: Bool
    ) -> BleTerminalConnectionMetadata? {
        // 连接中/排队中的终态始终归属当前 Gate owner，不能被历史 task 覆盖。
        if let admission = currentAdmission, admission.generation > 0 {
            return BleTerminalConnectionMetadata(
                source: admission.source,
                generation: admission.generation
            )
        }
        // Gate 在业务 connected 后会释放；此后的真实系统断连只能继承最后一次
        // 业务成功代次。仍未业务连接的迟到 cancel callback 禁止走该 fallback。
        guard state == .disconnectFromSys,
              isBusinessConnected,
              let task = reconnectTask,
              let generation = task.lastConnectedGeneration,
              generation > 0 else {
            return nil
        }
        return BleTerminalConnectionMetadata(
            source: task.source,
            generation: generation
        )
    }
}

/// 蓝牙关闭前冻结的连接终态元数据，避免清理 Gate 后事件退化为 unknown/generation=0。
struct BleTransportOffConnectionSnapshot {
    let uuid: String
    let name: String
    let source: BleConnectSource
    let generation: Int64
}

/// 辅助扫描只有在稳定旧 UUID 与新 peripheral UUID 不同、且非空 name 明确相同时才允许
/// 迁移 reconnect owner；避免仅凭相同广播名误合并两个真实设备。
enum BleReconnectIdentityPolicy {
    static func shouldMigrate(
        taskUuid: String,
        taskName: String,
        peripheralUuid: String,
        peripheralName: String
    ) -> Bool {
        let oldUuid = taskUuid.trimmingCharacters(in: .whitespacesAndNewlines)
        let newUuid = peripheralUuid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !oldUuid.isEmpty,
              !newUuid.isEmpty,
              oldUuid.caseInsensitiveCompare(newUuid) != .orderedSame,
              !taskName.isEmpty,
              !peripheralName.isEmpty else {
            return false
        }
        return taskName == peripheralName
    }

    static func migratedTask(
        _ task: BleReconnectTask,
        peripheralUuid: String,
        peripheralName: String
    ) -> BleReconnectTask? {
        guard shouldMigrate(
            taskUuid: task.uuid,
            taskName: task.name,
            peripheralUuid: peripheralUuid,
            peripheralName: peripheralName
        ) else {
            return nil
        }
        var migrated = task
        migrated.uuid = peripheralUuid
        migrated.name = peripheralName
        return migrated
    }
}

/**
 * Dart 激活目标与历史持久 owner 冲突时的 canonical UUID 选择规则。
 *
 * 已知 alias 代表调用方仍持有旧 UUID，必须解析到当前 canonical；否则一个合法的
 * CoreBluetooth UUID 是本次调用的最新事实，不能被同名历史持久目标反向覆盖。
 * 只有 caller 仍是 temp/无效身份时才允许使用 persisted UUID 兜底。
 */
enum BleReconnectTargetIdentityPolicy {
    static func canonicalUuid(
        callerUuid: String,
        aliasCanonicalUuid: String?,
        persistedUuid: String?
    ) -> String {
        if let alias = nonBlank(aliasCanonicalUuid) {
            return alias
        }
        let caller = callerUuid.trimmingCharacters(in: .whitespacesAndNewlines)
        if UUID(uuidString: caller) != nil {
            return caller
        }
        return nonBlank(persistedUuid) ?? caller
    }

    private static func nonBlank(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

/// initConfigs 只撤销“之前允许自动回连、现在被删除或关闭”的配置 owner。
enum BleReconnectConfigDiff {
    static func revokedConfigNames(
        previous: [BleConfig],
        current: [BleConfig]
    ) -> Set<String> {
        let currentByName = Dictionary(uniqueKeysWithValues: current.map { ($0.name, $0) })
        return Set(previous.compactMap { config in
            guard config.autoReconnect else { return nil }
            guard let next = currentByName[config.name], next.autoReconnect else {
                return config.name
            }
            return nil
        })
    }
}

/**
 * CoreBluetooth UUID 漂移别名索引。
 *
 * 每个 canonical target 只保留“最早业务身份 + 最近一次旧身份”两个 alias：最早身份
 * 保证未刷新的 UI 仍能 hard cancel，最近身份覆盖相邻迁移回调；A→B→C… 不会线性增长。
 * 所有 alias 都直接指向 canonical，不形成链。
 */
final class BleReconnectIdentityAliasIndex {
    static let maxAliasesPerCanonical = 2

    private var canonicalByAlias: [String: String] = [:]
    private var aliasesByCanonical: [String: [String]] = [:]

    /// 仅当 uuid 是历史 alias 时返回当前 canonical UUID。
    func resolvedCanonical(uuid: String) -> String? {
        canonicalByAlias[identityKey(uuid)]
    }

    /// 已知旧身份与 canonical 身份时建立一条有界 alias 关系。
    func bind(aliasUuid: String, canonicalUuid: String) {
        migrate(from: aliasUuid, to: canonicalUuid)
    }

    /// owner 漂移时把旧 alias 直接改指新 canonical，并裁剪为常数个。
    func migrate(from oldUuid: String, to newUuid: String) {
        let oldKey = identityKey(oldUuid)
        let newKey = identityKey(newUuid)
        guard !oldKey.isEmpty, !newKey.isEmpty, oldKey != newKey else { return }

        var candidates = aliasesByCanonical.removeValue(forKey: oldKey) ?? []
        candidates.append(contentsOf: aliasesByCanonical.removeValue(forKey: newKey) ?? [])
        candidates.append(oldKey)

        // 清掉所有指向旧/新 canonical 的旧映射，随后只重建 bounded direct aliases。
        canonicalByAlias = canonicalByAlias.filter { alias, destination in
            let destinationKey = identityKey(destination)
            return alias != oldKey && destinationKey != oldKey && destinationKey != newKey
        }
        var unique: [String] = []
        for alias in candidates where alias != newKey && !unique.contains(alias) {
            unique.append(alias)
        }
        let bounded: [String]
        if unique.count <= Self.maxAliasesPerCanonical {
            bounded = unique
        } else {
            // 保留最早 UI owner，并保留最新旧身份；中间历史 UUID 可安全淘汰。
            bounded = [unique[0], unique[unique.count - 1]]
        }
        for alias in bounded {
            canonicalByAlias[alias] = newUuid
        }
        if !bounded.isEmpty {
            aliasesByCanonical[newKey] = bounded
        }
    }

    /// hard cancel/reset 后移除 canonical target 的全部历史 alias。
    func removeAliases(canonicalUuid: String) {
        let resolved = resolvedCanonical(uuid: canonicalUuid) ?? canonicalUuid
        let canonicalKey = identityKey(resolved)
        let aliases = aliasesByCanonical.removeValue(forKey: canonicalKey) ?? []
        aliases.forEach { canonicalByAlias.removeValue(forKey: $0) }
        canonicalByAlias = canonicalByAlias.filter { _, destination in
            identityKey(destination) != canonicalKey
        }
    }

    func reset() {
        canonicalByAlias.removeAll()
        aliasesByCanonical.removeAll()
    }

    /// XCTest 只读观测：单 target 迁移任意次数都不得超过固定 alias 上限。
    func aliasCountForTesting(canonicalUuid: String) -> Int {
        let resolved = resolvedCanonical(uuid: canonicalUuid) ?? canonicalUuid
        return aliasesByCanonical[identityKey(resolved)]?.count ?? 0
    }

    var totalAliasCountForTesting: Int {
        canonicalByAlias.count
    }

    private func identityKey(_ uuid: String) -> String {
        uuid.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

/**
 *  持久化的自动回连目标。
 *
 *  只保存身份和配置名，避免把任何可能过期的 GATT/service/char 状态写入磁盘。
 */
struct BleReconnectTarget {
    /// 目标所属配置名。
    let belongConfig: String
    /// CoreBluetooth peripheral identifier。
    let uuid: String
    /// 最近一次可见设备名。
    let name: String
    /// 缓存 MAC 的末六位提示；只用于空 UUID 阶段校验广播名，不作为平台 UUID。
    let expectedMacSuffix: String

    /**
     *  从明确字段构造持久化目标。
     */
    init(belongConfig: String, uuid: String, name: String, expectedMacSuffix: String = "") {
        self.belongConfig = belongConfig
        self.uuid = uuid
        self.name = name
        self.expectedMacSuffix = expectedMacSuffix
    }

    /**
     *  从 UserDefaults 原始字典恢复目标。
     *
     *  旧数据缺少必需身份字段时直接丢弃，避免错误恢复到不确定设备。
     */
    init?(raw: [String: String]) {
        guard let belongConfig = raw["belongConfig"],
              let uuid = raw["uuid"] else {
            return nil
        }
        self.belongConfig = belongConfig
        self.uuid = uuid
        self.name = raw["name"] ?? ""
        self.expectedMacSuffix = ""
    }

    /**
     *  转换为 UserDefaults 可保存的轻量字典。
     */
    var raw: [String: String] {
        [
            "belongConfig": belongConfig,
            "uuid": uuid,
            "name": name
        ]
    }
}

/// 空 UUID 的 iOS 目标由名称身份 owner 暂存，等待扫描补齐 CoreBluetooth UUID。
struct BlePendingReconnectIdentity {
    let belongConfig: String
    let name: String
    let expectedMacSuffix: String
    let source: BleConnectSource

    /// 配置名与完整广播名共同组成唯一 owner，避免仅凭 R1 前缀误连附近设备。
    var key: String {
        "\(belongConfig.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())|" +
            name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// MAC 提示只做附加约束；历史缓存缺失 MAC 时仍以完整名称作为身份事实。
    func matches(belongConfig candidateConfig: String, advertisedName: String) -> Bool {
        guard candidateConfig.caseInsensitiveCompare(belongConfig) == .orderedSame,
              advertisedName == name else {
            return false
        }
        let suffix = expectedMacSuffix.filter(\.isHexDigit).uppercased()
        return suffix.isEmpty || advertisedName.filter(\.isHexDigit).uppercased().hasSuffix(suffix)
    }
}

enum BleReconnectActivationState: String {
    case resolved
    case identityPending
    case rejected
}

/// MethodChannel 对单个目标的同步回执；上层据此区分真 owner 与静默丢弃。
struct BleReconnectActivationResult {
    let target: BleReconnectTarget
    let state: BleReconnectActivationState
    let reason: String

    var raw: [String: String] {
        [
            "belongConfig": target.belongConfig,
            "uuid": target.uuid,
            "name": target.name,
            "state": state.rawValue,
            "reason": reason
        ]
    }
}

/**
 *  自动回连持久化仓库。
 *
 *  UserDefaults 足够承载少量目标身份和短事件队列；这里不引入数据库，避免插件层扩大存储边界。
 */
final class BleReconnectStore {
    /// 自动回连目标列表 key。
    private let targetsKey = "flutter_ezw_ble.reconnect.targets"
    /// native 被系统唤醒但 Dart 尚未监听时的事件缓冲 key。
    private let eventsKey = "flutter_ezw_ble.reconnect.events"
    /// 注入 defaults 便于未来做 store 级测试。
    private let defaults: UserDefaults

    /**
     *  创建持久化仓库。
     */
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /**
     *  读取并清空 native 事件缓冲。
     *
     *  State Restoration 可能早于 Dart EventChannel 订阅发生，因此需要 drain 语义让 Dart 恢复后补读。
     */
    func drainEvents() -> [[String: Any]] {
        let events = defaults.array(forKey: eventsKey) as? [[String: Any]] ?? []
        defaults.removeObject(forKey: eventsKey)
        return events
    }

    /**
     *  记录一条 native 自动回连/恢复事件。
     *
     *  事件队列限制为最近 50 条，防止异常循环在 UserDefaults 中无限增长。
     */
    func recordEvent(type: String, uuid: String = "", name: String = "", detail: String = "") {
        var events = defaults.array(forKey: eventsKey) as? [[String: Any]] ?? []
        events.append([
            "type": type,
            "uuid": uuid,
            "name": name,
            "detail": detail,
            "timestamp": Date().timeIntervalSince1970
        ])
        if events.count > 50 {
            events = Array(events.suffix(50))
        }
        defaults.set(events, forKey: eventsKey)
    }

    /**
     *  查找一个持久化目标。
     *
     *  优先按 UUID 精确匹配，同时保留 name 匹配是为了兼容连接早期还处于临时 UUID 的场景。
     */
    func target(uuid: String, name: String = "") -> BleReconnectTarget? {
        targets().first { target in
            (!uuid.isEmpty && target.uuid.caseInsensitiveCompare(uuid) == .orderedSame) ||
                (!name.isEmpty && target.name == name)
        }
    }

    /**
     *  新增或更新一个持久化目标。
     *
     *  同一 UUID 或同一 name 只保留最新配置，避免历史目标导致 restoration 误匹配。
     */
    func upsert(device: BleConnectedDevice) {
        let uuid = device.peripheral.identifier.uuidString
        guard !uuid.isEmpty else {
            return
        }
        let name = device.peripheral.name ?? ""
        let next = targets()
            .filter { target in
                target.uuid.caseInsensitiveCompare(uuid) != .orderedSame &&
                    target.name != name
            } + [
                BleReconnectTarget(
                    belongConfig: device.belongConfig.name,
                    uuid: uuid,
                    name: name
                )
            ]
        saveTargets(next)
    }

    /// Dart 绑定缓存补种时没有 live CBPeripheral，允许按稳定身份直接写入。
    func upsert(target: BleReconnectTarget) {
        guard !target.uuid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        let next = targets()
            .filter { stored in
                stored.uuid.caseInsensitiveCompare(target.uuid) != .orderedSame &&
                    (target.name.isEmpty || stored.name != target.name)
            } + [target]
        saveTargets(next)
    }

    /// 单次 UserDefaults 写入完成旧 UUID -> 新 UUID 迁移，避免先删后写之间留下空目标窗口。
    func migrate(
        oldUuid: String,
        oldName: String,
        to target: BleReconnectTarget
    ) {
        guard !target.uuid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        let next = targets().filter { stored in
            let isOld = stored.uuid.caseInsensitiveCompare(oldUuid) == .orderedSame ||
                (!oldName.isEmpty && stored.name == oldName)
            let isNew = stored.uuid.caseInsensitiveCompare(target.uuid) == .orderedSame ||
                (!target.name.isEmpty && stored.name == target.name)
            return !isOld && !isNew
        } + [target]
        saveTargets(next)
    }

    /**
     *  移除一个持久化目标。
     *
     *  用户主动 disconnect/remove 时必须清理目标，否则系统断连回调可能再次触发自动回连。
     */
    func remove(uuid: String, name: String = "") {
        guard !uuid.isEmpty || !name.isEmpty else {
            return
        }
        saveTargets(
            targets().filter { target in
                !((!uuid.isEmpty && target.uuid.caseInsensitiveCompare(uuid) == .orderedSame) ||
                    (!name.isEmpty && target.name == name))
            }
        )
    }

    /// 配置删除/关闭 autoReconnect 时，一次 UserDefaults 写入移除该配置全部 owner。
    @discardableResult
    func removeTargets(configNames: Set<String>) -> [BleReconnectTarget] {
        guard !configNames.isEmpty else { return [] }
        let existing = targets()
        let removed = existing.filter { configNames.contains($0.belongConfig) }
        saveTargets(existing.filter { !configNames.contains($0.belongConfig) })
        return removed
    }

    /**
     *  清空全部持久化目标。
     *
     *  reset 场景需要彻底取消 native 自动回连意图。
     */
    func clearTargets() {
        defaults.removeObject(forKey: targetsKey)
    }

    /**
     *  读取全部有效目标。
     *
     *  compactMap 会自然丢弃旧版本或损坏的目标数据。
     */
    func targets() -> [BleReconnectTarget] {
        (defaults.array(forKey: targetsKey) as? [[String: String]] ?? [])
            .compactMap(BleReconnectTarget.init(raw:))
    }

    /**
     *  保存目标列表。
     *
     *  所有写入统一走这里，保证磁盘格式只暴露 BleReconnectTarget.raw。
     */
    private func saveTargets(_ targets: [BleReconnectTarget]) {
        defaults.set(targets.map(\.raw), forKey: targetsKey)
    }
}
