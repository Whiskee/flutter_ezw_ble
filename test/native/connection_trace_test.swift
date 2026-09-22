import Foundation

/// Runs against the production buffer without CoreBluetooth or a real device.
@main
struct ConnectionTraceTests {
    static func main() throws {
        var mono = 10.0
        var wall = 1_000_000
        let trace = BleNativeConnectionTraceBuffer(monotonicClock: { mono }, wallClock: { wall })
        trace.record(stage: "attempt", result: "started")
        mono += 1.015
        wall += 1015
        trace.record(stage: "physical_connection", result: "connected", physicalConnectionEvent: "connected")
        let before = trace.snapshot()
        // Receiving both stages in one snapshot must retain their source interval.
        assert(abs(before.steps[1].occurredAtMs! - before.steps[0].occurredAtMs! - 1015) <= 1)
        mono += 0.002
        wall += 2
        let replay = trace.snapshot()
        assert(replay.steps[1].occurredAtMs == before.steps[1].occurredAtMs)
        assert(replay.steps[1].timingStatus == "valid")
        wall += 5000
        trace.record(stage: "auth", result: "failed", causeDomain: "native", causeCode: 7)
        assert(trace.snapshot().steps.last!.timingStatus == "clock_changed")
        assert(trace.snapshot().rssiStatus == "not_requested")
        trace.markRssiRequested()
        assert(trace.snapshot().rssiStatus == "not_observable")
        trace.markRssiFailed()
        assert(trace.snapshot().rssiStatus == "read_failed")
        trace.updateRssi(-72)
        assert(trace.snapshot().rssiStatus == "available")
        trace.record(stage: "physical_connection", result: "disconnected", physicalConnectionEvent: "disconnected")
        trace.record(stage: "gatt_ready", result: "success")
        for index in 0..<100 {
            trace.record(stage: "detail_\(index)", result: "started")
        }
        let bounded = trace.snapshot()
        assert(bounded.steps.count <= 32)
        assert(bounded.steps.first!.stage == "attempt")
        assert(bounded.steps.contains { $0.stage == "gatt_ready" })
        assert(bounded.steps.contains { $0.physicalConnectionEvent == "connected" })
        assert(bounded.steps.contains { $0.physicalConnectionEvent == "disconnected" })
        assert(bounded.steps.contains { $0.stage == "auth" && $0.causeCode == 7 })
        assert(bounded.steps.contains { $0.result == "gap" && ($0.droppedCount ?? 0) > 0 })
        assert(zip(bounded.steps, bounded.steps.dropFirst()).allSatisfy { $0.stepSeq < $1.stepSeq })
        print("Native trace timing, replay, RSSI and bounded retention tests passed")
    }
}
