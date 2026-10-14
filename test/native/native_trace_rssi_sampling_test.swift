import Foundation

/// Substitute only the unavailable CoreBluetooth boundary. The sampler, trace
/// buffer and Manager's request/owner/read/callback methods are production code.
enum CBPeripheralState { case connected, disconnected }
final class CBPeripheral {
    let identifier: UUID
    var state = CBPeripheralState.connected
    var reads = 0
    var onRead: (() -> Void)?
    init(identifier: UUID = UUID()) { self.identifier = identifier }
    func readRSSI() { reads += 1; onRead?() }
}
struct TestConnectedDevice {
    let peripheral: CBPeripheral
    var isConnected = true
    var isBleFlowCompleted = true
}

final class TestClock {
    final class Scheduled {
        var at: TimeInterval
        let interval: TimeInterval
        let repeats: Bool
        let action: () -> Void
        var cancelled = false
        init(at: TimeInterval, interval: TimeInterval, repeats: Bool, action: @escaping () -> Void) {
            self.at = at; self.interval = interval; self.repeats = repeats; self.action = action
        }
    }
    var now: TimeInterval = 0
    var history: [Scheduled] = []
    var activeCount: Int { history.filter { !$0.cancelled }.count }
    func schedule(_ interval: TimeInterval, _ repeats: Bool, _ action: @escaping () -> Void) -> () -> Void {
        let job = Scheduled(at: now + interval, interval: interval, repeats: repeats, action: action)
        history.append(job)
        return { job.cancelled = true }
    }
    func advance(_ seconds: TimeInterval) {
        let end = now + seconds
        while let job = history.filter({ !$0.cancelled && $0.at <= end }).min(by: { $0.at < $1.at }) {
            now = job.at
            if !job.repeats { job.cancelled = true }
            job.action()
            if job.repeats && !job.cancelled { job.at += job.interval }
        }
        now = end
    }
}

@main
struct NativeTraceRssiSamplingTests {
    static func fixture() -> (TestClock, BleManager, CBPeripheral, BleNativeConnectionTraceBuffer) {
        let clock = TestClock()
        let manager = BleManager(sampler: BleNativeTraceRssiSampler(schedule: clock.schedule))
        let peripheral = CBPeripheral()
        let trace = install(manager, peripheral)
        return (clock, manager, peripheral, trace)
    }

    @discardableResult
    static func install(_ manager: BleManager, _ peripheral: CBPeripheral) -> BleNativeConnectionTraceBuffer {
        let trace = BleNativeConnectionTraceBuffer()
        trace.record(stage: "attempt", result: "started")
        manager.nativeConnectionTraces[peripheral.identifier.uuidString] = trace
        manager.connectedDevices = [TestConnectedDevice(peripheral: peripheral)]
        manager.connectionTraceEnabled = true
        return trace
    }

    static func main() {
        // Normal callers retain the existing 2s first read / 15s periodic cadence.
        do {
            let (clock, manager, peripheral, trace) = fixture()
            manager.startNativeTraceRssiSampling(peripheral: peripheral)
            clock.advance(1.99); precondition(peripheral.reads == 0)
            clock.advance(0.01); precondition(peripheral.reads == 1 && clock.activeCount == 1)
            manager.peripheral(peripheral, didReadRSSI: -71, error: nil)
            clock.advance(15); precondition(peripheral.reads == 2)
            manager.peripheral(peripheral, didReadRSSI: -70, error: nil)
            precondition(trace.snapshot().lastRssiDbm == -70)
            precondition(manager.nativeTraceRssiInFlightAttemptIds.isEmpty)
        }
        // Quiet before BLE initialization/late GATT-ready creates no timer.
        do {
            let (clock, manager, peripheral, trace) = fixture()
            manager.nativeTraceRssiSampler.setPaused(true)
            manager.startNativeTraceRssiSampling(peripheral: peripheral)
            clock.advance(8 * 3600); precondition(peripheral.reads == 0 && clock.activeCount == 0)
            trace.record(stage: "physical_connection", result: "disconnected")
            precondition(trace.snapshot().steps.last?.stage == "physical_connection")
            precondition(manager.connectionTraceEnabled && manager.nativeConnectionTraces.count == 1)
            manager.nativeTraceRssiSampler.setPaused(false)
            manager.nativeTraceRssiSampler.setPaused(false)
            precondition(clock.activeCount == 1)
            clock.advance(2); precondition(peripheral.reads == 1 && clock.activeCount == 1)
        }
        // A cancelled initial callback delivered after pause cannot read/rearm.
        do {
            let (clock, manager, peripheral, _) = fixture()
            manager.startNativeTraceRssiSampling(peripheral: peripheral)
            let retired = clock.history[0]
            manager.nativeTraceRssiSampler.setPaused(true)
            manager.nativeTraceRssiSampler.setPaused(true)
            retired.action()
            precondition(peripheral.reads == 0 && clock.activeCount == 0)
            manager.nativeTraceRssiSampler.setPaused(false)
            retired.action()
            precondition(peripheral.reads == 0 && clock.activeCount == 1)
        }
        // Synchronous pause in the real read boundary must block repeat setup.
        do {
            let (clock, manager, peripheral, _) = fixture()
            peripheral.onRead = { manager.nativeTraceRssiSampler.setPaused(true) }
            manager.startNativeTraceRssiSampling(peripheral: peripheral)
            clock.advance(2); precondition(peripheral.reads == 1 && clock.activeCount == 0)
        }
        // Pausing keeps the unfinished read; its callback drains without caching.
        do {
            let (clock, manager, peripheral, trace) = fixture()
            manager.startNativeTraceRssiSampling(peripheral: peripheral)
            clock.advance(2)
            manager.nativeTraceRssiSampler.setPaused(true)
            precondition(manager.nativeTraceRssiInFlightAttemptIds.count == 1)
            manager.peripheral(peripheral, didReadRSSI: -60, error: nil)
            precondition(manager.nativeTraceRssiInFlightAttemptIds.isEmpty && trace.snapshot().lastRssiDbm == nil)
            manager.nativeTraceRssiSampler.setPaused(false)
            clock.advance(2); precondition(peripheral.reads == 2)
        }
        // A replaced peripheral must not resume its retired request.
        do {
            let (clock, manager, old, _) = fixture()
            manager.startNativeTraceRssiSampling(peripheral: old)
            manager.nativeTraceRssiSampler.setPaused(true)
            let new = CBPeripheral(identifier: old.identifier)
            install(manager, new)
            manager.nativeTraceRssiSampler.setPaused(false)
            clock.advance(100); precondition(old.reads == 0 && new.reads == 0 && clock.activeCount == 0)
            manager.startNativeTraceRssiSampling(peripheral: new)
            clock.advance(2); precondition(new.reads == 1)
        }
        // New attempt on the same object cannot overlap an unfinished old read.
        do {
            let (clock, manager, peripheral, _) = fixture()
            manager.startNativeTraceRssiSampling(peripheral: peripheral)
            clock.advance(2)
            manager.nativeTraceRssiSampler.setPaused(true)
            let newTrace = install(manager, peripheral)
            manager.startNativeTraceRssiSampling(peripheral: peripheral)
            manager.nativeTraceRssiSampler.setPaused(false)
            clock.advance(2); precondition(peripheral.reads == 1)
            manager.peripheral(peripheral, didReadRSSI: -55, error: nil)
            precondition(newTrace.snapshot().lastRssiDbm == nil)
            clock.advance(15); precondition(peripheral.reads == 2)
            manager.peripheral(peripheral, didReadRSSI: -79, error: nil)
            precondition(newTrace.snapshot().lastRssiDbm == -79)
        }
        // A different old peripheral's callback cannot consume the new request.
        do {
            let (clock, manager, old, _) = fixture()
            manager.startNativeTraceRssiSampling(peripheral: old)
            clock.advance(2)
            manager.nativeTraceRssiSampler.setPaused(true)
            let new = CBPeripheral(identifier: old.identifier)
            let trace = install(manager, new)
            manager.startNativeTraceRssiSampling(peripheral: new)
            manager.nativeTraceRssiSampler.setPaused(false)
            clock.advance(2); precondition(new.reads == 1)
            manager.peripheral(old, didReadRSSI: -50, error: nil)
            precondition(manager.nativeTraceRssiInFlightAttemptIds.count == 1 && trace.snapshot().lastRssiDbm == nil)
            manager.peripheral(new, didReadRSSI: -80, error: nil)
            precondition(trace.snapshot().lastRssiDbm == -80)
        }
        // Stop/Trace disable remains an explicit cancellation, never resumed.
        do {
            let (clock, manager, peripheral, _) = fixture()
            manager.startNativeTraceRssiSampling(peripheral: peripheral)
            manager.nativeTraceRssiSampler.setPaused(true)
            manager.setConnectionTraceEnabled(false)
            manager.nativeTraceRssiSampler.setPaused(false)
            clock.advance(100)
            precondition(peripheral.reads == 0 && clock.activeCount == 0 && manager.nativeConnectionTraces.isEmpty)
        }
        // A completion after physical disconnect must drain, not update Trace.
        do {
            let (clock, manager, peripheral, trace) = fixture()
            manager.startNativeTraceRssiSampling(peripheral: peripheral)
            clock.advance(2)
            peripheral.state = .disconnected
            manager.peripheral(peripheral, didReadRSSI: -52, error: nil)
            precondition(manager.nativeTraceRssiInFlightAttemptIds.isEmpty && trace.snapshot().lastRssiDbm == nil)
            clock.advance(15); precondition(peripheral.reads == 1 && clock.activeCount == 0)
        }
        // Read/rearm rejects actual disconnect and an incomplete cached owner.
        do {
            let (clock, manager, peripheral, _) = fixture()
            manager.startNativeTraceRssiSampling(peripheral: peripheral)
            manager.connectedDevices[0].isBleFlowCompleted = false
            clock.advance(2); precondition(peripheral.reads == 0 && clock.activeCount == 0)
            manager.connectedDevices[0].isBleFlowCompleted = true
            manager.startNativeTraceRssiSampling(peripheral: peripheral)
            peripheral.state = .disconnected
            clock.advance(2); precondition(peripheral.reads == 0 && clock.activeCount == 0)
        }
        print("native RSSI sampling: all behavior checks passed")
    }
}
