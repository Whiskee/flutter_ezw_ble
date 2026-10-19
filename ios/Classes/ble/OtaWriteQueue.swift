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
    var monotonicNow: TimeInterval { get }
}

struct SystemOtaWriteClock: OtaWriteClock {
    var now: Date {
        return Date()
    }

    var monotonicNow: TimeInterval {
        return ProcessInfo.processInfo.systemUptime
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

/// 一批 framed 小包共享一个 Dart Future，最后一包提交后才结算成功。
private final class OtaWriteBatch {
    let result: FlutterResult
    let packetCount: Int
    let byteCount: Int
    let enqueuedAt: Date
    var remaining: Int
    var readyCount = 0
    var backpressureCount = 0
    var backpressureWaitSeconds: TimeInterval = 0
    var softThrottleWaitSeconds: TimeInterval = 0
    var retryTimerLateSeconds: TimeInterval = 0
    var pollResumeCount = 0
    var callbackResumeCount = 0
    var softThrottleCount = 0
    var settled = false
    let extraMetrics: [String: Any]
    let metrics: (([String: Any]) -> Void)?

    init(result: @escaping FlutterResult, packets: [Data], enqueuedAt: Date, extraMetrics: [String: Any] = [:], metrics: (([String: Any]) -> Void)? = nil) {
        self.result = result
        packetCount = packets.count
        byteCount = packets.reduce(0) { $0 + $1.count }
        self.enqueuedAt = enqueuedAt
        self.extraMetrics = extraMetrics
        softThrottleWaitSeconds = Double(extraMetrics["nativeQueueSoftThrottleWaitMs"] as? Int ?? 0) / 1_000
        self.metrics = metrics
        remaining = packets.count
    }

    func settle(_ value: Any?) {
        guard !settled else { return }
        settled = true
        if value == nil {
            var payload = extraMetrics
            payload.merge([
                "nativeQueueBackpressureCount": backpressureCount,
                "nativeQueueBackpressureWaitMs": max(0, Int(backpressureWaitSeconds * 1_000)),
                "nativeQueueSoftThrottleWaitMs": max(0, Int(softThrottleWaitSeconds * 1_000)),
                "nativeQueueRetryTimerLateMs": max(0, Int(retryTimerLateSeconds * 1_000)),
                "nativeQueuePollResumeCount": pollResumeCount,
                "nativeQueueCallbackResumeCount": callbackResumeCount,
                "nativeQueueSoftThrottleCount": softThrottleCount
            ]) { _, new in new }
            metrics?(payload)
        }
        result(value)
    }
}

/// 单个 OTA 写入条目
private struct OtaWriteItem {
    let data: Data
    let target: OtaWriteTarget
    let expectedSessionGeneration: Int64
    let expectedAttemptGeneration: Int64
    let result: FlutterResult
    let batch: OtaWriteBatch?
}

enum OtaWriteChannel {
    static let ota = "ota"
    static let file = "file"
}

enum BlePsTypeValue {
    static let ota = 1
    static let file = 3
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
    //  - 15 秒只度量“队首 RAW 无法提交给 CoreBluetooth”的硬阻塞；协议 ACK 的
    //    30 秒无推进超时仍由 even_connect 持有，不能在 native 层混成同一个计时器。
    private static let backpressureStallTimeout: TimeInterval = 15.0

    //  =========== Variables
    //  - 关联外设(弱引用避免循环持有)
    private weak var peripheral: OtaWritePeripheral?
    //  - 待写入队列
    private var pending: [OtaWriteItem] = []
    //  - 自上一次软节流以来已成功写入的包数
    private var sinceLastDrainSync: Int = 0
    //  - 进入 canSend=false 等待的时间；softThrottle 不参与 15 秒硬阻塞计时。
    private var backpressureStartedAt: Date?
    //  - 诊断耗时使用单调时钟，避免系统时间跳变污染 native wait 指标。
    private var backpressureStartedAtMonotonic: TimeInterval?
    //  - softThrottle 是主动让出，不参与 15 秒 stall；仍单独度量，方便拆分
    //    “主动节流”等待与真实 canSend=false 硬背压。
    private var softThrottleStartedAtMonotonic: TimeInterval?
    //  - 当前等待原因仅用于结构化诊断，不能参与是否放行写入的判断。
    private var backpressureReason: String?
    //  - 每次建立或清理等待都推进 episode；旧 timer 即使迟到执行也不能驱动新 pending。
    private var backpressureEpisode: UInt64 = 0
    //  - 硬阻塞后必须等待上层 exact recovery 真实断开并清队列；否则迟到 ready
    //    可能继续发送旧 attempt 的后续 RAW。
    private var stalledAwaitingRecovery: Bool = false
    //  - 兜底重查任务; 只允许一个 pending work item
    private var backpressureRetryWorkItem: OtaWriteCancellable?
    //  - 记录 timer 计划时间与实际触发偏差；只写入批量 metrics，不追加高频日志。
    private var backpressureRetryScheduledAtMonotonic: TimeInterval?
    private var backpressureRetryDelay: TimeInterval?
    //  - 保留严格真实 ACK 收据只用于测量；64 包预算回收已撤销。
    //    Credit 命名保留 wire/埋点兼容性，收据不能改变计数、等待或定时器。
    private let otaWindowCreditLedger = OtaWindowCreditLedger()
    private var carriedOtaWindowCreditMetrics: [String: Any] = [:]
    // The legacy "credited" name stores timing only. An admitted FILE may still
    // wait on soft64 or canSend=false; retain its ACK anchor until actual submit.
    private var creditedNextFile: (data: Data, notificationAtMonotonic: TimeInterval)?
    //  - 时钟/调度器注入只服务于真实 XCTest 行为覆盖, 生产路径仍使用系统实现。
    private let clock: OtaWriteClock
    private let scheduler: OtaWriteScheduler
    // OTA 与文件传输各自持有队列实例，channel 只决定诊断和 typed error 命名。
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
    func enqueue(
        data: Data,
        target: OtaWriteTarget,
        expectedSessionGeneration: Int64 = 0,
        expectedAttemptGeneration: Int64 = 0,
        result: @escaping FlutterResult
    ) {
        if stalledAwaitingRecovery {
            result(Self.stalledError(
                endpoint: peripheral?.otaEndpointId,
                reason: "queue stalled awaiting OTA recovery disconnect",
                waitSeconds: Self.backpressureStallTimeout,
                pending: pending.count,
                expectedSessionGeneration: expectedSessionGeneration,
                expectedAttemptGeneration: expectedAttemptGeneration
            ))
            return
        }
        pending.append(OtaWriteItem(
            data: data,
            target: target,
            expectedSessionGeneration: expectedSessionGeneration,
            expectedAttemptGeneration: expectedAttemptGeneration,
            result: result,
            batch: nil
        ))
        logFileOnly("[ezw_ble][\(channel)] enqueued endpoint=\(peripheral?.otaEndpointId ?? "released") bytes=\(data.count) pending=\(pending.count)")
        pump()
    }

    /// 批量入口仍逐包提交给 CoreBluetooth，并为每包保留冻结的 exact owner。
    func enqueueBatch(
        packets: [Data],
        target: OtaWriteTarget,
        expectedSessionGeneration: Int64 = 0,
        expectedAttemptGeneration: Int64 = 0,
        metrics: (([String: Any]) -> Void)? = nil,
        result: @escaping FlutterResult
    ) {
        guard !packets.isEmpty else {
            result(Self.unavailableError(endpoint: peripheral?.otaEndpointId ?? "", reason: "empty batch", channel: channel))
            return
        }
        if stalledAwaitingRecovery {
            result(Self.stalledError(
                endpoint: peripheral?.otaEndpointId,
                reason: "queue stalled awaiting recovery disconnect",
                waitSeconds: Self.backpressureStallTimeout,
                pending: pending.count,
                channel: channel,
                expectedSessionGeneration: expectedSessionGeneration,
                expectedAttemptGeneration: expectedAttemptGeneration
            ))
            return
        }
        let batch = OtaWriteBatch(
            result: result,
            packets: packets,
            enqueuedAt: clock.now,
            extraMetrics: takeCarriedOtaWindowCreditMetrics(),
            metrics: metrics
        )
        packets.forEach { packet in
            pending.append(OtaWriteItem(
                data: packet,
                target: target,
                expectedSessionGeneration: expectedSessionGeneration,
                expectedAttemptGeneration: expectedAttemptGeneration,
                result: result,
                batch: batch
            ))
        }
        logFileOnly("[ezw_ble][\(channel)] batch enqueued endpoint=\(peripheral?.otaEndpointId ?? "released") packets=\(packets.count) bytes=\(batch.byteCount) pending=\(pending.count)")
        pump()
    }

    /// 为 RAW window 注册严格 ACK 测量记录。登记、提交、通知与消费收据
    /// 均不能释放64包软节流；它们只建立同 owner 的测量锚点。
    func registerOtaWindow(windowId: String, expectedAck: Data, owner: OtaWindowCreditOwner) -> Bool {
        guard channel == OtaWriteChannel.ota,
              pending.isEmpty,
              let registration = OtaWindowCreditRegistration(
                  windowId: windowId,
                  expectedAck: expectedAck,
                  owner: owner
              ),
              !stalledAwaitingRecovery else {
            return false
        }
        return otaWindowCreditLedger.register(registration)
    }

    /// 上层在 RAW batch Future 成功后调用。仅 allSubmitted 的窗口才有资格被
    /// 后续真实 ACK 测量；失败会立即丢弃该窗口，保持 64 包保护。
    func markOtaWindowSubmitted(windowId: String, owner: OtaWindowCreditOwner, success: Bool) -> Bool {
        guard channel == OtaWriteChannel.ota else {
            return false
        }
        guard success else {
            otaWindowCreditLedger.invalidate(windowId: windowId, owner: owner)
            return false
        }
        otaWindowCreditLedger.markSubmitted(windowId: windowId, owner: owner)
        return true
    }

    /// 原生 notify 入口只登记 receipt；Dart 下一条 FILE 携带相同
    /// receipt/window/owner 才能关联测量，任何阶段都不回收发送预算。
    func observeOtaAck(data: Data, owner: OtaWindowCreditOwner) -> [String: Any]? {
        guard channel == OtaWriteChannel.ota,
              let receipt = otaWindowCreditLedger.noteNotification(
                  data: data,
                  owner: owner,
                  monotonicNow: clock.monotonicNow
              ) else {
            return nil
        }
        return [
            "windowId": receipt.windowId,
            "receiptId": receipt.receiptId
        ]
    }

    /// 消费严格真实 ACK 收据只建立测量锚点；不得清零64包计数、结束软/硬等待
    /// 或取消 retry。FILE 实际提交时再计时，让 A/B 能观察原有等待成本。
    func recordOtaWindowAckForNextFile(windowId: String, receiptId: String, owner: OtaWindowCreditOwner, nextFile: Data) -> Bool {
        guard channel == OtaWriteChannel.ota,
              !stalledAwaitingRecovery,
              pending.isEmpty,
              isCanonicalNextFile(nextFile),
              let timing = otaWindowCreditLedger.consume(
                  windowId: windowId,
                  receiptId: receiptId,
                  owner: owner,
                  monotonicNow: clock.monotonicNow
              ) else {
            return false
        }
        creditedNextFile = (nextFile, timing.notificationAtMonotonic)
        carriedOtaWindowCreditMetrics = [
            "nativeNotifyToCreditMs": timing.nativeNotifyToCreditMs
        ]
        return true
    }

    /**
     *  `peripheralIsReady(toSendWriteWithoutResponse:)` 接入点
     *  - OS 通知背压解除, 立即继续抽干队列.
     */
    func onPeripheralReadyToSendWriteWithoutResponse() {
        pending.first?.batch?.readyCount += 1
        // 同时记录回调到达时的标志取值：回调到了但标志仍为 false，与回调根本不到，
        // 是两种不同的故障形态，只有在这里采样才能区分。外设已释放时无值可读。
        let canSend = peripheral.map { String($0.canSendWriteWithoutResponse) } ?? "released"
        if channel == OtaWriteChannel.ota {
            logger?("[ezw_ble][ota] ready endpoint=\(peripheral?.otaEndpointId ?? "released") episode=\(backpressureEpisode) canSend=\(canSend) pending=\(pending.count)")
        } else {
            logger?("[ezw_ble][\(channel)] ready endpoint=\(peripheral?.otaEndpointId ?? "released") episode=\(backpressureEpisode) canSend=\(canSend) pending=\(pending.count)")
        }
        // ready 回调本身不重置计时；只有 canSend 已真实恢复时 pump 才结束当前 episode，
        // 否则一次虚假/过早回调会把 15 秒 fail-closed 窗口无限向后延长。
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
            stalledAwaitingRecovery = false
            clearOtaWindowCredits()
            clearBackpressureWait()
            return
        }
        logger?("[ezw_ble][\(channel)] cancelled endpoint=\(peripheral?.otaEndpointId ?? "released") episode=\(backpressureEpisode) reason=\(reason) pending=\(pending.count)")
        let snapshot = pending
        pending.removeAll()
        sinceLastDrainSync = 0
        stalledAwaitingRecovery = false
        clearOtaWindowCredits()
        clearBackpressureWait()
        completeSnapshot(snapshot) { item in
            Self.error(
                code: "\(channel)_write_cancelled",
                endpoint: peripheral?.otaEndpointId,
                reason: reason,
                waitSeconds: nil,
                pending: snapshot.count,
                expectedSessionGeneration: item.expectedSessionGeneration,
                expectedAttemptGeneration: item.expectedAttemptGeneration
            )
        }
    }

    static func unavailableError(endpoint: String, reason: String, pending: Int = 0, channel: String = OtaWriteChannel.ota) -> FlutterError {
        return error(code: "\(channel)_write_unavailable", endpoint: endpoint, reason: reason, waitSeconds: nil, pending: pending)
    }

    static func unsupportedError(endpoint: String, reason: String, pending: Int = 0, channel: String = OtaWriteChannel.ota) -> FlutterError {
        return error(code: "\(channel)_write_unsupported", endpoint: endpoint, reason: reason, waitSeconds: nil, pending: pending)
    }

    static func stalledError(
        endpoint: String?,
        reason: String,
        waitSeconds: TimeInterval,
        pending: Int,
        channel: String = OtaWriteChannel.ota,
        expectedSessionGeneration: Int64,
        expectedAttemptGeneration: Int64
    ) -> FlutterError {
        return error(
            code: "\(channel)_write_stalled",
            endpoint: endpoint,
            reason: reason,
            waitSeconds: waitSeconds,
            pending: pending,
            expectedSessionGeneration: expectedSessionGeneration,
            expectedAttemptGeneration: expectedAttemptGeneration
        )
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
        guard !stalledAwaitingRecovery else {
            return
        }
        // A soft 64-packet yield is an explicit budget stop. Normal enqueue must not
        // bypass it; only the owned ready/poll path may reopen the queue. Even a
        // strictly verified real ACK remains observation-only during this A/B.
        if channel == OtaWriteChannel.ota, resumeSource == nil,
           softThrottleStartedAtMonotonic != nil, peripheral.canSendWriteWithoutResponse {
            return
        }
        //  2、抽干队列, 直到背压或软节流命中
        while !pending.isEmpty {
            //  - 2.1、CoreBluetooth 暂时不能再吞包, 等下一次 peripheralIsReady 回调
            guard peripheral.canSendWriteWithoutResponse else {
                pending.first?.batch?.backpressureCount += 1
                markBackpressureWaitStarted(reason: "canSend=false")
                if shouldCompleteStalledBackpressure(reason: "canSend=false") {
                    return
                }
                scheduleBackpressureRetry(after: Self.backpressureRetryInterval)
                return
            }
            logBackpressureResumeIfNeeded(source: resumeSource ?? "pump")
            recordResumeIfNeeded(source: resumeSource ?? "pump")
            finishSoftThrottleWaitIfNeeded()
            clearBackpressureWait()
            //  - 2.2、出队并写入
            let head = pending.removeFirst()
            guard head.target.submit(peripheral, head.data) else {
                if creditedNextFile?.data == head.data {
                    // A failed admission has no actual FILE timestamp. Do not
                    // attach this old ACK observation to a later unrelated RAW.
                    clearOtaWindowCredits()
                }
                completeItem(head, Self.unavailableError(
                    endpoint: peripheral.otaEndpointId,
                    reason: "peripheral released before submit",
                    pending: pending.count,
                    channel: channel
                ))
                continue
            }
            if let credited = creditedNextFile, credited.data == head.data {
                carriedOtaWindowCreditMetrics["nativeAckToNextFileMs"] =
                    OtaWindowCreditLedger.elapsedMilliseconds(
                        from: credited.notificationAtMonotonic,
                        to: clock.monotonicNow
                    )
                creditedNextFile = nil
            }
            sinceLastDrainSync += 1
            let shouldSoftThrottle = sinceLastDrainSync >= Self.softDrainEvery
            if shouldSoftThrottle { head.batch?.softThrottleCount += 1 }
            if head.batch == nil {
                logFileOnly("[ezw_ble][\(channel)] submitted endpoint=\(peripheral.otaEndpointId) char=\(head.target.characteristicUUID) bytes=\(head.data.count) pending=\(pending.count)")
            }
            //  - 2.3、CoreBluetooth 已接受本次 writeValue 调用后才向 Dart 回包;
            //  -- WriteWithoutResponse 无设备 ack, 这里的成功只代表已提交给 CoreBluetooth。
            completeItem(head, nil)
            //  - 2.4、软节流: 每 N 包主动让出
            //  -- canSendWriteWithoutResponse 在 iPhone 6s/SE 一代等老机型上"报喜不报忧",
            //  -- 突发塞包会触发底层丢包, 这里强制等下一次 peripheralIsReady 回调
            if shouldSoftThrottle {
                // OTA preserves the soft stop even at a terminal boundary: a
                // following enqueue is not itself evidence of a real ACK.
                if channel != OtaWriteChannel.ota && pending.isEmpty {
                    sinceLastDrainSync = 0
                    continue
                }
                sinceLastDrainSync = 0
                // softThrottle 只是主动让出以维持老机型稳定性；它不启动 canSend=false
                // 硬阻塞计时，下一次 poll 会在 canSend 仍为 false 时重新冻结起点。
                markSoftThrottleWait()
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
            // A terminal batch can leave only the soft timer/ACK slot behind.
            // Releasing the peripheral must invalidate those owners too.
            sinceLastDrainSync = 0
            clearOtaWindowCredits()
            clearBackpressureWait()
            return
        }
        logger?("[ezw_ble][\(channel)] cancelled endpoint=released reason=\(reason) pending=\(pending.count)")
        let snapshot = pending
        pending.removeAll()
        sinceLastDrainSync = 0
        stalledAwaitingRecovery = false
        clearOtaWindowCredits()
        clearBackpressureWait()
        completeSnapshot(snapshot) { item in
            Self.error(
                code: "\(channel)_write_unavailable",
                endpoint: nil,
                reason: reason,
                waitSeconds: nil,
                pending: snapshot.count,
                expectedSessionGeneration: item.expectedSessionGeneration,
                expectedAttemptGeneration: item.expectedAttemptGeneration
            )
        }
    }

    /// Complete one queue item, retiring only its failed batch before publishing
    /// the error. A stall's post-cleanup count proves local unsent-queue state,
    /// never CoreBluetooth drain or a firmware ACK.
    func completeItem(_ item: OtaWriteItem, _ value: Any?) {
        if let error = value {
            if let batch = item.batch {
                pending.removeAll { $0.batch === batch }
            }
            var completion: Any = error
            if let stalled = error as? FlutterError,
               stalled.code == "\(channel)_write_stalled",
               var details = stalled.details as? [String: Any] {
                // Keep legacy `pending` (including the failed head) for diagnostics.
                // Snapshot after same-batch cleanup and before callback reentrancy;
                // other batches/singles stay queued, and the stall gate stays shut.
                details["remainingPending"] = pending.count
                completion = FlutterError(code: stalled.code, message: stalled.message, details: details)
            }
            if let batch = item.batch {
                batch.settle(completion)
            } else {
                item.result(completion)
            }
            return
        }
        guard let batch = item.batch else {
            item.result(nil)
            return
        }
        batch.remaining -= 1
        if batch.remaining == 0 {
            logFileOnly("[ezw_ble][\(channel)] batch completed endpoint=\(peripheral?.otaEndpointId ?? "released") packets=\(batch.packetCount) bytes=\(batch.byteCount) elapsed=\(max(0, Int(clock.now.timeIntervalSince(batch.enqueuedAt) * 1_000)))ms ready=\(batch.readyCount) backpressure=\(batch.backpressureCount) softThrottle=\(batch.softThrottleCount) pending=\(pending.count)")
            batch.settle(nil)
        }
    }

    func completeSnapshot(_ snapshot: [OtaWriteItem], error: (OtaWriteItem) -> FlutterError) {
        var settledBatches = Set<ObjectIdentifier>()
        snapshot.forEach { item in
            if let batch = item.batch {
                if settledBatches.insert(ObjectIdentifier(batch)).inserted {
                    batch.settle(error(item))
                }
            } else {
                item.result(error(item))
            }
        }
    }
}

// MARK: - Backpressure Watchdog
private extension OtaWriteQueue {

    func markBackpressureWaitStarted(reason: String) {
        if backpressureStartedAt == nil || backpressureReason != reason {
            // A hard canSend=false wait supersedes any soft 64-packet yield. Cancel
            // that older retry before scheduling the 100ms poll, otherwise the stale
            // 500ms handle occupies the single retry slot and can leave Dart awaiting
            // until an unrelated callback arrives.
            finishSoftThrottleWaitIfNeeded()
            cancelScheduledRetryForWaitTransition()
            backpressureEpisode &+= 1
            backpressureStartedAt = clock.now
            backpressureStartedAtMonotonic = clock.monotonicNow
            backpressureReason = reason
            logFileOnly("[ezw_ble][\(channel)] backpressure endpoint=\(peripheral?.otaEndpointId ?? "released") episode=\(backpressureEpisode) reason=\(reason) wait=0.0s pending=\(pending.count)")
        }
    }

    func markSoftThrottleWait() {
        clearBackpressureWait()
        backpressureEpisode &+= 1
        softThrottleStartedAtMonotonic = clock.monotonicNow
        logFileOnly("[ezw_ble][\(channel)] throttle endpoint=\(peripheral?.otaEndpointId ?? "released") episode=\(backpressureEpisode) pending=\(pending.count)")
    }

    func clearBackpressureWait() {
        finishSoftThrottleWaitIfNeeded()
        if backpressureStartedAt != nil, let startedAt = backpressureStartedAtMonotonic {
            let waitSeconds = max(0, clock.monotonicNow - startedAt)
            pending.first?.batch?.backpressureWaitSeconds += waitSeconds
        }
        if backpressureStartedAt != nil || backpressureRetryWorkItem != nil {
            // 先推进 token，再取消任务；即使测试调度器或系统队列仍执行旧 block，
            // captured episode 也无法触碰下一次等待的 work item 或 pending。
            backpressureEpisode &+= 1
        }
        backpressureStartedAt = nil
        backpressureStartedAtMonotonic = nil
        backpressureReason = nil
        backpressureRetryWorkItem?.cancel()
        backpressureRetryWorkItem = nil
        backpressureRetryScheduledAtMonotonic = nil
        backpressureRetryDelay = nil
    }

    func scheduleBackpressureRetry(after interval: TimeInterval) {
        guard backpressureRetryWorkItem == nil else {
            return
        }
        let episode = backpressureEpisode
        backpressureRetryScheduledAtMonotonic = clock.monotonicNow
        backpressureRetryDelay = interval
        backpressureRetryWorkItem = scheduler.schedule(after: interval) { [weak self] in
            guard let self = self,
                  self.backpressureEpisode == episode else {
                return
            }
            self.recordRetryTimerFired()
            self.backpressureRetryWorkItem = nil
            self.backpressureRetryScheduledAtMonotonic = nil
            self.backpressureRetryDelay = nil
            guard !self.pending.isEmpty, !self.stalledAwaitingRecovery else {
                self.finishSoftThrottleWaitIfNeeded()
                return
            }
            self.pump(resumeSource: "poll")
        }
    }

    /// 15 秒仍不可写才终止队首请求；同批尾包在错误返回前撤销，其它请求仍须等
    /// exact recovery/cleanup。保持 stall gate，迟到 ready 不能复活未提交的旧包。
    func shouldCompleteStalledBackpressure(reason: String) -> Bool {
        guard let startedAt = backpressureStartedAtMonotonic else {
            return false
        }
        let waitSeconds = max(0, clock.monotonicNow - startedAt)
        guard waitSeconds >= Self.backpressureStallTimeout else {
            return false
        }
        let stalled = pending.removeFirst()
        let pendingCount = pending.count + 1
        logger?("[ezw_ble][\(channel)] stalled endpoint=\(peripheral?.otaEndpointId ?? "released") episode=\(backpressureEpisode) reason=\(reason) wait=\(String(format: "%.3f", waitSeconds))s pending=\(pendingCount) session=\(stalled.expectedSessionGeneration) attempt=\(stalled.expectedAttemptGeneration)")
        sinceLastDrainSync = 0
        stalledAwaitingRecovery = true
        clearOtaWindowCredits()
        clearBackpressureWait()
        completeItem(stalled, Self.stalledError(
            endpoint: peripheral?.otaEndpointId,
            reason: reason,
            waitSeconds: waitSeconds,
            pending: pendingCount,
            channel: channel,
            expectedSessionGeneration: stalled.expectedSessionGeneration,
            expectedAttemptGeneration: stalled.expectedAttemptGeneration
        ))
        return true
    }

    func logBackpressureResumeIfNeeded(source: String) {
        guard let startedAt = backpressureStartedAt else {
            return
        }
        let waitSeconds = clock.now.timeIntervalSince(startedAt)
        logFileOnly("[ezw_ble][\(channel)] resumed endpoint=\(peripheral?.otaEndpointId ?? "released") episode=\(backpressureEpisode) reason=\(backpressureReason ?? "unknown") source=\(source) wait=\(String(format: "%.3f", waitSeconds))s pending=\(pending.count)")
    }

    func finishSoftThrottleWaitIfNeeded() {
        guard let startedAt = softThrottleStartedAtMonotonic else {
            return
        }
        let waitSeconds = max(0, clock.monotonicNow - startedAt)
        if let batch = pending.first?.batch {
            batch.softThrottleWaitSeconds += waitSeconds
        } else if channel == OtaWriteChannel.ota, creditedNextFile != nil {
            // The measured FILE uses the single-packet API, not a RAW batch.
            // Carry its completed soft wait to the following RAW result without
            // changing when the wait ends or allowing the receipt to resume it.
            let previous = carriedOtaWindowCreditMetrics["nativeQueueSoftThrottleWaitMs"] as? Int ?? 0
            carriedOtaWindowCreditMetrics["nativeQueueSoftThrottleWaitMs"] =
                previous + max(0, Int(waitSeconds * 1_000))
        }
        softThrottleStartedAtMonotonic = nil
    }

    func cancelScheduledRetryForWaitTransition() {
        backpressureRetryWorkItem?.cancel()
        backpressureRetryWorkItem = nil
        backpressureRetryScheduledAtMonotonic = nil
        backpressureRetryDelay = nil
    }

    func recordRetryTimerFired() {
        guard let scheduledAt = backpressureRetryScheduledAtMonotonic,
              let delay = backpressureRetryDelay else {
            return
        }
        let lateSeconds = max(0, clock.monotonicNow - scheduledAt - delay)
        pending.first?.batch?.retryTimerLateSeconds += lateSeconds
    }

    func recordResumeIfNeeded(source: String) {
        guard backpressureStartedAt != nil || softThrottleStartedAtMonotonic != nil else {
            return
        }
        switch source {
        case "poll":
            pending.first?.batch?.pollResumeCount += 1
        case "callback":
            pending.first?.batch?.callbackResumeCount += 1
        default:
            break
        }
    }

    func clearOtaWindowCredits() {
        otaWindowCreditLedger.invalidate()
        carriedOtaWindowCreditMetrics.removeAll()
        creditedNextFile = nil
    }

    func takeCarriedOtaWindowCreditMetrics() -> [String: Any] {
        guard channel == OtaWriteChannel.ota, !carriedOtaWindowCreditMetrics.isEmpty else {
            return [:]
        }
        let metrics = carriedOtaWindowCreditMetrics
        carriedOtaWindowCreditMetrics.removeAll()
        return metrics
    }

    func isCanonicalNextFile(_ data: Data) -> Bool {
        guard channel == OtaWriteChannel.ota,
              data.count == 11 else {
            return false
        }
        let bytes = [UInt8](data)
        // FILE start is a phone->glasses, single-frame OTA command. The sync id
        // at byte 2 is intentionally variable, so do not bake it into the guard.
        return bytes[0] == 0xAA &&
            bytes[1] == 0x21 &&
            bytes[3] == 3 &&
            bytes[4] == 1 &&
            bytes[5] == 1 &&
            bytes[6] == 0xC0 &&
            bytes[7] == 0x00 &&
            bytes[8] == 0x02 &&
            // CRC16(02) = C1B2, little-endian on the unchanged wire protocol.
            bytes[9] == 0xB2 && bytes[10] == 0xC1
    }
}

private extension OtaWriteQueue {

    /// Successful OTA windows are measured through callbacks/metrics; text logs keep only
    /// abnormal evidence so full upgrades do not grow logs linearly with packet count.
    func logFileOnly(_ message: @autoclosure () -> String) {
        guard channel != OtaWriteChannel.ota else {
            return
        }
        logger?(message())
    }

    static func error(
        code: String,
        endpoint: String?,
        reason: String,
        waitSeconds: TimeInterval?,
        pending: Int,
        expectedSessionGeneration: Int64 = 0,
        expectedAttemptGeneration: Int64 = 0
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
        if expectedSessionGeneration > 0 {
            details["session"] = expectedSessionGeneration
            details["expectedSessionGeneration"] = expectedSessionGeneration
        }
        if expectedAttemptGeneration > 0 {
            details["attempt"] = expectedAttemptGeneration
            details["expectedAttemptGeneration"] = expectedAttemptGeneration
        }
        return FlutterError(
            code: code,
            message: reason,
            details: details
        )
    }
}
