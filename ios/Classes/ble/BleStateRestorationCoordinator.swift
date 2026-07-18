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

/**
 *  iOS State Preservation / Restoration 的 pending peripheral 缓存器。
 *
 *  该对象只负责收集和去重 restored peripheral；具体匹配配置和恢复 GATT 流程交给
 *  BleStateRestorationFlow，避免在 willRestoreState 回调里直接执行业务连接。
 */
final class BleStateRestorationCoordinator {
    /// 等待 initConfigs 后重新匹配的 restored peripherals。
    private var pendingPeripherals: [CBPeripheral] = []

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
    func enqueue(_ peripheral: CBPeripheral) {
        // 1、按 CoreBluetooth identifier 去重，避免同一 restored peripheral 重复 replay。
        if pendingPeripherals.contains(where: { $0.identifier == peripheral.identifier }) {
            return
        }
        pendingPeripherals.append(peripheral)
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
        return peripherals
    }

    /// reset/clean 会使本次 runtime restoration session 全部失效。
    func clearPendingPeripherals() {
        // 1、reset/clean 直接丢弃本轮 restoration 债务，不允许旧对象复活连接。
        pendingPeripherals.removeAll()
    }
}
