import Foundation

/// A runtime lane belongs to one successful physical attempt and the actual
/// peripheral/characteristic objects. UUID equality must never migrate a lane.
struct BleRuntimeCommonIdentity: Equatable {
    let uuid: String
    let sessionGeneration: Int64
    let attemptGeneration: Int64
    let peripheralId: AnyHashable
    let characteristicId: AnyHashable
}

struct BleRuntimeCommonResult {
    let status: String
    let enabled: Bool?
    let revision: Int64

    var raw: [String: Any] {
        var value: [String: Any] = ["status": status, "revision": revision]
        if let enabled { value["enabled"] = enabled }
        return value
    }
}

/// CoreBluetooth has no CCCD request id. Keep the physical operation in flight
/// after a deadline, so its late false callback can never acknowledge a new true.
/// Only real callbacks/terminal events advance that physical lane. All calls run
/// on the manager's main queue; tests replace only the clock and CB submit edge.
final class BleRuntimeCommonNotifications {
    typealias Completion = (BleRuntimeCommonResult) -> Void
    typealias Schedule = (TimeInterval, @escaping () -> Void) -> (() -> Void)
    private final class Waiter {
        let id = UUID()
        let revision: Int64
        let desired: Bool
        let completion: Completion
        var cancelDeadline: (() -> Void)?
        init(revision: Int64, desired: Bool, completion: @escaping Completion) {
            self.revision = revision
            self.desired = desired
            self.completion = completion
        }
    }
    private final class Lane {
        let identity: BleRuntimeCommonIdentity
        var revision: Int64
        var desired: Bool
        var confirmed: Bool?
        var operation: Bool?
        var unknown = false
        var recoveryRequested = false
        var waiters: [Waiter] = []
        var submit: (Bool) -> Bool
        init(identity: BleRuntimeCommonIdentity, revision: Int64, desired: Bool,
             physicalState: Bool, submit: @escaping (Bool) -> Bool) {
            self.identity = identity
            self.revision = revision
            self.desired = desired
            self.confirmed = physicalState
            self.submit = submit
        }
    }
    private var lanes: [String: Lane] = [:]
    private let schedule: Schedule
    private let confirmationBudget: TimeInterval

    init(confirmationBudget: TimeInterval = 5, schedule: @escaping Schedule = { delay, body in
        let work = DispatchWorkItem(block: body)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        return { work.cancel() }
    }) {
        self.confirmationBudget = confirmationBudget
        self.schedule = schedule
    }

    /// Changing desired state fences writes synchronously, before setNotifyValue.
    /// Repeated intent shares the operation while each caller has a bounded wait.
    func request(identity: BleRuntimeCommonIdentity, revision: Int64, enabled: Bool,
                 physicalState: Bool, submit: @escaping (Bool) -> Bool,
                 completion: @escaping Completion) {
        guard identity.sessionGeneration > 0, identity.attemptGeneration > 0, revision > 0 else {
            completion(BleRuntimeCommonResult(status: "stale", enabled: nil, revision: revision))
            return
        }
        if let old = lanes[identity.uuid], old.identity != identity {
            // A new validated attempt retires only the old lane; it must never
            // inherit a previous connection's fence or callback expectation.
            lanes.removeValue(forKey: identity.uuid)
            retire(old, status: "stale")
            // Retiring a waiter can synchronously install another valid intent.
            // Do not erase or replace that new physical owner on the way out.
            if let installed = lanes[identity.uuid], installed.identity != identity {
                completion(BleRuntimeCommonResult(status: "stale", enabled: nil, revision: revision))
                return
            }
        }
        let lane = lanes[identity.uuid] ?? Lane(identity: identity, revision: revision,
            desired: enabled, physicalState: physicalState, submit: submit)
        lanes[identity.uuid] = lane
        guard revision >= lane.revision,
              revision != lane.revision || enabled == lane.desired else {
            completion(BleRuntimeCommonResult(status: "stale", enabled: lane.confirmed, revision: revision))
            return
        }
        lane.submit = submit
        lane.revision = revision
        lane.desired = enabled
        let superseded = lane.waiters.filter { $0.revision != revision || $0.desired != enabled }
        lane.waiters.removeAll { $0.revision != revision || $0.desired != enabled }
        finish(superseded, lane: lane, status: "stale")
        // Completion delivery can synchronously re-enter through platform tests
        // or adapters; do not install the older caller after a new intent won.
        guard lanes[identity.uuid] === lane, lane.revision == revision, lane.desired == enabled else {
            completion(BleRuntimeCommonResult(status: "stale", enabled: lane.confirmed, revision: revision))
            return
        }
        if lane.recoveryRequested {
            // cancelPeripheralConnection is irreversible for this physical lane.
            // A late true callback cannot reopen writes before real disconnect.
            completion(BleRuntimeCommonResult(status: "reconnecting", enabled: lane.confirmed, revision: revision))
            return
        }
        let waiter = Waiter(revision: revision, desired: enabled, completion: completion)
        lane.waiters.append(waiter)
        waiter.cancelDeadline = schedule(confirmationBudget) { [weak self, weak lane, weak waiter] in
            guard let self, let lane, let waiter,
                  self.lanes[identity.uuid] === lane,
                  lane.waiters.contains(where: { $0 === waiter }) else { return }
            // Do not clear operation: CoreBluetooth still owes its callback.
            lane.unknown = true
            lane.waiters.removeAll { $0 === waiter }
            self.finish([waiter], lane: lane, status: "unknown")
        }
        pump(lane)
    }

    /// Runtime routing precedes initialization's admission/readiness guard.
    /// Return true only for this exact physical characteristic, including errors.
    func didUpdate(uuid: String, peripheralId: AnyHashable, characteristicId: AnyHashable,
                   enabled: Bool, failed: Bool) -> Bool {
        guard let lane = lanes[uuid], lane.identity.peripheralId == peripheralId,
              lane.identity.characteristicId == characteristicId else { return false }
        guard let operation = lane.operation else {
            // An unsolicited mismatch (for example teardown racing a late
            // writer) is not evidence that the last confirmed ready state held.
            // Do not automatically retry CCCD or grant restore authorization.
            lane.confirmed = failed ? nil : enabled
            if failed || enabled != lane.desired { lane.unknown = true }
            return true
        }
        lane.operation = nil
        lane.confirmed = failed ? nil : enabled
        lane.unknown = failed || enabled != operation
        if lane.unknown {
            let waiters = lane.waiters
            lane.waiters.removeAll()
            finish(waiters, lane: lane, status: "failed")
        } else {
            // The latest intent may have changed during the old operation.
            // Complete only after its compensating true has its own callback.
            pump(lane)
        }
        return true
    }

    /// The last native common write edge must use this fence. An old attempt's
    /// lane cannot block a new attempt's initialization/AUTH.
    func blocksWrite(uuid: String, sessionGeneration: Int64, attemptGeneration: Int64,
                     peripheralId: AnyHashable) -> Bool {
        guard let lane = lanes[uuid], lane.identity.peripheralId == peripheralId,
              (sessionGeneration <= 0 || attemptGeneration <= 0 ||
               (lane.identity.sessionGeneration == sessionGeneration &&
                lane.identity.attemptGeneration == attemptGeneration)) else { return false }
        return lane.recoveryRequested || !lane.desired || lane.operation != nil || lane.unknown || lane.confirmed != true
    }

    /// At most one actual cancel per physical lane, even if clients retry with
    /// new revisions. No terminal state is synthesized when that cancel starts.
    func requestRecovery(identity: BleRuntimeCommonIdentity, revision: Int64,
                         cancel: () -> Void) -> BleRuntimeCommonResult {
        guard let lane = lanes[identity.uuid], lane.identity == identity,
              revision == lane.revision else {
            return BleRuntimeCommonResult(status: "stale", enabled: nil, revision: revision)
        }
        if lane.recoveryRequested {
            return BleRuntimeCommonResult(status: "reconnecting", enabled: lane.confirmed, revision: revision)
        }
        guard lane.desired, lane.unknown else {
            return BleRuntimeCommonResult(status: "busy", enabled: lane.confirmed, revision: revision)
        }
        if !lane.recoveryRequested {
            lane.recoveryRequested = true
            cancel()
        }
        return BleRuntimeCommonResult(status: "reconnecting", enabled: lane.confirmed, revision: revision)
    }

    /// Real disconnect/reset/explicit owner teardown ends only its own objects.
    func terminal(uuid: String, peripheralId: AnyHashable? = nil) {
        guard let lane = lanes[uuid], peripheralId == nil || lane.identity.peripheralId == peripheralId else { return }
        lanes.removeValue(forKey: uuid)
        retire(lane, status: "notConnected")
    }

    func removeAll() {
        let old = Array(lanes.values)
        lanes.removeAll()
        for lane in old { retire(lane, status: "notConnected") }
    }

    private func pump(_ lane: Lane) {
        guard lanes[lane.identity.uuid] === lane, lane.operation == nil else { return }
        if lane.recoveryRequested {
            let waiters = lane.waiters
            lane.waiters.removeAll()
            finish(waiters, lane: lane, status: "reconnecting")
            return
        }
        if !lane.unknown, lane.confirmed == lane.desired {
            let waiters = lane.waiters
            lane.waiters.removeAll()
            finish(waiters, lane: lane, status: "confirmed")
            return
        }
        lane.operation = lane.desired
        if !lane.submit(lane.desired) {
            lane.operation = nil
            lane.confirmed = nil
            lane.unknown = true
            let waiters = lane.waiters
            lane.waiters.removeAll()
            finish(waiters, lane: lane, status: "stale")
        }
    }

    private func retire(_ lane: Lane, status: String) {
        let waiters = lane.waiters
        lane.waiters.removeAll()
        finish(waiters, lane: lane, status: status)
    }

    private func finish(_ waiters: [Waiter], lane: Lane, status: String) {
        for waiter in waiters {
            waiter.cancelDeadline?()
            waiter.cancelDeadline = nil
            waiter.completion(BleRuntimeCommonResult(status: status,
                enabled: lane.confirmed, revision: waiter.revision))
        }
    }
}
