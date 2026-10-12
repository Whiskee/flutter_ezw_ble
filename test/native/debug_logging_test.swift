import Foundation

// Flutter is the only mocked system boundary; manager logger methods, scan
// dedupe and OTA queue are compiled directly from their production sources.
typealias FlutterResult = (Any?) -> Void
final class FlutterError: Error {
    let code: String
    let message: String?
    let details: Any?
    init(code: String, message: String?, details: Any?) {
        self.code = code
        self.message = message
        self.details = details
    }
}

enum BleEC {
    case logger
    func emit(_ value: Any) { NativeLogEvidence.events.append(value as! String) }
}

enum NativeLogEvidence {
    static var events: [String] = []
    static var formats = 0
    static var keyFormats = 0
    static func message() -> String {
        formats += 1
        return "notify uuid=endpoint bytes=205"
    }
    static func key() -> String {
        keyFormats += 1
        return "scan-target"
    }
}

final class TestPeripheral: OtaWritePeripheral {
    var canSendWriteWithoutResponse = true
    var diagnosticReads = 0
    var otaEndpointId: String {
        diagnosticReads += 1
        return "endpoint"
    }
}
final class TestClock: OtaWriteClock { var now = Date(timeIntervalSince1970: 0) }
final class TestCancellation: OtaWriteCancellable { func cancel() {} }
struct TestScheduler: OtaWriteScheduler {
    func schedule(after interval: TimeInterval, _ block: @escaping () -> Void) -> OtaWriteCancellable {
        TestCancellation()
    }
}

@main
struct NativeDebugLoggingTests {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fputs("FAILED: \(message)\n", stderr)
            exit(1)
        }
    }

    static func main() {
        check(!BleDebugLogPolicy.isEnabled, "Debug must default to false before any manager exists")
        let manager = BleManager()
        for _ in 0..<50_000 { manager.loggerD(msg: NativeLogEvidence.message()) }
        print("disabled notify samples=50000 formatted=\(NativeLogEvidence.formats) emitted=\(NativeLogEvidence.events.count)")
        fflush(stdout)
        check(NativeLogEvidence.formats == 0, "disabled Debug eagerly formatted packets")
        check(NativeLogEvidence.events.isEmpty, "disabled Debug emitted packets")
        manager.scanLog(key: NativeLogEvidence.key(), message: NativeLogEvidence.message())
        check(NativeLogEvidence.keyFormats == 0, "disabled scan consumed dedupe key")
        BleDebugLogPolicy.emit("[d]-startup \(NativeLogEvidence.message())")
        check(NativeLogEvidence.formats == 0, "disabled startup eagerly formatted")
        manager.loggerE(msg: "service discovery failed")
        check(NativeLogEvidence.events == ["[e]-BleManage::service discovery failed"], "error log lost with Debug off")

        BleDebugLogPolicy.setEnabled(true)
        manager.loggerD(msg: NativeLogEvidence.message())
        manager.scanLog(key: NativeLogEvidence.key(), message: NativeLogEvidence.message())
        manager.scanLog(key: NativeLogEvidence.key(), message: NativeLogEvidence.message())
        BleDebugLogPolicy.emit("[d]-startup \(NativeLogEvidence.message())")
        check(NativeLogEvidence.formats == 3, "enabled logging must format once; duplicate scan must stay lazy")
        check(NativeLogEvidence.events.count == 4, "enabled format/prefix delivery changed")
        check(NativeLogEvidence.events[1] == "[d]-BleManage::notify uuid=endpoint bytes=205", "Debug prefix changed")
        BleDebugLogPolicy.setEnabled(false)
        manager.loggerD(msg: NativeLogEvidence.message())
        check(NativeLogEvidence.formats == 3, "disabling was not applied to the next packet")

        let peripheral = TestPeripheral()
        let clock = TestClock()
        var submissions = 0
        var successes = 0
        var debugMessages: [String] = []
        var errors: [String] = []
        var results: [FlutterError] = []
        let queue = OtaWriteQueue(
            peripheral: peripheral,
            logger: { debugMessages.append($0) },
            errorLogger: { errors.append($0) },
            clock: clock,
            scheduler: TestScheduler()
        )
        let target = OtaWriteTarget(characteristicUUID: "ota") { _, data in
            check(data == Data([1, 2, 3]), "queue payload changed")
            submissions += 1
            return true
        }
        for _ in 0..<256 {
            queue.enqueue(data: Data([1, 2, 3]), target: target) { value in
                check(value == nil, "successful write became an error")
                successes += 1
            }
        }
        check(submissions == 256 && successes == 256 && queue.queueDepth == 0, "Debug gate changed OTA submission/completion")
        check(peripheral.diagnosticReads == 0 && debugMessages.isEmpty, "OTA callback formatted packets before Manager gate")
        print("disabled OTA packets=256 submitted=\(submissions) completed=\(successes) diagnosticReads=\(peripheral.diagnosticReads)")
        BleDebugLogPolicy.setEnabled(true)
        queue.enqueue(data: Data([1, 2, 3]), target: target) { _ in successes += 1 }
        check(debugMessages.count == 2, "enabled OTA diagnostics missing")
        BleDebugLogPolicy.setEnabled(false)

        peripheral.canSendWriteWithoutResponse = false
        queue.enqueue(data: Data([1]), target: target, expectedSessionGeneration: 7, expectedAttemptGeneration: 9) { value in
            if let error = value as? FlutterError { results.append(error) }
        }
        clock.now = Date(timeIntervalSince1970: 15)
        queue.onPeripheralReadyToSendWriteWithoutResponse()
        check(results.count == 1 && results[0].code == "ota_write_stalled", "stall terminal result changed")
        let details = results[0].details as! [String: Any]
        check(details["session"] as? Int64 == 7 && details["attempt"] as? Int64 == 9, "stall exact identity changed")
        check(errors.count == 1 && errors[0].contains("stalled"), "stall error diagnosis lost with Debug off")
        queue.cancelAll(reason: "explicit teardown")

        var temporaryPeripheral: TestPeripheral? = TestPeripheral()
        let unavailableQueue = OtaWriteQueue(peripheral: temporaryPeripheral!, logger: { debugMessages.append($0) }, errorLogger: { errors.append($0) }, clock: clock, scheduler: TestScheduler())
        temporaryPeripheral = nil
        unavailableQueue.enqueue(data: Data([1]), target: target) { value in
            check((value as? FlutterError)?.code == "ota_write_unavailable", "released peripheral terminal result changed")
        }
        check(errors.count == 2 && errors[1].contains("endpoint=released"), "released peripheral error diagnosis lost")
        print("native debug logging: all behavior checks passed")
    }
}
