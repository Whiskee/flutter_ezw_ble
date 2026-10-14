import Foundation

/// CoreBluetooth returns RSSI without a request token. Keep an unfinished read
/// separate from a trace's lifetime, so replacing a trace cannot relabel its
/// late callback as a newer read on the same peripheral object.
final class BleNativeTraceRssiRequests {
    private final class Request {
        weak var peripheral: AnyObject?
        let attemptId: String
        init(peripheral: AnyObject, attemptId: String) {
            self.peripheral = peripheral
            self.attemptId = attemptId
        }
    }
    private var requests: [ObjectIdentifier: Request] = [:]

    func begin(peripheral: AnyObject, attemptId: String) -> Bool {
        // Do not retain disconnected peripherals merely for diagnostics.
        requests = requests.filter { $0.value.peripheral != nil }
        let key = ObjectIdentifier(peripheral)
        guard requests[key] == nil else { return false }
        requests[key] = Request(peripheral: peripheral, attemptId: attemptId)
        return true
    }

    func finish(peripheral: AnyObject) -> String? {
        let key = ObjectIdentifier(peripheral)
        guard let request = requests[key], request.peripheral === peripheral else { return nil }
        requests.removeValue(forKey: key)
        return request.attemptId
    }
}

/// Owns diagnostic timers only. The independent singleton can accept a host
/// pause before BleManager exists without constructing a CoreBluetooth central.
final class BleNativeTraceRssiSampler {
    typealias Cancel = () -> Void
    typealias Schedule = (TimeInterval, Bool, @escaping () -> Void) -> Cancel

    static let shared = BleNativeTraceRssiSampler()

    private final class Sampling {
        let isOwnerCurrent: () -> Bool
        let read: () -> Void
        var revision: UInt64 = 0
        var cancel: Cancel?

        init(isOwnerCurrent: @escaping () -> Bool, read: @escaping () -> Void) {
            self.isOwnerCurrent = isOwnerCurrent
            self.read = read
        }

        func retireTimer() {
            revision &+= 1
            cancel?()
            cancel = nil
        }
    }

    private let schedule: Schedule
    private var samplings: [String: Sampling] = [:]
    private(set) var isPaused = false

    /// Production and injected schedulers enqueue callbacks in the caller's
    /// serial domain; they must not call the action synchronously from schedule.
    init(schedule: @escaping Schedule = { interval, repeats, action in
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: repeats) { _ in action() }
        return { timer.invalidate() }
    }) {
        self.schedule = schedule
    }

    func setPaused(_ paused: Bool) {
        precondition(Thread.isMainThread)
        guard isPaused != paused else { return }
        isPaused = paused
        // Keep only the request and its live-owner check. Pausing never clears
        // a trace, changes connection ownership, or starts an extra retry.
        for sampling in samplings.values { sampling.retireTimer() }
        if !paused {
            for (key, sampling) in Array(samplings) { arm(key, sampling) }
        }
    }

    func start(key: String, isOwnerCurrent: @escaping () -> Bool, read: @escaping () -> Void) {
        precondition(Thread.isMainThread)
        stop(key: key)
        let sampling = Sampling(isOwnerCurrent: isOwnerCurrent, read: read)
        samplings[key] = sampling
        arm(key, sampling)
    }

    func stop(key: String) {
        precondition(Thread.isMainThread)
        samplings.removeValue(forKey: key)?.retireTimer()
    }

    func stopAll() {
        precondition(Thread.isMainThread)
        for sampling in samplings.values { sampling.retireTimer() }
        samplings.removeAll()
    }

    private func arm(_ key: String, _ sampling: Sampling) {
        guard !isPaused else { return }
        guard sampling.isOwnerCurrent() else { stop(key: key); return }
        let revision = sampling.revision
        sampling.cancel = schedule(2.0, false) { [weak self, weak sampling] in
            guard let self, let sampling, self.accepts(key, sampling, revision) else { return }
            sampling.read()
            // readRSSI or a test driver can synchronously revoke the request.
            // A retired initial callback must never create a repeating timer.
            guard self.accepts(key, sampling, revision) else { return }
            sampling.cancel = self.schedule(15.0, true) { [weak self, weak sampling] in
                guard let self, let sampling, self.accepts(key, sampling, revision) else { return }
                sampling.read()
            }
        }
    }

    private func accepts(_ key: String, _ sampling: Sampling, _ revision: UInt64) -> Bool {
        guard !isPaused, samplings[key] === sampling, sampling.revision == revision else { return false }
        guard sampling.isOwnerCurrent() else { stop(key: key); return false }
        return true
    }
}
