//
//  OtaWriteQueue.swift
//  flutter_ezw_ble
//
//  Created by Whiskee on 2026/5/12.
//
//  iOS OTA WriteWithoutResponse 写队列与背压控制
//  - 配套规范: /Users/whiskee/Workspace/OpenSource/flutter_ezw_ble/IOS_OTA_NOWAIT_SPEC.md
//  - 通过 canSendWriteWithoutResponse + peripheralIsReadyToSendWriteWithoutResponse: 做流控,
//    把 iOS OTA 通道的每包等回调改成填满 packets-per-event,与 Android WRITE_TYPE_NO_RESPONSE 对齐.
//

import CoreBluetooth
import Flutter

/// 单个 OTA 写入条目
private struct OtaWriteItem {
    let data: Data
    let characteristic: CBCharacteristic
    let result: FlutterResult
}

/// 单外设的 OTA 写队列
/// - 仅服务于 `psType == 1` (BlePrivateService.type.ota) 通道;
/// - 每 `softDrainEvery` 包主动让出, 等待 `peripheralIsReady` 回调再继续, 防止
///   `canSendWriteWithoutResponse` 在老机型上报喜不报忧时塞包丢失.
final class OtaWriteQueue {

    //  =========== Constants
    //  - 软节流阈值: 每写入 N 包主动让出, 等待 peripheralIsReady 后再继续
    //  - 可后续按机型实测调整
    private static let softDrainEvery: Int = 64

    //  =========== Variables
    //  - 关联外设(弱引用避免循环持有)
    private weak var peripheral: CBPeripheral?
    //  - 待写入队列
    private var pending: [OtaWriteItem] = []
    //  - 自上一次软节流以来已成功写入的包数
    private var sinceLastDrainSync: Int = 0
    //  - 日志回调(由 BleManager 注入, 复用其 loggerD)
    private let logger: ((String) -> Void)?

    //  =========== Get/Set
    /// 当前队列深度(包含尚未写入 BLE 栈的项)
    var queueDepth: Int {
        return pending.count
    }

    /// 是否还有待写入数据
    var hasPending: Bool {
        return !pending.isEmpty
    }

    init(peripheral: CBPeripheral, logger: ((String) -> Void)? = nil) {
        self.peripheral = peripheral
        self.logger = logger
    }
}

// MARK: - Public Methods
extension OtaWriteQueue {

    /**
     *  入队一笔 OTA 写入
     *  - 调用方持有 Dart 端的 await, 直到本条 result(nil) 触发后才会发下一包;
     *  - 即立即触发 pump, 在背压允许的窗口内尽量打满 packets-per-event.
     */
    func enqueue(data: Data, characteristic: CBCharacteristic, result: @escaping FlutterResult) {
        pending.append(OtaWriteItem(data: data, characteristic: characteristic, result: result))
        pump()
    }

    /**
     *  `peripheralIsReady(toSendWriteWithoutResponse:)` 接入点
     *  - OS 通知背压解除, 立即继续抽干队列.
     */
    func onPeripheralReadyToSendWriteWithoutResponse() {
        logger?("[ezw_ble][ota] peripheralIsReady → resume pump (pending=\(pending.count))")
        pump()
    }

    /**
     *  取消并清空所有待写入数据
     *  - 用于断连/重置时通知 Dart 端 await 立即返回, 避免挂起;
     *  - WriteWithoutResponse 本就无 ack, 取消后业务层应通过 CRC 校验决定是否 retry.
     */
    func cancelAll(reason: String) {
        guard !pending.isEmpty else {
            return
        }
        logger?("[ezw_ble][ota] cancelAll reason=\(reason), discard pending=\(pending.count)")
        let snapshot = pending
        pending.removeAll()
        sinceLastDrainSync = 0
        snapshot.forEach { item in
            item.result(nil)
        }
    }
}

// MARK: - Private Methods
extension OtaWriteQueue {

    /**
     *  驱动队列:
     *  - 1、外设已释放则清空并通知 Dart 端 await 返回, 避免挂起;
     *  - 2、循环写入直到队列空, 或背压挂起, 或触发软节流阈值;
     *  - 3、每包写入后立即 result(nil), Dart 侧自然按 await 串行发下一包.
     */
    private func pump() {
        //  1、外设已被释放(异常断连/重置), 清空所有 pending
        guard let peripheral = peripheral else {
            cancelAll(reason: "peripheral released")
            return
        }
        //  2、抽干队列, 直到背压或软节流命中
        while !pending.isEmpty {
            //  - 2.1、CoreBluetooth 暂时不能再吞包, 等下一次 peripheralIsReady 回调
            guard peripheral.canSendWriteWithoutResponse else {
                logger?("[ezw_ble][ota] pump pause canSend=false, wait peripheralIsReady (pending=\(pending.count))")
                return
            }
            //  - 2.2、出队并写入
            let head = pending.removeFirst()
            peripheral.writeValue(
                head.data,
                for: head.characteristic,
                type: .withoutResponse
            )
            sinceLastDrainSync += 1
            //  - 2.3、立即向 Dart 端回包(WriteWithoutResponse 本就无 ack)
            head.result(nil)
            //  - 2.4、软节流: 每 N 包主动让出
            //  -- canSendWriteWithoutResponse 在 iPhone 6s/SE 一代等老机型上"报喜不报忧",
            //  -- 突发塞包会触发底层丢包, 这里强制等下一次 peripheralIsReady 回调
            if sinceLastDrainSync >= Self.softDrainEvery {
                logger?("[ezw_ble][ota] pump throttle (sinceLastDrainSync=\(sinceLastDrainSync)), wait peripheralIsReady")
                sinceLastDrainSync = 0
                return
            }
        }
    }
}
