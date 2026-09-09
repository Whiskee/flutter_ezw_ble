import Foundation

/// Process-local native trace for one real CoreBluetooth physical attempt.
struct BleNativeConnectionTrace: Codable {
    var attemptId: String
    var steps: [BleNativeConnectionTraceStep]
    var rssiStatus: String?
    var capturedElapsedMs: Int?
    var lastRssiDbm: Int?
    var rssiAgeMs: Int?
    var phy: String?
    var requestedPriority: String?
}

/// One retained native stage. `stepSeq` stays monotonic for the physical attempt.
struct BleNativeConnectionTraceStep: Codable {
    var stepSeq: Int
    var stage: String
    var result: String
    var occurredAtMs: Int?
    var timingStatus: String?
    var physicalConnectionEvent: String?
    var elapsedMs: Int
    var serviceType: String?
    var causeDomain: String?
    var causeCode: Int?
    var droppedCount: Int?
    var bondState: String?
    var writeLimitBytes: Int?
    var linkTrigger: String?
    var rssiBucket: String?
    var phy: String?
    var priorityAction: String?
    var actionResult: String?
}

final class BleNativeConnectionTraceBuffer {
    static let maxSteps = 32

    let attemptId = UUID().uuidString
    // One source anchor survives snapshot/replay; wall-clock jumps remain explicit.
    private let monotonicClock: () -> TimeInterval
    private let wallClock: () -> Int
    private let startedAt: TimeInterval
    private let startedAtEpochMs: Int

    init(monotonicClock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         wallClock: @escaping () -> Int = { Int(Date().timeIntervalSince1970 * 1000) }) {
        self.monotonicClock = monotonicClock
        self.wallClock = wallClock
        startedAt = monotonicClock()
        startedAtEpochMs = wallClock()
    }
    private var steps: [BleNativeConnectionTraceStep] = []
    private var seen: Set<String> = []
    private var nextStepSeq = 1
    private var droppedCount = 0
    private var rssiStatus = "not_requested"
    private var lastRssiDbm: Int?
    private var lastRssiAt: TimeInterval?

    func record(
        stage: String,
        result: String,
        serviceType: String? = nil,
        causeDomain: String? = nil,
        causeCode: Int? = nil,
        bondState: String? = nil,
        writeLimitBytes: Int? = nil,
        linkTrigger: String? = nil,
        rssiBucket: String? = nil,
        phy: String? = nil,
        priorityAction: String? = nil,
        actionResult: String? = nil,
        physicalConnectionEvent: String? = nil
    ) {
        let duplicateKey = "\(stage)|\(result)|\(serviceType ?? "")|\(bondState ?? "")|\(linkTrigger ?? "")|\(rssiBucket ?? "")|\(phy ?? "")|\(priorityAction ?? "")|\(actionResult ?? "")"
        guard !seen.contains(duplicateKey) else { return }
        seen.insert(duplicateKey)
        let elapsed = max(0, Int((monotonicClock() - startedAt) * 1000))
        let occurred = startedAtEpochMs + elapsed
        let step = BleNativeConnectionTraceStep(
            stepSeq: nextStepSeq,
            stage: stage,
            result: result,
            occurredAtMs: occurred,
            timingStatus: abs(wallClock() - occurred) > 1000 ? "clock_changed" : "valid",
            physicalConnectionEvent: physicalConnectionEvent,
            elapsedMs: elapsed,
            serviceType: serviceType,
            causeDomain: causeDomain,
            causeCode: causeCode,
            droppedCount: nil,
            bondState: bondState,
            writeLimitBytes: writeLimitBytes,
            linkTrigger: linkTrigger,
            rssiBucket: rssiBucket,
            phy: phy,
            priorityAction: priorityAction,
            actionResult: actionResult
        )
        nextStepSeq += 1
        append(step)
    }

    /// A failed existing read is evidence, never a reason to schedule another read.
    func markRssiRequested() { if lastRssiDbm == nil { rssiStatus = "not_observable" } }

    func markRssiFailed() { rssiStatus = lastRssiDbm == nil ? "read_failed" : "available" }

    func updateRssi(_ rssi: Int) {
        rssiStatus = "available"
        lastRssiDbm = rssi
        lastRssiAt = monotonicClock()
    }

    func snapshot() -> BleNativeConnectionTrace {
        let age = lastRssiAt.map { max(0, Int((monotonicClock() - $0) * 1000)) }
        return BleNativeConnectionTrace(
            attemptId: attemptId,
            // Preserve producer sequences across bounded-buffer replacement so
            // Dart does not mistake a new terminal stage for an old slot.
            steps: steps,
            rssiStatus: rssiStatus,
            capturedElapsedMs: max(0, Int((monotonicClock() - startedAt) * 1000)),
            lastRssiDbm: lastRssiDbm,
            rssiAgeMs: age,
            phy: nil,
            requestedPriority: nil
        )
    }

    private func append(_ step: BleNativeConnectionTraceStep) {
        guard steps.count >= Self.maxSteps else {
            steps.append(step)
            return
        }
        // Preserve the start, physical callbacks and earliest failure. Intermediate
        // detail eviction is explicit and does not rewrite retained occurrence time.
        steps.removeAll { $0.result == "gap" }
        while steps.count > Self.maxSteps - 2 {
            let firstFailure = steps.firstIndex { ["failed", "timeout", "abnormal"].contains($0.result) }
            let candidate = steps.indices.first { index in
                index != 0 && index != firstFailure &&
                    steps[index].physicalConnectionEvent == nil &&
                    !["disconnect", "gatt_ready"].contains(steps[index].stage)
            } ?? 1
            steps.remove(at: candidate)
            droppedCount += 1
        }
        let gap = BleNativeConnectionTraceStep(
            stepSeq: step.stepSeq, stage: "trace", result: "gap",
            occurredAtMs: step.occurredAtMs, timingStatus: step.timingStatus,
            physicalConnectionEvent: nil, elapsedMs: step.elapsedMs,
            droppedCount: droppedCount
        )
        steps.append(gap)
        var terminal = step
        terminal.stepSeq = nextStepSeq
        nextStepSeq += 1
        steps.append(terminal)
    }

}
