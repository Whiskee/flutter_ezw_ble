import Foundation
import Flutter

// Only platform logging and CoreBluetooth are faked; token, cancellation and
// timer decisions below execute the production OtaWriteQueue unchanged.
final class FileOwnerLogSink { func emit(_ message: String) {} }
enum BleEC { static let logger = FileOwnerLogSink() }

private final class FilePeripheral: OtaWritePeripheral {
    let otaEndpointId: String
    var canSendWriteWithoutResponse = true
    init(_ endpoint: String = "file-left") { otaEndpointId = endpoint }
}
private final class FileClock: OtaWriteClock {
    var now = Date(timeIntervalSince1970: 1_000)
    var monotonicNow: TimeInterval = 1_000
}
private final class FileTask: OtaWriteCancellable {
    let block: () -> Void
    var cancelled = false
    init(_ block: @escaping () -> Void) { self.block = block }
    func cancel() { cancelled = true }
}
private final class FileScheduler: OtaWriteScheduler {
    var tasks: [FileTask] = []
    func schedule(after interval: TimeInterval, _ block: @escaping () -> Void) -> OtaWriteCancellable {
        let task = FileTask(block)
        tasks.append(task)
        return task
    }
    func fireOldestEvenIfCancelled() {
        precondition(!tasks.isEmpty)
        tasks.removeFirst().block()
    }
    func fireNext() {
        while !tasks.isEmpty {
            let task = tasks.removeFirst()
            if !task.cancelled { task.block(); return }
        }
        preconditionFailure("Missing live file timer")
    }
}

@main
private struct FileBatchOwnerTests {
    static func main() throws {
        try cancelledReservationCannotBeResurrected()
        try partialCancellationPreservesOtherBatches()
        try tokensAreOneUseAndEndpointScoped()
        try completionRetiresBeforeReentrantBegin()
        try cancelledCallbackCannotDriveReplacementWait()
        try cancellationKeepsSoft64StopAndInvalidatesOldTimer()
        try teardownRevokesEmptyAndSubmittedReservations()
        try submissionReentrancyCannotResumeCancelledTail()
        try replacementAndLegacyEnqueueCannotBypassTerminal64()
        try cancellationCannotRefundSubmittedBudget()
        try failedSubmitRetiresBeforeReentrantBegin()
        try cancellationCallbackReservationKeepsOtherWorkLive()
        print("file batch owner: 12 native cancellation and timer regressions passed")
    }

    private static func cancelledReservationCannotBeResurrected() throws {
        let peripheral = FilePeripheral()
        let queue = OtaWriteQueue(peripheral: peripheral, channel: OtaWriteChannel.file)
        let token = try unwrap(queue.beginFilePacketBatch())
        try expect(queue.beginFilePacketBatch() == nil, "only one live reservation")
        try expect(queue.cancelFilePacketBatch(fileBatchToken: token), "cancel reserved token")
        try expect(!queue.cancelFilePacketBatch(fileBatchToken: token), "duplicate cancel is no-op")
        var writes = 0
        var results: [Any?] = []
        queue.enqueueBatch(packets: [Data([1])],
            target: OtaWriteTarget(characteristicUUID: "file") { _, _ in writes += 1; return true },
            fileBatchToken: token, result: { results.append($0) })
        try expect(writes == 0 && errorCode(results) == "file_write_unavailable", "retired token must fail closed")
        let replacement = try unwrap(queue.beginFilePacketBatch())
        try expect(replacement != token, "replacement token must not reuse retired token")
        try expect(!queue.cancelFilePacketBatch(fileBatchToken: token), "old token cannot cancel replacement")
        try expect(queue.cancelFilePacketBatch(fileBatchToken: replacement), "replacement remains live")
    }

    private static func partialCancellationPreservesOtherBatches() throws {
        let peripheral = FilePeripheral()
        let scheduler = FileScheduler()
        let queue = OtaWriteQueue(peripheral: peripheral, scheduler: scheduler, channel: OtaWriteChannel.file)
        let token = try unwrap(queue.beginFilePacketBatch())
        var writes: [UInt8] = []
        var ownedResults: [Any?] = []
        var otherResults: [Any?] = []
        let target = OtaWriteTarget(characteristicUUID: "file") { _, data in
            writes.append(data[0])
            peripheral.canSendWriteWithoutResponse = false
            return true
        }
        queue.enqueueBatch(packets: [Data([1]), Data([2]), Data([3])], target: target,
            fileBatchToken: token, result: { ownedResults.append($0) })
        queue.enqueueBatch(packets: [Data([9])], target: target, result: { otherResults.append($0) })
        try expect(writes == [1] && queue.queueDepth == 3, "partial batch must wait with unrelated work")
        try expect(queue.cancelFilePacketBatch(fileBatchToken: token), "exact active batch must cancel")
        try expect(errorCode(ownedResults) == "file_write_cancelled" && queue.queueDepth == 1,
            "only matching unsent tail must be retired once")
        peripheral.canSendWriteWithoutResponse = true
        queue.onPeripheralReadyToSendWriteWithoutResponse()
        try expect(writes == [1, 9] && otherResults.count == 1 && otherResults[0] == nil,
            "unrelated batch must survive and submit normally")
        scheduler.fireOldestEvenIfCancelled()
        try expect(writes == [1, 9] && ownedResults.count == 1, "cancelled timer must not replay retired packets")
    }

    private static func tokensAreOneUseAndEndpointScoped() throws {
        let peripheral = FilePeripheral()
        peripheral.canSendWriteWithoutResponse = false
        let queue = OtaWriteQueue(peripheral: peripheral, scheduler: FileScheduler(), channel: OtaWriteChannel.file)
        let otherPeripheral = FilePeripheral("file-right")
        let other = OtaWriteQueue(peripheral: otherPeripheral, channel: OtaWriteChannel.file)
        let token = try unwrap(queue.beginFilePacketBatch())
        var writes = 0
        let target = OtaWriteTarget(characteristicUUID: "file") { _, _ in writes += 1; return true }
        var original: [Any?] = []
        var rejected: [Any?] = []
        queue.enqueueBatch(packets: [Data([1]), Data([2])], target: target, fileBatchToken: token,
            result: { original.append($0) })
        queue.enqueueBatch(packets: [Data([3])], target: target, fileBatchToken: token,
            result: { rejected.append($0) })
        other.enqueueBatch(packets: [Data([4])], target: target, fileBatchToken: token,
            result: { rejected.append($0) })
        try expect(rejected.count == 2 && rejected.allSatisfy { ($0 as? FlutterError)?.code == "file_write_unavailable" },
            "duplicate and cross-endpoint admission must reject")
        try expect(original.isEmpty && queue.queueDepth == 2 && writes == 0, "rejection must preserve original batch")
        try expect(queue.cancelFilePacketBatch(fileBatchToken: token) && original.count == 1,
            "original owner stays cancellable after duplicate rejection")
        let ota = OtaWriteQueue(peripheral: otherPeripheral)
        try expect(ota.beginFilePacketBatch() == nil && !ota.cancelFilePacketBatch(fileBatchToken: token),
            "file APIs cannot mutate OTA queue")
    }

    private static func completionRetiresBeforeReentrantBegin() throws {
        let peripheral = FilePeripheral()
        let queue = OtaWriteQueue(peripheral: peripheral, channel: OtaWriteChannel.file)
        let first = try unwrap(queue.beginFilePacketBatch())
        var second: String?
        var writes: [UInt8] = []
        let target = OtaWriteTarget(characteristicUUID: "file") { _, data in writes.append(data[0]); return true }
        var completions = 0
        queue.enqueueBatch(packets: [Data([1])], target: target, fileBatchToken: first) { result in
            precondition(result == nil)
            completions += 1
            second = queue.beginFilePacketBatch()
            if let second {
                queue.enqueueBatch(packets: [Data([2])], target: target, fileBatchToken: second) { _ in completions += 1 }
            }
        }
        try expect(second != nil && second != first && writes == [1, 2] && completions == 2,
            "completion must retire old owner before callback installs replacement")
        try expect(!queue.cancelFilePacketBatch(fileBatchToken: first), "late old cancel cannot affect completed successor")
    }

    private static func cancelledCallbackCannotDriveReplacementWait() throws {
        let peripheral = FilePeripheral()
        peripheral.canSendWriteWithoutResponse = false
        let clock = FileClock()
        let scheduler = FileScheduler()
        let queue = OtaWriteQueue(peripheral: peripheral, clock: clock, scheduler: scheduler, channel: OtaWriteChannel.file)
        let token = try unwrap(queue.beginFilePacketBatch())
        var replacement: String?
        var replacementResults: [Any?] = []
        var writes = 0
        let target = OtaWriteTarget(characteristicUUID: "file") { _, _ in writes += 1; return true }
        queue.enqueueBatch(packets: [Data([1]), Data([2])], target: target, fileBatchToken: token) { _ in
            replacement = queue.beginFilePacketBatch()
            if let replacement {
                queue.enqueueBatch(packets: [Data([9])], target: target, fileBatchToken: replacement,
                    result: { replacementResults.append($0) })
            }
        }
        try expect(queue.cancelFilePacketBatch(fileBatchToken: token), "cancel original waiting owner")
        try expect(replacement != nil && replacementResults.isEmpty && queue.queueDepth == 1, "callback may install new waiting owner")
        peripheral.canSendWriteWithoutResponse = true
        scheduler.fireOldestEvenIfCancelled()
        try expect(writes == 0 && replacementResults.isEmpty, "old timer cannot pump replacement's new wait")
        scheduler.fireNext()
        try expect(writes == 1 && replacementResults.count == 1, "replacement resumes only via own timer")
    }

    private static func cancellationKeepsSoft64StopAndInvalidatesOldTimer() throws {
        let peripheral = FilePeripheral()
        let scheduler = FileScheduler()
        let queue = OtaWriteQueue(peripheral: peripheral, scheduler: scheduler, channel: OtaWriteChannel.file)
        let token = try unwrap(queue.beginFilePacketBatch())
        var writes = 0
        let target = OtaWriteTarget(characteristicUUID: "file") { _, _ in writes += 1; return true }
        queue.enqueueBatch(packets: (0..<65).map { Data([UInt8($0)]) }, target: target,
            fileBatchToken: token, result: { _ in })
        try expect(writes == 64 && queue.queueDepth == 1, "owned file must stop at unchanged 64 packet budget")
        try expect(queue.cancelFilePacketBatch(fileBatchToken: token), "cancel soft-throttled owner")
        let replacement = try unwrap(queue.beginFilePacketBatch())
        queue.enqueueBatch(packets: [Data([99])], target: target, fileBatchToken: replacement, result: { _ in })
        try expect(writes == 64, "cancellation and replacement admission cannot bypass soft stop")
        scheduler.fireOldestEvenIfCancelled()
        try expect(writes == 64, "old soft timer cannot resume replacement")
        scheduler.fireNext()
        try expect(writes == 65, "owned replacement timer may resume after original soft boundary")
    }

    private static func teardownRevokesEmptyAndSubmittedReservations() throws {
        let peripheral = FilePeripheral()
        let queue = OtaWriteQueue(peripheral: peripheral, channel: OtaWriteChannel.file)
        let token = try unwrap(queue.beginFilePacketBatch())
        queue.cancelAll(reason: "teardown")
        try expect(!queue.cancelFilePacketBatch(fileBatchToken: token), "teardown revokes unsubmitted reservation")
        peripheral.canSendWriteWithoutResponse = false
        let replacement = try unwrap(queue.beginFilePacketBatch())
        var results: [Any?] = []
        queue.enqueueBatch(packets: [Data([1])], target: OtaWriteTarget(characteristicUUID: "file") { _, _ in true },
            fileBatchToken: replacement, result: { results.append($0) })
        queue.cancelAll(reason: "teardown")
        try expect(errorCode(results) == "file_write_cancelled" && !queue.cancelFilePacketBatch(fileBatchToken: replacement),
            "teardown retires active batch once")
        let recreated = OtaWriteQueue(peripheral: peripheral, channel: OtaWriteChannel.file)
        try expect(recreated.beginFilePacketBatch() != replacement, "queue recreation cannot reuse native token")
    }

    private static func submissionReentrancyCannotResumeCancelledTail() throws {
        let peripheral = FilePeripheral()
        let queue = OtaWriteQueue(peripheral: peripheral, channel: OtaWriteChannel.file)
        let token = try unwrap(queue.beginFilePacketBatch())
        var writes: [UInt8] = []
        var results: [Any?] = []
        let target = OtaWriteTarget(characteristicUUID: "file") { _, data in
            writes.append(data[0])
            _ = queue.cancelFilePacketBatch(fileBatchToken: token)
            return true // The already submitted packet cannot be retracted.
        }
        queue.enqueueBatch(packets: [Data([1]), Data([2])], target: target, fileBatchToken: token,
            result: { results.append($0) })
        try expect(writes == [1] && errorCode(results) == "file_write_cancelled" && results.count == 1,
            "cancel during platform submission may not replay tail or claim success")
    }

    private static func replacementAndLegacyEnqueueCannotBypassTerminal64() throws {
        let peripheral = FilePeripheral()
        let scheduler = FileScheduler()
        let queue = OtaWriteQueue(peripheral: peripheral, scheduler: scheduler, channel: OtaWriteChannel.file)
        let token = try unwrap(queue.beginFilePacketBatch())
        var writes = 0
        let target = OtaWriteTarget(characteristicUUID: "file") { _, _ in writes += 1; return true }
        queue.enqueueBatch(packets: (0..<64).map { Data([UInt8($0)]) }, target: target, fileBatchToken: token) { _ in
            let replacement = queue.beginFilePacketBatch()!
            queue.enqueueBatch(packets: [Data([90])], target: target, fileBatchToken: replacement, result: { _ in })
            queue.enqueueBatch(packets: [Data([91])], target: target, result: { _ in })
        }
        try expect(writes == 64 && queue.queueDepth == 2, "completion/reentrant legacy admission cannot bypass terminal soft64")
        scheduler.fireNext()
        try expect(writes == 66 && queue.queueDepth == 0, "unchanged soft retry may resume both owners")
    }

    private static func cancellationCannotRefundSubmittedBudget() throws {
        let peripheral = FilePeripheral()
        let scheduler = FileScheduler()
        let queue = OtaWriteQueue(peripheral: peripheral, scheduler: scheduler, channel: OtaWriteChannel.file)
        let token = try unwrap(queue.beginFilePacketBatch())
        var writes = 0
        let target = OtaWriteTarget(characteristicUUID: "file") { _, _ in
            writes += 1
            if writes == 63 { peripheral.canSendWriteWithoutResponse = false }
            return true
        }
        queue.enqueueBatch(packets: (0..<64).map { Data([UInt8($0)]) }, target: target, fileBatchToken: token, result: { _ in })
        try expect(queue.cancelFilePacketBatch(fileBatchToken: token), "cancel at packet 63")
        peripheral.canSendWriteWithoutResponse = true
        let replacement = try unwrap(queue.beginFilePacketBatch())
        queue.enqueueBatch(packets: [Data([90]), Data([91])], target: target, fileBatchToken: replacement, result: { _ in })
        try expect(writes == 64 && queue.queueDepth == 1, "cancel must not refund already submitted 63 packets")
        scheduler.fireOldestEvenIfCancelled()
        try expect(writes == 64, "old hard timer cannot drive replacement soft wait")
        scheduler.fireNext()
        try expect(writes == 65, "replacement tail resumes after its own soft boundary")
    }

    private static func failedSubmitRetiresBeforeReentrantBegin() throws {
        let peripheral = FilePeripheral()
        let queue = OtaWriteQueue(peripheral: peripheral, channel: OtaWriteChannel.file)
        let token = try unwrap(queue.beginFilePacketBatch())
        var replacement: String?
        var results: [Any?] = []
        queue.enqueueBatch(packets: [Data([1]), Data([2])],
            target: OtaWriteTarget(characteristicUUID: "file") { _, _ in false }, fileBatchToken: token) { value in
                results.append(value)
                replacement = queue.beginFilePacketBatch()
            }
        try expect(errorCode(results) == "file_write_unavailable" && replacement != nil && queue.queueDepth == 0,
            "submit failure retires old owner before callback; its tails never survive")
        try expect(!queue.cancelFilePacketBatch(fileBatchToken: token), "late failed token cannot revoke callback replacement")
    }

    private static func cancellationCallbackReservationKeepsOtherWorkLive() throws {
        let peripheral = FilePeripheral()
        peripheral.canSendWriteWithoutResponse = false
        let queue = OtaWriteQueue(peripheral: peripheral, scheduler: FileScheduler(), channel: OtaWriteChannel.file)
        let token = try unwrap(queue.beginFilePacketBatch())
        var writes: [UInt8] = []
        var replacement: String?
        let target = OtaWriteTarget(characteristicUUID: "file") { _, data in writes.append(data[0]); return true }
        queue.enqueueBatch(packets: [Data([1])], target: target, fileBatchToken: token) { _ in
            replacement = queue.beginFilePacketBatch()
        }
        queue.enqueueBatch(packets: [Data([9])], target: target, result: { _ in })
        peripheral.canSendWriteWithoutResponse = true
        try expect(queue.cancelFilePacketBatch(fileBatchToken: token), "cancel waiting head")
        try expect(replacement != nil && writes == [9] && queue.queueDepth == 0,
            "callback may reserve without submitting; unrelated retained work must remain live")
    }

    private static func errorCode(_ results: [Any?]) -> String? {
        results.count == 1 ? (results[0] as? FlutterError)?.code : nil
    }
    private static func unwrap(_ token: String?) throws -> String {
        guard let token else { throw NSError(domain: "FileBatchOwnerTests", code: 1) }
        return token
    }
    private static func expect(_ accepted: Bool, _ message: String) throws {
        if !accepted { throw NSError(domain: "FileBatchOwnerTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
}
