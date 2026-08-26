import CoreBluetooth
import Foundation

/// Process-local native trace for one real CoreBluetooth physical attempt.
struct BleNativeConnectionTrace: Codable {
    var attemptId: String
    var steps: [BleNativeConnectionTraceStep]
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
    private let startedAt = ProcessInfo.processInfo.systemUptime
    private var steps: [BleNativeConnectionTraceStep] = []
    private var seen: Set<String> = []
    private var nextStepSeq = 1
    private var droppedCount = 0
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
        actionResult: String? = nil
    ) {
        let duplicateKey = "\(stage)|\(result)|\(serviceType ?? "")|\(bondState ?? "")|\(linkTrigger ?? "")|\(rssiBucket ?? "")|\(phy ?? "")|\(priorityAction ?? "")|\(actionResult ?? "")"
        guard !seen.contains(duplicateKey) else { return }
        seen.insert(duplicateKey)
        let step = BleNativeConnectionTraceStep(
            stepSeq: nextStepSeq,
            stage: stage,
            result: result,
            elapsedMs: max(0, Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1000)),
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

    func updateRssi(_ rssi: Int) {
        lastRssiDbm = rssi
        lastRssiAt = ProcessInfo.processInfo.systemUptime
    }

    func snapshot() -> BleNativeConnectionTrace {
        let age = lastRssiAt.map { max(0, Int((ProcessInfo.processInfo.systemUptime - $0) * 1000)) }
        return BleNativeConnectionTrace(
            attemptId: attemptId,
            // Preserve producer sequences across bounded-buffer replacement so
            // Dart does not mistake a new terminal stage for an old slot.
            steps: steps,
            capturedElapsedMs: max(0, Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1000)),
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
        droppedCount += 1
        let gap = BleNativeConnectionTraceStep(
            // The incoming non-terminal stage is omitted by the bounded buffer,
            // so its sequence becomes the observable gap sequence.
            stepSeq: step.stepSeq,
            stage: "trace",
            result: "gap",
            elapsedMs: step.elapsedMs,
            serviceType: nil,
            causeDomain: nil,
            causeCode: nil,
            droppedCount: droppedCount,
            bondState: nil,
            writeLimitBytes: nil,
            linkTrigger: nil,
            rssiBucket: nil,
            phy: nil,
            priorityAction: nil,
            actionResult: nil
        )
        if isTerminal(step) {
            var terminal = step
            terminal.stepSeq = nextStepSeq
            nextStepSeq += 1
            steps[Self.maxSteps - 2] = gap
            // Keep the terminal after the gap in both array and producer order.
            steps[Self.maxSteps - 1] = terminal
        } else {
            steps[Self.maxSteps - 1] = gap
        }
    }

    private func isTerminal(_ step: BleNativeConnectionTraceStep) -> Bool {
        step.stage == "disconnect" ||
            ["success", "failed", "timeout", "cancelled", "abnormal", "expected"].contains(step.result)
    }
}
