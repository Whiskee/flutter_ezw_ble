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

/// 单个 OTA 写入条目
private struct OtaWriteItem {
    let data: Data
    let target: OtaWriteTarget
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
    //  - CoreBluetooth 偶发不再回调 peripheralIsReady 时, 定期重查 canSend,
    //    避免 Dart 侧 await 永久挂起并把后续 retry 堆进同一个 native queue.
    private static let backpressureRetryInterval: TimeInterval = 0.1
    //  - 软节流本身用于防突发丢包, 兜底重查要更保守, 避免绕过节流保护。
    private static let softThrottleRetryInterval: TimeInterval = 0.5
    //  - 4 秒是异常背压的观测阈值；现场日志证明 CoreBluetooth 可能在阈值后数百毫秒
    //    才发布 ready，因此只进入一次有界宽限，不能在这里提前清掉仍可恢复的 pending。
    private static let backpressureStallTimeout: TimeInterval = 4.0
    //  - 宽限最多 1 秒；总等待 5 秒仍不可写时继续 fail-closed，避免 Dart await 永久挂起。
    private static let backpressureGraceTimeout: TimeInterval = 1.0

    //  =========== Variables
    //  - 关联外设(弱引用避免循环持有)
    private weak var peripheral: OtaWritePeripheral?
    //  - 待写入队列
    private var pending: [OtaWriteItem] = []
    //  - 自上一次软节流以来已成功写入的包数
    private var sinceLastDrainSync: Int = 0
    //  - 进入 canSend=false / 软节流等待的时间
    private var backpressureStartedAt: Date?
    //  - 同一次背压只允许进入一次 grace，避免 watchdog 每 100ms 重复记录阈值日志。
    private var backpressureEnteredGrace: Bool = false
    //  - 当前等待原因仅用于结构化诊断，不能参与是否放行写入的判断。
    private var backpressureReason: String?
    //  - 每次建立或清理等待都推进 episode；旧 timer 即使迟到执行也不能驱动新 pending。
    private var backpressureEpisode: UInt64 = 0
    //  - 兜底重查任务; 只允许一个 pending work item
    private var backpressureRetryWorkItem: OtaWriteCancellable?
    //  - 时钟/调度器注入只服务于真实 XCTest 行为覆盖, 生产路径仍使用系统实现。
    private let clock: OtaWriteClock
    private let scheduler: OtaWriteScheduler
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
        scheduler: OtaWriteScheduler = MainQueueOtaWriteScheduler()
    ) {
        self.peripheral = peripheral
        self.logger = logger
        self.clock = clock
        self.scheduler = scheduler
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
        pending.append(OtaWriteItem(data: data, target: target, result: result))
        logger?("[ezw_ble][ota] enqueued endpoint=\(peripheral?.otaEndpointId ?? "released") bytes=\(data.count) pending=\(pending.count)")
        pump()
    }

    /**
     *  `peripheralIsReady(toSendWriteWithoutResponse:)` 接入点
     *  - OS 通知背压解除, 立即继续抽干队列.
     */
    func onPeripheralReadyToSendWriteWithoutResponse() {
        logger?("[ezw_ble][ota] ready endpoint=\(peripheral?.otaEndpointId ?? "released") episode=\(backpressureEpisode) pending=\(pending.count)")
        // ready 回调本身不重置计时；只有 canSend 已真实恢复时 pump 才结束当前 episode，
        // 否则一次虚假/过早回调会把 5 秒 fail-closed 窗口无限向后延长。
        pump(resumeSource: "callback")
    }

    /**
     *  取消并清空所有待写入数据
     *  - 用于断连/重置时用 typed FlutterError 释放 Dart await, 避免挂起;
     *  - WriteWithoutResponse 本就无 ack, 取消后业务层按错误类型分类并终止本轮写入。
     */
    func cancelAll(reason: String) {
        guard !pending.isEmpty else {
            sinceLastDrainSync = 0
            clearBackpressureWait()
            return
        }
        logger?("[ezw_ble][ota] cancelled endpoint=\(peripheral?.otaEndpointId ?? "released") episode=\(backpressureEpisode) stage=\(backpressureStage) reason=\(reason) pending=\(pending.count)")
        let snapshot = pending
        pending.removeAll()
        sinceLastDrainSync = 0
        clearBackpressureWait()
        snapshot.forEach { item in
            item.result(Self.error(code: "ota_write_cancelled", endpoint: peripheral?.otaEndpointId, reason: reason, waitSeconds: nil, pending: snapshot.count))
        }
    }

    static func unavailableError(endpoint: String, reason: String, pending: Int = 0) -> FlutterError {
        return error(code: "ota_write_unavailable", endpoint: endpoint, reason: reason, waitSeconds: nil, pending: pending)
    }

    static func unsupportedError(endpoint: String, reason: String, pending: Int = 0) -> FlutterError {
        return error(code: "ota_write_unsupported", endpoint: endpoint, reason: reason, waitSeconds: nil, pending: pending)
    }

    static func stalledError(endpoint: String?, reason: String, waitSeconds: TimeInterval, pending: Int) -> FlutterError {
        return error(code: "ota_write_stalled", endpoint: endpoint, reason: reason, waitSeconds: waitSeconds, pending: pending)
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
    private func pump(resumeSource: String? = nil) {
        //  1、外设已被释放(异常断连/重置), 清空所有 pending
        guard let peripheral = peripheral else {
            completePendingAsUnavailable(reason: "peripheral released")
            return
        }
        //  2、抽干队列, 直到背压或软节流命中
        while !pending.isEmpty {
            //  - 2.1、CoreBluetooth 暂时不能再吞包, 等下一次 peripheralIsReady 回调
            guard peripheral.canSendWriteWithoutResponse else {
                markBackpressureWaitStarted(reason: "canSend=false")
                if shouldCompleteStalledBackpressure(reason: "canSend=false") {
                    return
                }
                scheduleBackpressureRetry(after: Self.backpressureRetryInterval)
                return
            }
            logBackpressureResumeIfNeeded(source: resumeSource ?? "pump")
            clearBackpressureWait()
            //  - 2.2、出队并写入
            let head = pending.removeFirst()
            guard head.target.submit(peripheral, head.data) else {
                head.result(Self.unavailableError(
                    endpoint: peripheral.otaEndpointId,
                    reason: "peripheral released before submit",
                    pending: pending.count
                ))
                continue
            }
            sinceLastDrainSync += 1
            logger?("[ezw_ble][ota] submitted endpoint=\(peripheral.otaEndpointId) char=\(head.target.characteristicUUID) bytes=\(head.data.count) pending=\(pending.count)")
            //  - 2.3、CoreBluetooth 已接受本次 writeValue 调用后才向 Dart 回包;
            //  -- WriteWithoutResponse 无设备 ack, 这里的成功只代表已提交给 CoreBluetooth。
            head.result(nil)
            //  - 2.4、软节流: 每 N 包主动让出
            //  -- canSendWriteWithoutResponse 在 iPhone 6s/SE 一代等老机型上"报喜不报忧",
            //  -- 突发塞包会触发底层丢包, 这里强制等下一次 peripheralIsReady 回调
            if sinceLastDrainSync >= Self.softDrainEvery {
                sinceLastDrainSync = 0
                markBackpressureWaitStarted(reason: "softThrottle")
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
        logger?("[ezw_ble][ota] cancelled endpoint=released reason=\(reason) pending=\(pending.count)")
        let snapshot = pending
        pending.removeAll()
        sinceLastDrainSync = 0
        clearBackpressureWait()
        snapshot.forEach { item in
            item.result(Self.error(
                code: "ota_write_unavailable",
                endpoint: nil,
                reason: reason,
                waitSeconds: nil,
                pending: snapshot.count
            ))
        }
    }
}

// MARK: - Backpressure Watchdog
private extension OtaWriteQueue {

    var backpressureStage: String {
        return backpressureEnteredGrace ? "grace" : "base"
    }

    func markBackpressureWaitStarted(reason: String) {
        if backpressureStartedAt == nil {
            backpressureEpisode &+= 1
            backpressureStartedAt = clock.now
            backpressureEnteredGrace = false
            backpressureReason = reason
            logger?("[ezw_ble][ota] backpressure endpoint=\(peripheral?.otaEndpointId ?? "released") episode=\(backpressureEpisode) stage=base reason=\(reason) wait=0.0s pending=\(pending.count)")
        }
    }

    func clearBackpressureWait() {
        if backpressureStartedAt != nil || backpressureRetryWorkItem != nil {
            // 先推进 token，再取消任务；即使测试调度器或系统队列仍执行旧 block，
            // captured episode 也无法触碰下一次等待的 work item 或 pending。
            backpressureEpisode &+= 1
        }
        backpressureStartedAt = nil
        backpressureEnteredGrace = false
        backpressureReason = nil
        backpressureRetryWorkItem?.cancel()
        backpressureRetryWorkItem = nil
    }

    func scheduleBackpressureRetry(after interval: TimeInterval) {
        guard backpressureRetryWorkItem == nil else {
            return
        }
        let episode = backpressureEpisode
        backpressureRetryWorkItem = scheduler.schedule(after: interval) { [weak self] in
            guard let self = self,
                  self.backpressureEpisode == episode,
                  self.backpressureStartedAt != nil else {
                return
            }
            self.backpressureRetryWorkItem = nil
            guard !self.pending.isEmpty else {
                return
            }
            self.pump(resumeSource: "poll")
        }
    }

    /// 4 秒只进入一次 grace，5 秒仍不可写才终止，兼顾迟到 ready 与有界 await。
    func shouldCompleteStalledBackpressure(reason: String) -> Bool {
        guard let startedAt = backpressureStartedAt else {
            return false
        }
        let waitSeconds = clock.now.timeIntervalSince(startedAt)
        guard waitSeconds >= Self.backpressureStallTimeout else {
            return false
        }
        let terminalTimeout = Self.backpressureStallTimeout + Self.backpressureGraceTimeout
        guard waitSeconds >= terminalTimeout else {
            if !backpressureEnteredGrace {
                backpressureEnteredGrace = true
                logger?("[ezw_ble][ota] backpressure endpoint=\(peripheral?.otaEndpointId ?? "released") episode=\(backpressureEpisode) stage=grace reason=\(reason) wait=\(String(format: "%.3f", waitSeconds))s pending=\(pending.count)")
            }
            return false
        }
        logger?("[ezw_ble][ota] stalled endpoint=\(peripheral?.otaEndpointId ?? "released") episode=\(backpressureEpisode) stage=terminal reason=\(reason) wait=\(String(format: "%.3f", waitSeconds))s pending=\(pending.count)")
        let snapshot = pending
        pending.removeAll()
        sinceLastDrainSync = 0
        clearBackpressureWait()
        snapshot.forEach { item in
            item.result(Self.stalledError(
                endpoint: peripheral?.otaEndpointId,
                reason: reason,
                waitSeconds: waitSeconds,
                pending: snapshot.count
            ))
        }
        return true
    }

    func logBackpressureResumeIfNeeded(source: String) {
        guard let startedAt = backpressureStartedAt else {
            return
        }
        let waitSeconds = clock.now.timeIntervalSince(startedAt)
        logger?("[ezw_ble][ota] resumed endpoint=\(peripheral?.otaEndpointId ?? "released") episode=\(backpressureEpisode) stage=\(backpressureStage) reason=\(backpressureReason ?? "unknown") source=\(source) wait=\(String(format: "%.3f", waitSeconds))s pending=\(pending.count)")
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
