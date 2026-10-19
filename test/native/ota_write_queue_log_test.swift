import Foundation

final class FakeOtaPeripheral: OtaWritePeripheral {
    let otaEndpointId = "ios-left"
    var canSendWriteWithoutResponse = true
}

final class FakeOtaClock: OtaWriteClock {
    var now = Date(timeIntervalSince1970: 1_000)
    var monotonicNow: TimeInterval = 1_000
}

final class FakeOtaTask: OtaWriteCancellable {
    let block: () -> Void
    let interval: TimeInterval
    let deadline: TimeInterval
    var cancelled = false

    init(interval: TimeInterval, deadline: TimeInterval, _ block: @escaping () -> Void) {
        self.interval = interval
        self.deadline = deadline
        self.block = block
    }

    func cancel() {
        cancelled = true
    }
}

final class FakeOtaScheduler: OtaWriteScheduler {
    private var tasks: [FakeOtaTask] = []
    private let clock: FakeOtaClock?

    init(clock: FakeOtaClock? = nil) { self.clock = clock }

    func schedule(after interval: TimeInterval, _ block: @escaping () -> Void) -> OtaWriteCancellable {
        let task = FakeOtaTask(interval: interval,
            deadline: (clock?.monotonicNow ?? 0) + interval, block)
        tasks.append(task)
        return task
    }

    var activeIntervals: [TimeInterval] {
        return tasks.filter { !$0.cancelled }.map(\.interval)
    }

    /// Deadline-aware mode proves 100/500ms ordering without wall-clock sleeps.
    /// Existing manual-fire mode remains useful for hostile cancelled callbacks.
    func advance(by seconds: TimeInterval) {
        guard let clock else { fatalError("A clock is required for deadline mode") }
        let end = clock.monotonicNow + seconds
        while let task = tasks.filter({ !$0.cancelled && $0.deadline <= end })
            .min(by: { $0.deadline < $1.deadline }) {
            tasks.removeAll { $0 === task }
            clock.now = clock.now.addingTimeInterval(task.deadline - clock.monotonicNow)
            clock.monotonicNow = task.deadline
            task.block()
        }
        clock.now = clock.now.addingTimeInterval(end - clock.monotonicNow)
        clock.monotonicNow = end
    }

    func runNext() {
        while !tasks.isEmpty {
            let task = tasks.removeFirst()
            if !task.cancelled {
                task.block()
                return
            }
        }
        fatalError("No active scheduled task")
    }

    /// Regression tests intentionally execute cancelled timers to model a main-queue
    /// block that was already dispatched before cancellation; production token checks
    /// must make that late block harmless.
    func runOldestIncludingCancelled() {
        guard !tasks.isEmpty else {
            fatalError("No scheduled task")
        }
        tasks.removeFirst().block()
    }
}

/// Host test for the native queue log contract; it uses fakes so no CoreBluetooth device is needed.
@main
struct OtaWriteQueueLogTests {
    static func main() throws {
        try successfulOtaBatchDoesNotEmitRoutineLogs()
        try successfulOtaBatchReportsMeasuredQueueMetrics()
        try softThrottleTransitionToHardBackpressureReplacesRetryTimer()
        try exact64PacketBatchDoesNotLeaveRetryTimer()
        try cancelledSoftThrottleTimerCannotDriveNewAttempt()
        try hardBackpressureStallTimerDoesNotRestartOnPoll()
        try stalledOtaStillLogsDiagnostic()
        try fileBatchKeepsExistingRoutineLogs()
        try verifiedAckDoesNotResetPartial64PacketBudget()
        try verifiedAckDoesNotReleaseSoftWaitAndKeepsMeasurements()
        try observedFileReadyCallbackKeepsSoftWaitMeasurement()
        try cancelledObservedFileDoesNotLeakMeasurements()
        try verifiedAckMeasuresWithoutBypassingBackpressure()
        try staleReceiptCannotMeasureNewWindow()
        try softToHardPollUsesNewDeadline()
        try failedObservedFileDoesNotLeakMeasurements()
        print("OTA write queue log reduction tests passed")
    }

    private static func successfulOtaBatchDoesNotEmitRoutineLogs() throws {
        let peripheral = FakeOtaPeripheral()
        let clock = FakeOtaClock()
        let scheduler = FakeOtaScheduler()
        var logs: [String] = []
        var submitted = 0
        var results: [Any?] = []
        let queue = OtaWriteQueue(
            peripheral: peripheral,
            logger: { logs.append($0) },
            clock: clock,
            scheduler: scheduler
        )
        let target = OtaWriteTarget(characteristicUUID: "ota-write") { _, _ in
            submitted += 1
            return true
        }

        queue.enqueueBatch(
            packets: (0..<32).map { Data([$0]) },
            target: target,
            result: { results.append($0) }
        )

        try assert(submitted == 32, "expected all OTA packets to submit")
        try assert(results.count == 1 && results.first! == nil, "expected successful batch result")
        try assert(logs.isEmpty, "successful OTA batch should not emit routine logs: \(logs)")
    }

    private static func successfulOtaBatchReportsMeasuredQueueMetrics() throws {
        let peripheral = FakeOtaPeripheral()
        peripheral.canSendWriteWithoutResponse = false
        let clock = FakeOtaClock()
        let scheduler = FakeOtaScheduler()
        var metrics: [[String: Any]] = []
        var results: [Any?] = []
        let queue = OtaWriteQueue(
            peripheral: peripheral,
            clock: clock,
            scheduler: scheduler
        )
        let target = OtaWriteTarget(characteristicUUID: "ota-write") { _, _ in true }

        queue.enqueueBatch(
            packets: [Data([0x01]), Data([0x02])],
            target: target,
            metrics: { metrics.append($0) },
            result: { results.append($0) }
        )
        clock.now = clock.now.addingTimeInterval(0.25)
        clock.monotonicNow += 0.25
        peripheral.canSendWriteWithoutResponse = true
        scheduler.runNext()

        try assert(results.count == 1 && results.first! == nil, "expected successful measured batch")
        try assert(metrics.count == 1, "expected exactly one metrics callback")
        try assert(metrics[0]["nativeQueueBackpressureCount"] as? Int == 1, "expected one backpressure sample")
        try assert(metrics[0]["nativeQueueBackpressureWaitMs"] as? Int == 250, "expected 250ms wait")
        try assert(metrics[0]["nativeQueueSoftThrottleCount"] as? Int == 0, "expected no soft throttle")
        try assert(metrics[0]["nativeQueueRetryTimerLateMs"] as? Int == 150, "expected 150ms late retry timer")
        try assert(metrics[0]["nativeQueuePollResumeCount"] as? Int == 1, "expected one poll resume")
        try assert(metrics[0]["nativeQueueCallbackResumeCount"] as? Int == 0, "expected no callback resume")
    }

    private static func softThrottleTransitionToHardBackpressureReplacesRetryTimer() throws {
        let peripheral = FakeOtaPeripheral()
        let clock = FakeOtaClock()
        let scheduler = FakeOtaScheduler()
        var submitted = 0
        var metrics: [[String: Any]] = []
        var results: [Any?] = []
        let queue = OtaWriteQueue(peripheral: peripheral, clock: clock, scheduler: scheduler)
        let target = OtaWriteTarget(characteristicUUID: "ota-write") { _, _ in
            submitted += 1
            return true
        }

        queue.enqueueBatch(
            packets: (0..<65).map { Data([$0]) },
            target: target,
            metrics: { metrics.append($0) },
            result: { results.append($0) }
        )
        try assert(submitted == 64, "expected soft throttle after 64 submitted packets")
        try assert(scheduler.activeIntervals == [0.5], "expected initial soft retry timer")

        peripheral.canSendWriteWithoutResponse = false
        queue.enqueue(data: Data([0xee]), target: target, result: { results.append($0) })

        try assert(scheduler.activeIntervals == [0.1], "hard backpressure must replace stale soft retry with 100ms poll")
        clock.now = clock.now.addingTimeInterval(0.1)
        clock.monotonicNow += 0.1
        peripheral.canSendWriteWithoutResponse = true
        scheduler.runOldestIncludingCancelled()
        try assert(scheduler.activeIntervals == [0.1], "late cancelled soft timer must not clear the live hard retry")
        scheduler.runNext()

        try assert(submitted == 66, "expected pending tail and new item to submit after hard retry")
        try assert(results.count == 2, "expected batch and single write to settle")
        try assert(metrics.count == 1, "expected batch metrics after tail submission")
        try assert(metrics[0]["nativeQueueSoftThrottleWaitMs"] as? Int == 0, "soft wait should be closed before hard wait starts")
        try assert(metrics[0]["nativeQueueBackpressureWaitMs"] as? Int == 100, "expected hard wait to measure only the 100ms retry")
    }

    private static func exact64PacketBatchDoesNotLeaveRetryTimer() throws {
        let peripheral = FakeOtaPeripheral()
        let clock = FakeOtaClock()
        let scheduler = FakeOtaScheduler()
        var submitted = 0
        var results: [Any?] = []
        var metrics: [[String: Any]] = []
        let queue = OtaWriteQueue(peripheral: peripheral, clock: clock, scheduler: scheduler)

        queue.enqueueBatch(
            packets: (0..<64).map { Data([$0]) },
            target: OtaWriteTarget(characteristicUUID: "ota-write") { _, _ in
                submitted += 1
                return true
            },
            metrics: { metrics.append($0) },
            result: { results.append($0) }
        )

        try assert(submitted == 64, "expected exact 64-packet batch to submit")
        try assert(results.count == 1 && results.first! == nil, "expected exact 64-packet batch to settle")
        try assert(scheduler.activeIntervals == [0.5], "exact OTA boundary must retain soft64 without ACK")
        try assert(metrics[0]["nativeQueueSoftThrottleCount"] as? Int == 1, "exact terminal batch should still count the 64th soft boundary")
        try assert(metrics[0]["nativeQueueSoftThrottleWaitMs"] as? Int == 0, "no pending tail means no soft wait time")

        queue.enqueue(data: Data([0xfa]), target: OtaWriteTarget(characteristicUUID: "ota-write") { _, _ in
            submitted += 1
            return true
        }, result: { results.append($0) })
        try assert(submitted == 64, "new enqueue alone cannot bypass no-ACK soft64")
        clock.monotonicNow += 0.5
        scheduler.runNext()
        try assert(submitted == 65, "owned fallback may resume the protected queue")

        let fileScheduler = FakeOtaScheduler()
        var fileSubmitted = 0
        let fileQueue = OtaWriteQueue(
            peripheral: peripheral,
            clock: clock,
            scheduler: fileScheduler,
            channel: OtaWriteChannel.file
        )
        fileQueue.enqueueBatch(
            packets: (0..<64).map { Data([$0]) },
            target: OtaWriteTarget(characteristicUUID: "file-write") { _, _ in
                fileSubmitted += 1
                return true
            },
            result: { _ in }
        )
        try assert(fileSubmitted == 64, "file exact 64-packet batch should submit")
        try assert(fileScheduler.activeIntervals.isEmpty, "file exact terminal soft throttle must not leave a retry timer")
    }

    private static func cancelledSoftThrottleTimerCannotDriveNewAttempt() throws {
        let peripheral = FakeOtaPeripheral()
        let clock = FakeOtaClock()
        let scheduler = FakeOtaScheduler()
        var submitted = 0
        var results: [Any?] = []
        let queue = OtaWriteQueue(peripheral: peripheral, clock: clock, scheduler: scheduler)
        let target = OtaWriteTarget(characteristicUUID: "ota-write") { _, _ in
            submitted += 1
            return true
        }

        queue.enqueueBatch(
            packets: (0..<65).map { Data([$0]) },
            target: target,
            result: { results.append($0) }
        )
        try assert(scheduler.activeIntervals == [0.5], "expected soft retry before cancellation")
        queue.cancelAll(reason: "new attempt")
        queue.enqueue(data: Data([0xfa]), target: target, result: { results.append($0) })
        scheduler.runOldestIncludingCancelled()

        try assert(submitted == 65, "cancelled soft timer must not submit cancelled tail")
        try assert(results.count == 2, "expected cancelled batch and new single result")
        try assert(results.last! == nil, "expected new attempt write to succeed")
    }

    private static let ack = Data([0xAA,0x12,7,4,1,1,0xC1,0,2,0,0x6D,0x7B])
    private static let file = Data([0xAA,0x21,8,3,1,1,0xC0,0,2,0xB2,0xC1])
    private static func creditOwner(attempt: Int64 = 1) -> OtaWindowCreditOwner {
        return OtaWindowCreditOwner(uuid: "ios-left", sessionGeneration: 1,
            attemptGeneration: attempt, transactionId: "tx", otaGeneration: 1,
            instanceId: "instance")!
    }

    /// A real ACK is now observation-only: packet accounting spans window boundaries.
    /// Reintroducing the old receipt-driven reset would send all 65 packets here.
    private static func verifiedAckDoesNotResetPartial64PacketBudget() throws {
        let peripheral = FakeOtaPeripheral()
        let scheduler = FakeOtaScheduler()
        let queue = OtaWriteQueue(peripheral: peripheral, scheduler: scheduler)
        let owner = creditOwner()
        var submitted = 0
        var completed = false
        let target = OtaWriteTarget(characteristicUUID: "ota") { _, _ in submitted += 1; return true }
        try assert(queue.registerOtaWindow(windowId: "partial", expectedAck: ack, owner: owner), "register partial window")
        queue.enqueueBatch(packets: (0..<18).map { Data([$0]) }, target: target, result: { value in
            _ = queue.markOtaWindowSubmitted(windowId: "partial", owner: owner, success: value == nil)
        })
        let receipt = queue.observeOtaAck(data: ack, owner: owner)!
        try assert(queue.recordOtaWindowAckForNextFile(windowId: "partial", receiptId: receipt["receiptId"] as! String,
            owner: owner, nextFile: file), "consume real ACK only for measurement")
        queue.enqueue(data: file, target: target, result: { _ in })
        queue.enqueueBatch(packets: (0..<46).map { Data([$0]) }, target: target, result: { _ in completed = true })
        try assert(submitted == 64 && queue.queueDepth == 1 && !completed,
            "real ACK must not reset the accumulated 64-packet budget")
        try assert(scheduler.activeIntervals == [0.5], "soft64 still owns its 500ms retry")
        scheduler.runNext()
        try assert(submitted == 65 && completed, "owned retry resumes the remaining packet once")
    }

    /// Receipt arrival during an existing soft wait must neither cancel its timer nor
    /// pump the FILE; the retained ACK timestamp includes that wait in the next sample.
    private static func verifiedAckDoesNotReleaseSoftWaitAndKeepsMeasurements() throws {
        let peripheral = FakeOtaPeripheral()
        let clock = FakeOtaClock()
        let scheduler = FakeOtaScheduler(clock: clock)
        let queue = OtaWriteQueue(peripheral: peripheral, clock: clock, scheduler: scheduler)
        let owner = creditOwner()
        var submitted = 0
        var fileCompleted = false
        var metrics: [String: Any] = [:]
        let target = OtaWriteTarget(characteristicUUID: "ota") { _, _ in submitted += 1; return true }
        try assert(queue.registerOtaWindow(windowId: "soft-wait", expectedAck: ack, owner: owner), "register soft window")
        queue.enqueueBatch(packets: (0..<64).map { Data([$0]) }, target: target, result: { value in
            _ = queue.markOtaWindowSubmitted(windowId: "soft-wait", owner: owner, success: value == nil)
        })
        scheduler.advance(by: 0.025)
        let receipt = queue.observeOtaAck(data: ack, owner: owner)!
        try assert(queue.recordOtaWindowAckForNextFile(windowId: "soft-wait", receiptId: receipt["receiptId"] as! String,
            owner: owner, nextFile: file), "record actual ACK anchor")
        try assert(scheduler.activeIntervals == [0.5], "real ACK must not cancel the soft retry")
        queue.enqueue(data: file, target: target, result: { _ in fileCompleted = true })
        scheduler.advance(by: 0.474)
        try assert(submitted == 64 && !fileCompleted, "FILE stays pending before the original soft deadline")
        scheduler.advance(by: 0.002)
        try assert(submitted == 65 && fileCompleted, "FILE submits once at the owned soft deadline")
        queue.enqueueBatch(packets: [Data([9])], target: target, metrics: { metrics = $0 }, result: { _ in })
        try assert(metrics["nativeNotifyToCreditMs"] as? Int == 0, "legacy credit field measures admission only")
        let ackToFile = metrics["nativeAckToNextFileMs"] as? Int
        try assert(ackToFile == 474 || ackToFile == 475, "actual FILE sample includes retained soft wait")
        try assert(metrics["nativeQueueSoftThrottleWaitMs"] as? Int == 500, "FILE soft wait remains measurable after rollback")
    }

    /// An actual ready callback may resume soft64 before its poll deadline, but
    /// consuming an ACK cannot; the old cancelled poll cannot re-publish a sample.
    private static func observedFileReadyCallbackKeepsSoftWaitMeasurement() throws {
        let peripheral = FakeOtaPeripheral()
        let clock = FakeOtaClock()
        let scheduler = FakeOtaScheduler(clock: clock)
        let queue = OtaWriteQueue(peripheral: peripheral, clock: clock, scheduler: scheduler)
        let owner = creditOwner()
        var submitted = 0
        var metrics: [String: Any] = [:]
        let target = OtaWriteTarget(characteristicUUID: "ota") { _, _ in submitted += 1; return true }
        try assert(queue.registerOtaWindow(windowId: "ready-file", expectedAck: ack, owner: owner), "register callback window")
        queue.enqueueBatch(packets: (0..<64).map { Data([$0]) }, target: target, result: { value in
            _ = queue.markOtaWindowSubmitted(windowId: "ready-file", owner: owner, success: value == nil)
        })
        scheduler.advance(by: 0.025)
        let receipt = queue.observeOtaAck(data: ack, owner: owner)!
        try assert(queue.recordOtaWindowAckForNextFile(windowId: "ready-file", receiptId: receipt["receiptId"] as! String,
            owner: owner, nextFile: file), "record callback measurement anchor")
        queue.enqueue(data: file, target: target, result: { _ in })
        try assert(submitted == 64, "ACK plus enqueue cannot reopen soft64")
        scheduler.advance(by: 0.025)
        queue.onPeripheralReadyToSendWriteWithoutResponse()
        try assert(submitted == 65 && scheduler.activeIntervals.isEmpty, "actual ready resumes FILE and cancels old poll")
        queue.enqueueBatch(packets: [Data([9])], target: target, metrics: { metrics = $0 }, result: { _ in })
        let softWait = metrics["nativeQueueSoftThrottleWaitMs"] as? Int
        let ackToFile = metrics["nativeAckToNextFileMs"] as? Int
        try assert(softWait == 49 || softWait == 50, "callback still measures completed FILE soft wait")
        try assert(ackToFile == 24 || ackToFile == 25, "actual callback submission retains the ACK anchor")
        scheduler.runOldestIncludingCancelled()
        queue.enqueueBatch(packets: [Data([10])], target: target, metrics: { metrics = $0 }, result: { _ in })
        try assert(submitted == 67 && metrics["nativeAckToNextFileMs"] == nil,
            "late old poll cannot submit twice or re-publish consumed timing")
    }

    /// Cancelling a FILE still awaiting soft64 drops its local timing owner and
    /// work item; a later attempt must not inherit either from the old receipt.
    private static func cancelledObservedFileDoesNotLeakMeasurements() throws {
        let peripheral = FakeOtaPeripheral()
        let clock = FakeOtaClock()
        let scheduler = FakeOtaScheduler(clock: clock)
        let queue = OtaWriteQueue(peripheral: peripheral, clock: clock, scheduler: scheduler)
        let owner = creditOwner()
        var fileResults: [Any?] = []
        var submitted = 0
        var metrics: [String: Any] = [:]
        let target = OtaWriteTarget(characteristicUUID: "ota") { _, _ in submitted += 1; return true }
        try assert(queue.registerOtaWindow(windowId: "cancelled-file", expectedAck: ack, owner: owner), "register cancelled window")
        queue.enqueueBatch(packets: (0..<64).map { Data([$0]) }, target: target, result: { value in
            _ = queue.markOtaWindowSubmitted(windowId: "cancelled-file", owner: owner, success: value == nil)
        })
        scheduler.advance(by: 0.025)
        let receipt = queue.observeOtaAck(data: ack, owner: owner)!
        try assert(queue.recordOtaWindowAckForNextFile(windowId: "cancelled-file", receiptId: receipt["receiptId"] as! String,
            owner: owner, nextFile: file), "record pending FILE measurement")
        queue.enqueue(data: file, target: target, result: { fileResults.append($0) })
        queue.cancelAll(reason: "replace attempt")
        try assert(fileResults.count == 1 && fileResults[0] != nil && queue.queueDepth == 0,
            "cancelled pending FILE has one terminal failure")
        queue.enqueueBatch(packets: [Data([9])], target: target, metrics: { metrics = $0 }, result: { _ in })
        scheduler.runOldestIncludingCancelled()
        try assert(submitted == 65 && metrics["nativeAckToNextFileMs"] == nil &&
            metrics["nativeNotifyToCreditMs"] == nil && metrics["nativeQueueSoftThrottleWaitMs"] as? Int == 0,
            "new attempt cannot inherit timing or submit the cancelled FILE")
        try assert(!queue.recordOtaWindowAckForNextFile(windowId: "cancelled-file", receiptId: receipt["receiptId"] as! String,
            owner: owner, nextFile: file), "cancelled receipt remains invalid")
    }

    /// Native submission and real ACK observations cannot reset the budget.
    /// The retained receipt measures FILE admission and actual submission separately.
    private static func verifiedAckMeasuresWithoutBypassingBackpressure() throws {
        let peripheral = FakeOtaPeripheral()
        let clock = FakeOtaClock()
        let scheduler = FakeOtaScheduler()
        let queue = OtaWriteQueue(peripheral: peripheral, clock: clock, scheduler: scheduler)
        let owner = creditOwner()
        var submitted = 0
        var metrics: [String: Any] = [:]
        let target = OtaWriteTarget(characteristicUUID: "ota") { _, _ in submitted += 1; return true }
        try assert(queue.registerOtaWindow(windowId: "w1", expectedAck: ack, owner: owner), "register current window")
        try assert(queue.observeOtaAck(data: ack, owner: owner) == nil, "ACK before submission is not a receipt")
        queue.enqueueBatch(packets: (0..<64).map { Data([$0]) }, target: target, result: { value in
            _ = queue.markOtaWindowSubmitted(windowId: "w1", owner: owner, success: value == nil)
        })
        try assert(scheduler.activeIntervals == [0.5], "native completion alone keeps soft64")
        let receipt = queue.observeOtaAck(data: ack, owner: owner)!
        try assert(queue.observeOtaAck(data: ack, owner: owner) == nil, "duplicate ACK has no new receipt")
        clock.monotonicNow += 0.05
        peripheral.canSendWriteWithoutResponse = false
        var corruptFile = file
        corruptFile[10] ^= 1
        try assert(!queue.recordOtaWindowAckForNextFile(windowId: "w1", receiptId: receipt["receiptId"] as! String,
            owner: owner, nextFile: corruptFile), "invalidFILECRC cannotconsume realreceipt")
        try assert(queue.recordOtaWindowAckForNextFile(windowId: "w1", receiptId: receipt["receiptId"] as! String,
            owner: owner, nextFile: file), "actual verified receipt records timing without resetting budget")
        try assert(!queue.recordOtaWindowAckForNextFile(windowId: "w1", receiptId: receipt["receiptId"] as! String,
            owner: owner, nextFile: file), "receipt is single use")
        queue.enqueue(data: file, target: target, result: { _ in })
        try assert(submitted == 64, "ACK observation never bypasses canSend=false")
        try assert(scheduler.activeIntervals == [0.1], "hard wait retains100ms poll")
        scheduler.runOldestIncludingCancelled()
        try assert(submitted == 64 && scheduler.activeIntervals == [0.1], "old soft timer cannot clear hard retry")
        peripheral.canSendWriteWithoutResponse = true
        clock.monotonicNow += 0.1
        scheduler.runNext()
        try assert(submitted == 65, "real readiness resumes FILE")
        queue.enqueueBatch(packets: [Data([9])], target: target, metrics: { metrics = $0 }, result: { _ in })
        try assert(metrics["nativeNotifyToCreditMs"] as? Int == 49 || metrics["nativeNotifyToCreditMs"] as? Int == 50,
            "credit admission records50ms beforehardbackpressure")
        try assert(metrics["nativeAckToNextFileMs"] as? Int == 149 || metrics["nativeAckToNextFileMs"] as? Int == 150,
            "ACK to actualFILE submission includes100ms hardwait and is measured once")
    }

    private static func staleReceiptCannotMeasureNewWindow() throws {
        let peripheral = FakeOtaPeripheral()
        let queue = OtaWriteQueue(peripheral: peripheral)
        let owner = creditOwner()
        try assert(queue.registerOtaWindow(windowId: "old", expectedAck: ack, owner: owner), "register old")
        _ = queue.markOtaWindowSubmitted(windowId: "old", owner: owner, success: true)
        let receipt = queue.observeOtaAck(data: ack, owner: owner)!
        try assert(queue.registerOtaWindow(windowId: "wrappedSS", expectedAck: ack, owner: owner), "same8bitSS new localwindow")
        try assert(!queue.recordOtaWindowAckForNextFile(windowId: "old", receiptId: receipt["receiptId"] as! String,
            owner: owner, nextFile: file), "SSwrap cannot reuse previousreceipt")
        _ = queue.markOtaWindowSubmitted(windowId: "wrappedSS", owner: owner, success: true)
        let current = queue.observeOtaAck(data: ack, owner: owner)!
        try assert(!queue.recordOtaWindowAckForNextFile(windowId: "wrappedSS", receiptId: current["receiptId"] as! String,
            owner: creditOwner(attempt: 2), nextFile: file), "wrong physical owner cannot associate a measurement")
        queue.cancelAll(reason: "new attempt")
        try assert(!queue.recordOtaWindowAckForNextFile(windowId: "wrappedSS", receiptId: current["receiptId"] as! String,
            owner: owner, nextFile: file), "cancelemptyqueue clearsreceipt")
    }

    private static func softToHardPollUsesNewDeadline() throws {
        let peripheral = FakeOtaPeripheral()
        let clock = FakeOtaClock()
        let scheduler = FakeOtaScheduler(clock: clock)
        let queue = OtaWriteQueue(peripheral: peripheral, clock: clock, scheduler: scheduler)
        var submitted = 0
        let target = OtaWriteTarget(characteristicUUID: "ota") { _, _ in submitted += 1; return true }
        queue.enqueueBatch(packets: (0..<64).map { Data([$0]) }, target: target, result: { _ in })
        scheduler.advance(by: 0.01)
        peripheral.canSendWriteWithoutResponse = false
        queue.enqueue(data: file, target: target, result: { _ in })
        peripheral.canSendWriteWithoutResponse = true
        scheduler.advance(by: 0.099)
        try assert(submitted == 64, "hard poll must not fire before its100ms deadline")
        scheduler.advance(by: 0.002)
        try assert(submitted == 65, "new100ms poll resumes before old500ms deadline withoutready")
        scheduler.advance(by: 0.5)
        try assert(submitted == 65, "oldsofttimer cannot submit twice")
    }

    private static func failedObservedFileDoesNotLeakMeasurements() throws {
        let peripheral = FakeOtaPeripheral()
        let queue = OtaWriteQueue(peripheral: peripheral)
        let owner = creditOwner()
        try assert(queue.registerOtaWindow(windowId: "failed-file", expectedAck: ack, owner: owner), "register")
        _ = queue.markOtaWindowSubmitted(windowId: "failed-file", owner: owner, success: true)
        let receipt = queue.observeOtaAck(data: ack, owner: owner)!
        try assert(queue.recordOtaWindowAckForNextFile(windowId: "failed-file", receiptId: receipt["receiptId"] as! String,
            owner: owner, nextFile: file), "record timing anchor")
        queue.enqueue(data: file, target: OtaWriteTarget(characteristicUUID: "ota") { _, _ in false }, result: { _ in })
        var metrics: [String: Any] = [:]
        queue.enqueueBatch(packets: [Data([9])], target: OtaWriteTarget(characteristicUUID: "ota") { _, _ in true },
            metrics: { metrics = $0 }, result: { _ in })
        try assert(metrics["nativeAckToNextFileMs"] == nil && metrics["nativeNotifyToCreditMs"] == nil,
            "failedFILE invalidates oldtiming before unrelatedRAW")
    }

    private static func hardBackpressureStallTimerDoesNotRestartOnPoll() throws {
        let peripheral = FakeOtaPeripheral()
        peripheral.canSendWriteWithoutResponse = false
        let clock = FakeOtaClock()
        let scheduler = FakeOtaScheduler()
        var results: [Any?] = []
        let queue = OtaWriteQueue(peripheral: peripheral, clock: clock, scheduler: scheduler)

        queue.enqueue(
            data: Data([0x7f]),
            target: OtaWriteTarget(characteristicUUID: "ota-write") { _, _ in true },
            expectedSessionGeneration: 37,
            expectedAttemptGeneration: 9,
            result: { results.append($0) }
        )
        clock.now = clock.now.addingTimeInterval(14.9)
        clock.monotonicNow += 14.9
        scheduler.runNext()
        try assert(results.isEmpty, "14.9s should not stall yet")
        clock.now = clock.now.addingTimeInterval(0.2)
        clock.monotonicNow += 0.2
        scheduler.runNext()

        try assert(results.count == 1, "hard backpressure poll must preserve the original 15s stall start")
    }

    private static func stalledOtaStillLogsDiagnostic() throws {
        let peripheral = FakeOtaPeripheral()
        peripheral.canSendWriteWithoutResponse = false
        let clock = FakeOtaClock()
        let scheduler = FakeOtaScheduler()
        var logs: [String] = []
        var results: [Any?] = []
        let queue = OtaWriteQueue(
            peripheral: peripheral,
            logger: { logs.append($0) },
            clock: clock,
            scheduler: scheduler
        )

        queue.enqueue(
            data: Data([0x7f]),
            target: OtaWriteTarget(characteristicUUID: "ota-write") { _, _ in true },
            expectedSessionGeneration: 37,
            expectedAttemptGeneration: 9,
            result: { results.append($0) }
        )
        clock.now = clock.now.addingTimeInterval(15)
        clock.monotonicNow += 15
        scheduler.runNext()

        try assert(results.count == 1, "expected stalled write to settle once")
        try assert(logs.contains { $0.contains("[ezw_ble][ota] stalled") }, "expected stalled OTA diagnostic log: \(logs)")
    }




    private static func fileBatchKeepsExistingRoutineLogs() throws {
        let peripheral = FakeOtaPeripheral()
        let clock = FakeOtaClock()
        let scheduler = FakeOtaScheduler()
        var logs: [String] = []
        let queue = OtaWriteQueue(
            peripheral: peripheral,
            logger: { logs.append($0) },
            clock: clock,
            scheduler: scheduler,
            channel: OtaWriteChannel.file
        )

        queue.enqueueBatch(
            packets: [Data([0x01]), Data([0x02])],
            target: OtaWriteTarget(characteristicUUID: "file-write") { _, _ in true },
            result: { _ in }
        )

        try assert(logs.contains { $0.contains("[ezw_ble][file] batch enqueued") }, "expected file batch enqueue log")
        try assert(logs.contains { $0.contains("[ezw_ble][file] batch completed") }, "expected file batch completion log")
        try assert(!logs.contains { $0.contains("[ezw_ble][file] submitted") }, "file batch should not gain per-packet submitted logs")
    }

    private static func assert(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else {
            throw NSError(domain: "OtaWriteQueueLogTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }
}
