//
//  BleUpgradeStateRegistry.swift
//  flutter_ezw_ble
//
//  Owns the native OTA marker and command-admission decision for each endpoint.
//

import Foundation

/**
 *  iOS Native 升级态的唯一状态源。
 *
 *  marker 必须始终存在为一个非可选集合；可选容器会让 optional chaining 在首次
 *  `enter` 时静默失效，进而同时绕过命令门禁和退出状态恢复。
 */
final class BleUpgradeStateRegistry {
    private var endpointIds: Set<String> = []

    /** 当前是否持有指定 endpoint 的升级 marker。 */
    func contains(_ endpointId: String) -> Bool {
        endpointIds.contains(endpointId)
    }

    /** 安装升级 marker；重复进入保持幂等，并返回是否首次插入。 */
    @discardableResult
    func enter(_ endpointId: String) -> Bool {
        endpointIds.insert(endpointId).inserted
    }

    /**
     *  消费升级 marker。
     *
     *  退出流程必须先消费 marker，再校验 live connection；这样迟到回调即使校验失败，
     *  也不能在后续再次复活已经失效的连接。
     */
    @discardableResult
    func consume(_ endpointId: String) -> Bool {
        endpointIds.remove(endpointId) != nil
    }

    /** 按设备撤销范围清理 marker，避免配置替换后旧 endpoint 继续阻断写入。 */
    func removeAll(where shouldRemove: (String) -> Bool) {
        endpointIds = Set(endpointIds.filter { !shouldRemove($0) })
    }

    /** 清理全部 marker，用于 reset 和 Bluetooth OFF 的中性 teardown。 */
    func clear() {
        endpointIds.removeAll()
    }

    /**
     *  判断一条写入能否穿过 Native OTA 门禁。
     *
     *  OTA 数据通道天然允许；common 只有上层协议已显式白名单确认时才允许。
     */
    func canSend(
        endpointId: String,
        psType: Int,
        allowDuringUpgrade: Bool = false
    ) -> Bool {
        !contains(endpointId) || psType == 1 || allowDuringUpgrade
    }

    /** 仅供 Native 单测验证 marker 生命周期，生产逻辑不得据此分支。 */
    var countForTesting: Int {
        endpointIds.count
    }
}
