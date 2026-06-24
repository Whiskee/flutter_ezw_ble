//
//  BleGattReadiness.swift
//  flutter_ezw_ble
//
//  Provides the single readiness gate used before emitting connectFinish.
//  CoreBluetooth may replay cached services, characteristics, and notify state
//  out of the order seen during a clean foreground connect.
//

import CoreBluetooth
import Foundation

/**
 *  GATT 初始化完成度快照。
 *
 *  自动回连和 State Restoration 都可能拿到已经缓存的 service/characteristic/notify 状态，
 *  不能依赖单个 delegate 回调顺序来判断连接完成，因此统一在这里做 readiness gate。
 */
struct BleGattReadiness {
    /// 当前配置要求全部就绪的私有服务数量。
    let expectedPrivateServiceCount: Int
    /// 已找到写特征的私有服务数量。
    let writeCount: Int
    /// 已找到读特征的私有服务数量。
    let readCount: Int
    /// 已完成 notify/CCCD 注册的读特征数量。
    let notifyCount: Int

    /**
     *  判断 GATT 是否可以对 Dart 发 connectFinish。
     *
     *  notify 使用 >= 是为了兼容 cached notify 或重复 notify 回调，不让乱序回调造成重复失败。
     */
    var isComplete: Bool {
        writeCount == expectedPrivateServiceCount &&
            readCount == expectedPrivateServiceCount &&
            notifyCount >= expectedPrivateServiceCount
    }

    /**
     *  输出固定 GATT readiness 摘要。
     *
     *  该字符串会进入 gatt/notifyReady 日志，用于定位到底是 service、char 还是 notify 卡住。
     */
    var summary: String {
        "notifyProgress=\(notifyCount)/\(expectedPrivateServiceCount), writeChars=\(writeCount), readChars=\(readCount)"
    }

    /**
     *  从当前连接设备缓存生成 readiness 快照。
     *
     *  只读取 BleConnectedDevice 已经维护的字典/集合，避免在 gate 内重新触发 GATT 操作。
     */
    static func make(device: BleConnectedDevice, config: BleConfig) -> BleGattReadiness {
        BleGattReadiness(
            expectedPrivateServiceCount: config.privateServices.count,
            writeCount: device.writeCharsDic.count,
            readCount: device.readCharsDic.count,
            notifyCount: device.notifiedReadCharUUIDs.count
        )
    }
}
