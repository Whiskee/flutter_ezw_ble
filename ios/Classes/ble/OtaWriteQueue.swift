//
//  OtaWriteQueue.swift
//  flutter_ezw_ble
//
//  Created by Whiskee on 2026/5/12.
//
//  iOS OTA WriteWithoutResponse 写队列与背压控制
//  - 配套规范: docs/IOS_OTA_NOWAIT_SPEC.md
//  - 通过 canSendWriteWithoutResponse + peripheralIsReadyToSendWriteWithoutResponse: 做流控,
//    把 iOS OTA 通道的每包等回调改成填满 packets-per-event,与 Android WRITE_TYPE_NO_RESPONSE 对齐.
//

import CoreBluetooth
import Foundation
import Flutter

/// OTA 队列只依赖这组最小外设能力，XCTest 可以注入 fake，生产环境由 CBPeripheral 实现。
protocol OtaWritePeripheral: AnyObject {
    var otaEndpointId: String { get }
    var canSendWriteWithoutResponse: Bool { get }
}

extension CBPeripheral: OtaWritePeripheral {
    var otaEndpointId: String {
        return identifier.uuidString
    }
}

/// 单次 CoreBluetooth 提交目标。submit 返回 true 后才允许把 Dart Future 视为成功。
struct OtaWriteTarget {
    let characteristicUUID: String
    let submit: (OtaWritePeripheral, Data) -> Bool
}

/// OTA 队列使用可注入时钟，让 stall 判定在单元测试中保持确定性。
protocol OtaWriteClock {
    var now: Date { get }
}

struct SystemOtaWriteClock: OtaWriteClock {
    var now: Date {
        return Date()
    }
}

/// OTA 队列使用可注入调度器；生产环境仍在主队列做 watchdog 重试。
protocol OtaWriteScheduler {
    @discardableResult
    func schedule(after interval: TimeInterval, _ block: @escaping () -> Void) -> OtaWriteCancellable
}

protocol OtaWriteCancellable: AnyObject {
    func cancel()
}

final class DispatchOtaWriteCancellable: OtaWriteCancellable {
    private let workItem: DispatchWorkItem

    init(workItem: DispatchWorkItem) {
        self.workItem = workItem
    }

    func cancel() {
        workItem.cancel()
    }
}

struct MainQueueOtaWriteScheduler: OtaWriteScheduler {
    func schedule(after interval: TimeInterval, _ block: @escaping () -> Void) -> OtaWriteCancellable {
        let workItem = DispatchWorkItem(block: block)
        DispatchQueue.main.asyncAfter(deadline: .now() + interval, execute: workItem)
        return DispatchOtaWriteCancellable(workItem: workItem)
    }
}

/// 一批 framed OTA 小包共享一个 Dart Future；成功只在最后一包被 CoreBluetooth 接受后结算。
private final class OtaWriteBatch {
    let result: FlutterResult
    var remaining: Int
    var settled = false

    init(result: @escaping FlutterResult, remaining: Int) {
        self.result = result
        self.remaining = remaining
    }

    func settle(_ value: Any?) {
        guard !settled else {
            return
        }
        settled = true
        result(value)
    }
}

/// 单个 OTA 写入条目
private struct OtaWriteItem {
    let data: Data
    let target: OtaWriteTarget
    let result: FlutterResult
    let batch: OtaWriteBatch?
}

/// 使用无应答批量写队列的通道标识。
///
/// 只用于日志前缀和 typed error code；OTA 与文件各自持有独立队列实例，pending 从不共享，
/// 退出升级只能取消 OTA 队列，不得连带清掉正在传输的文件批次。
enum OtaWriteChannel {
    static let ota = "ota"
    static let file = "file"
}

/// 与 Dart `BleG2PsType` 对齐的私有服务类型；批量写入口只放行各自的通道。
enum BlePsTypeValue {
    static let ota = 1
    static let file = 3
}

/// 单外设、单通道的无应答写队列
/// - 服务于 `psType == 1` (OTA) 与 `psType == 3` (文件) 两条通道, 各自独立实例;
/// - 每 `softDrainEvery` 包主动让出, 等待 `peripheralIsReady` 回调再继续, 防止
///   `canSendWriteWithoutResponse` 在老机型上报喜不报忧时塞包丢失.
final class OtaWriteQueue {

    //  =========== Constants
    //  - 软节流阈值: 每写入 N 包主动让出, 等待 peripheralIsReady 后再继续
    //  - 可后续按机型实测调整
    private static let softDrainEvery: Int = 64
    //  - CoreBluetooth 偶发不再回调 peripheralIsReady 时, 定期重查 canSend,
    //    避免 Dart 侧 await 永久挂起并把后续 retry 堆进同一个 native queue.
    private static let backpressureRetryInterval: TimeInterval = 0.1
    //  - 软节流本身用于防突发丢包, 兜底重查要更保守, 避免绕过节流保护。
    private static let softThrottleRetryInterval: TimeInterval = 0.5
    //  - 原生侧提前用 typed error 释放 pending，让上层分类并终止当前 OTA 写入链路。
    private static let backpressureStallTimeout: TimeInterval = 4.0

    //  =========== Variables
    //  - 关联外设(弱引用避免循环持有)
    private weak var peripheral: OtaWritePeripheral?
    //  - 待写入队列
    private var pending: [OtaWriteItem] = []
    //  - 自上一次软节流以来已成功写入的包数
    private var sinceLastDrainSync: Int = 0
    //  - 进入 canSend=false / 软节流等待的时间
    private var backpressureStartedAt: Date?
    //  - 兜底重查任务; 只允许一个 pending work item
    private var backpressureRetryWorkItem: OtaWriteCancellable?
    //  - 时钟/调度器注入只服务于真实 XCTest 行为覆盖, 生产路径仍使用系统实现。
    private let clock: OtaWriteClock
    private let scheduler: OtaWriteScheduler
    //  - 通道标识: 只影响日志前缀与 typed error code, 不改变任何队列语义。
    private let channel: String
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

    init(
        peripheral: OtaWritePeripheral,
        logger: ((String) -> Void)? = nil,
        clock: OtaWriteClock = SystemOtaWriteClock(),
        scheduler: OtaWriteScheduler = MainQueueOtaWriteScheduler(),
        channel: String = OtaWriteChannel.ota
    ) {
        self.peripheral = peripheral
        self.logger = logger
        self.clock = clock
        self.scheduler = scheduler
        self.channel = channel
    }
}

// MARK: - Public Methods
extension OtaWriteQueue {

    /**
     *  入队一笔 OTA 写入
     *  - 调用方持有 Dart 端的 await, 直到本条完成后才会发下一包;
     *  - 即立即触发 pump, 在背压允许的窗口内尽量打满 packets-per-event.
     */
    func enqueue(data: Data, target: OtaWriteTarget, result: @escaping FlutterResult) {
        pending.append(OtaWriteItem(data: data, target: target, result: result, batch: nil))
        logger?("[ezw_ble][\(channel)] enqueued endpoint=\(peripheral?.otaEndpointId ?? "released") bytes=\(data.count) pending=\(pending.count)")
        pump()
    }

    /**
     * 一次入队一组已封装小包。
     *
     * Future 必须等最后一包 `writeValue` 被 CoreBluetooth 接受后才完成；第 N 包失败
     * 立即丢掉本批剩余 pending。不能把入队成功当成整批已写入。
     */
    func enqueueBatch(packets: [Data], target: OtaWriteTarget, result: @escaping FlutterResult) {
        guard !packets.isEmpty else {
            result(Self.unavailableError(
                endpoint: peripheral?.otaEndpointId ?? "",
                reason: "empty batch",
                pending: 0,
                channel: channel
            ))
            return
        }
        let batch = OtaWriteBatch(result: result, remaining: packets.count)
        packets.forEach { packet in
            pending.append(OtaWriteItem(
                data: packet,
                target: target,
                result: result,
                batch: batch
            ))
        }
        logger?(
            "[ezw_ble][\(channel)] batch enqueued endpoint=\(peripheral?.otaEndpointId ?? "released") " +
            "packets=\(packets.count) bytes=\(packets.reduce(0) { $0 + $1.count }) pending=\(pending.count)"
        )
        pump()
    }

    /**
     *  `peripheralIsReady(toSendWriteWithoutResponse:)` 接入点
     *  - OS 通知背压解除, 立即继续抽干队列.
     */
    func onPeripheralReadyToSendWriteWithoutResponse() {
        logger?("[ezw_ble][\(channel)] ready endpoint=\(peripheral?.otaEndpointId ?? "released") pending=\(pending.count)")
        clearBackpressureWait()
        pump()
    }

    /**
     *  取消并清空所有待写入数据
     *  - 用于断连/重置时用 typed FlutterError 释放 Dart await, 避免挂起;
     *  - WriteWithoutResponse 本就无 ack, 取消后业务层按错误类型分类并终止本轮写入。
     */
    func cancelAll(reason: String) {
        guard !pending.isEmpty else {
            return
        }
        logger?("[ezw_ble][\(channel)] cancelled endpoint=\(peripheral?.otaEndpointId ?? "released") reason=\(reason) pending=\(pending.count)")
        let snapshot = pending
        pending.removeAll()
        sinceLastDrainSync = 0
        clearBackpressureWait()
        completeSnapshot(
            snapshot,
            Self.error(
                code: "\(channel)_write_cancelled",
                endpoint: peripheral?.otaEndpointId,
                reason: reason,
                waitSeconds: nil,
                pending: snapshot.count
            )
        )
    }

    static func unavailableError(
        endpoint: String,
        reason: String,
        pending: Int = 0,
        channel: String = OtaWriteChannel.ota
    ) -> FlutterError {
        return error(code: "\(channel)_write_unavailable", endpoint: endpoint, reason: reason, waitSeconds: nil, pending: pending)
    }

    static func unsupportedError(
        endpoint: String,
        reason: String,
        pending: Int = 0,
        channel: String = OtaWriteChannel.ota
    ) -> FlutterError {
        return error(code: "\(channel)_write_unsupported", endpoint: endpoint, reason: reason, waitSeconds: nil, pending: pending)
    }

    static func stalledError(
        endpoint: String?,
        reason: String,
        waitSeconds: TimeInterval,
        pending: Int,
        channel: String = OtaWriteChannel.ota
    ) -> FlutterError {
        return error(code: "\(channel)_write_stalled", endpoint: endpoint, reason: reason, waitSeconds: waitSeconds, pending: pending)
    }
}

// MARK: - Private Methods
extension OtaWriteQueue {

    /**
     *  驱动队列:
     *  - 1、外设已释放则清空并通知 Dart 端 await 返回, 避免挂起;
     *  - 2、循环写入直到队列空, 或背压挂起, 或触发软节流阈值;
     *  - 3、每包提交给 CoreBluetooth 后 result(nil), Dart 侧自然按 await 串行发下一包.
     */
    private func pump() {
        //  1、外设已被释放(异常断连/重置), 清空所有 pending
        guard let peripheral = peripheral else {
            completePendingAsUnavailable(reason: "peripheral released")
            return
        }
        //  2、抽干队列, 直到背压或软节流命中
        while !pending.isEmpty {
            //  - 2.1、CoreBluetooth 暂时不能再吞包, 等下一次 peripheralIsReady 回调
            guard peripheral.canSendWriteWithoutResponse else {
                if shouldCancelStalledBackpressure(reason: "canSend=false") {
                    return
                }
                logger?("[ezw_ble][\(channel)] stalled endpoint=\(peripheral.otaEndpointId) reason=canSend=false wait=pending pending=\(pending.count)")
                scheduleBackpressureRetry(after: Self.backpressureRetryInterval)
                return
            }
            clearBackpressureWait()
            //  - 2.2、出队并写入
            let head = pending.removeFirst()
            guard head.target.submit(peripheral, head.data) else {
                completeItem(
                    head,
                    Self.unavailableError(
                        endpoint: peripheral.otaEndpointId,
                        reason: "peripheral released before submit",
                        pending: pending.count,
                        channel: channel
                    )
                )
                continue
            }
            sinceLastDrainSync += 1
            if head.batch == nil {
                logger?("[ezw_ble][\(channel)] submitted endpoint=\(peripheral.otaEndpointId) char=\(head.target.characteristicUUID) bytes=\(head.data.count) pending=\(pending.count)")
            }
            //  - 2.3、CoreBluetooth 已接受本次 writeValue 调用后才向 Dart 回包;
            //  -- WriteWithoutResponse 无设备 ack, 这里的成功只代表已提交给 CoreBluetooth。
            completeItem(head, nil)
            //  - 2.4、软节流: 每 N 包主动让出
            //  -- canSendWriteWithoutResponse 在 iPhone 6s/SE 一代等老机型上"报喜不报忧",
            //  -- 突发塞包会触发底层丢包, 这里强制等下一次 peripheralIsReady 回调
            if sinceLastDrainSync >= Self.softDrainEvery {
                logger?("[ezw_ble][\(channel)] stalled endpoint=\(peripheral.otaEndpointId) reason=softThrottle wait=ready pending=\(pending.count)")
                sinceLastDrainSync = 0
                markBackpressureWaitStarted()
                scheduleBackpressureRetry(after: Self.softThrottleRetryInterval)
                return
            }
        }
        clearBackpressureWait()
    }
}

private extension OtaWriteQueue {

    func completePendingAsUnavailable(reason: String) {
        guard !pending.isEmpty else {
            return
        }
        logger?("[ezw_ble][\(channel)] cancelled endpoint=released reason=\(reason) pending=\(pending.count)")
        let snapshot = pending
        pending.removeAll()
        sinceLastDrainSync = 0
        clearBackpressureWait()
        completeSnapshot(
            snapshot,
            Self.error(
                code: "\(channel)_write_unavailable",
                endpoint: nil,
                reason: reason,
                waitSeconds: nil,
                pending: snapshot.count
            )
        )
    }

    func completeItem(_ item: OtaWriteItem, _ value: Any?) {
        guard let batch = item.batch else {
            item.result(value)
            return
        }
        if let error = value {
            pending.removeAll { $0.batch === batch }
            batch.settle(error)
            return
        }
        batch.remaining -= 1
        if batch.remaining <= 0 {
            logger?("[ezw_ble][\(channel)] batch completed endpoint=\(peripheral?.otaEndpointId ?? "released") pending=\(pending.count)")
            batch.settle(nil)
        }
    }

    func completeSnapshot(_ snapshot: [OtaWriteItem], _ error: FlutterError) {
        var settledBatches = Set<ObjectIdentifier>()
        snapshot.forEach { item in
            if let batch = item.batch {
                if settledBatches.insert(ObjectIdentifier(batch)).inserted {
                    batch.settle(error)
                }
            } else {
                item.result(error)
            }
        }
    }
}

// MARK: - Backpressure Watchdog
private extension OtaWriteQueue {

    func markBackpressureWaitStarted() {
        if backpressureStartedAt == nil {
            backpressureStartedAt = clock.now
        }
    }

    func clearBackpressureWait() {
        backpressureStartedAt = nil
        backpressureRetryWorkItem?.cancel()
        backpressureRetryWorkItem = nil
    }

    func scheduleBackpressureRetry(after interval: TimeInterval) {
        markBackpressureWaitStarted()
        guard backpressureRetryWorkItem == nil else {
            return
        }
        backpressureRetryWorkItem = scheduler.schedule(after: interval) { [weak self] in
            guard let self = self else {
                return
            }
            self.backpressureRetryWorkItem = nil
            guard !self.pending.isEmpty else {
                return
            }
            self.pump()
        }
    }

    func shouldCancelStalledBackpressure(reason: String) -> Bool {
        markBackpressureWaitStarted()
        guard let startedAt = backpressureStartedAt else {
            return false
        }
        let waitSeconds = clock.now.timeIntervalSince(startedAt)
        guard waitSeconds >= Self.backpressureStallTimeout else {
            return false
        }
        logger?("[ezw_ble][\(channel)] stalled endpoint=\(peripheral?.otaEndpointId ?? "released") reason=\(reason) wait=\(String(format: "%.1f", waitSeconds))s pending=\(pending.count)")
        let snapshot = pending
        pending.removeAll()
        sinceLastDrainSync = 0
        clearBackpressureWait()
        completeSnapshot(
            snapshot,
            Self.stalledError(
                endpoint: peripheral?.otaEndpointId,
                reason: reason,
                waitSeconds: waitSeconds,
                pending: snapshot.count,
                channel: channel
            )
        )
        return true
    }
}

private extension OtaWriteQueue {

    static func error(
        code: String,
        endpoint: String?,
        reason: String,
        waitSeconds: TimeInterval?,
        pending: Int
    ) -> FlutterError {
        var details: [String: Any] = [
            "reason": reason,
            "pending": pending
        ]
        if let endpoint = endpoint {
            details["endpoint"] = endpoint
        }
        if let waitSeconds = waitSeconds {
            details["wait"] = waitSeconds
        }
        return FlutterError(
            code: code,
            message: reason,
            details: details
        )
    }
}
