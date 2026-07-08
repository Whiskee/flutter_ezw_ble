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
    let uuid: String
    /// 设备名作为 UUID 缺失/变化时的辅助匹配字段。
    var name: String
    /// 已执行的自动回连尝试次数，用于退避和最大次数限制。
    var attempt: Int = 0
    /// 非 passive 模式下的 backoff timer。
    var timer: Timer?
    /// 蓝牙关闭期间暂停任务，poweredOn 后由系统状态回调恢复。
    var pausedByBluetoothOff: Bool = false
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

    /**
     *  从明确字段构造持久化目标。
     */
    init(belongConfig: String, uuid: String, name: String) {
        self.belongConfig = belongConfig
        self.uuid = uuid
        self.name = name
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
    private func targets() -> [BleReconnectTarget] {
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
