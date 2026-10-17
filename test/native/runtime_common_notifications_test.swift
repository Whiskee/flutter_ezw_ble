import Foundation

private func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}

private final class Clock {
    var bodies: [Int: () -> Void] = [:]
    var next = 0
    func schedule(_ delay: TimeInterval, _ body: @escaping () -> Void) -> (() -> Void) {
        next += 1
        let id = next
        bodies[id] = body
        return { [weak self] in self?.bodies.removeValue(forKey: id) }
    }
    func expire() {
        let ready = Array(bodies.values)
        bodies.removeAll()
        for body in ready { body() }
    }
}

private func identity(_ attempt: Int64 = 4, _ object: String = "peripheral") -> BleRuntimeCommonIdentity {
    BleRuntimeCommonIdentity(uuid: "ring", sessionGeneration: 3,
        attemptGeneration: attempt, peripheralId: object, characteristicId: "common")
}

@main
struct RuntimeCommonTests {
    static func main() {
        let clock = Clock()
        let lane = BleRuntimeCommonNotifications(schedule: clock.schedule)
        var submitted: [Bool] = []
        var results: [BleRuntimeCommonResult] = []
        let submit: (Bool) -> Bool = { submitted.append($0); return true }
        func request(_ revision: Int64, _ enabled: Bool, _ owner: BleRuntimeCommonIdentity = identity()) {
            lane.request(identity: owner, revision: revision, enabled: enabled,
                physicalState: true, submit: submit) { results.append($0) }
        }
        func callback(_ enabled: Bool, failed: Bool = false, object: String = "peripheral") {
            check(lane.didUpdate(uuid: "ring", peripheralId: object,
                characteristicId: "common", enabled: enabled, failed: failed), "runtime callback routed")
        }
        func blocked(_ attempt: Int64 = 4, _ object: String = "peripheral") -> Bool {
            lane.blocksWrite(uuid: "ring", sessionGeneration: 3,
                attemptGeneration: attempt, peripheralId: object)
        }

        // Real off/true intents serialize. The old false cannot acknowledge true.
        request(1, false)
        check(submitted == [false] && blocked(), "off fences before submission")
        request(2, true)
        check(submitted == [false] && results.last?.status == "stale", "on waits for off")
        callback(false)
        check(submitted == [false, true] && blocked(), "false callback pumps true but remains fenced")
        callback(true)
        check(results.last?.status == "confirmed" && results.last?.enabled == true && !blocked(), "true has own confirmation")
        request(2, true)
        check(submitted.count == 2 && results.last?.status == "confirmed", "same ready intent idempotent")
        request(1, false)
        check(results.last?.status == "stale" && submitted.count == 2, "old revision rejected")

        // Timeout resolves the caller but retains the operation; no second CCCD
        // is submitted until that exact old callback or a real disconnect.
        request(3, false)
        clock.expire()
        check(results.last?.status == "unknown" && blocked(), "off timeout unknown")
        request(4, true)
        clock.expire()
        check(results.last?.status == "unknown" && submitted == [false, true, false], "true deadline cannot fake old operation completion")
        var cancels = 0
        let recovery = lane.requestRecovery(identity: identity(), revision: 4) { cancels += 1 }
        check(recovery.status == "reconnecting" && cancels == 1 && blocked(), "real cancel does not release fence")
        _ = lane.requestRecovery(identity: identity(), revision: 4) { cancels += 1 }
        check(cancels == 1, "repeated recovery cannot duplicate cancel")
        // Even a late callback after cancel cannot authorize old-lane writes.
        callback(false)
        check(submitted == [false, true, false] && blocked(), "accepted cancel prevents CCCD compensation")
        request(5, true)
        check(results.last?.status == "reconnecting" && blocked(), "no terminal cannot report ready")
        clock.expire()
        _ = lane.requestRecovery(identity: identity(), revision: 5) { cancels += 1 }
        check(cancels == 1, "new revision cannot duplicate exact physical cancel")
        check(!blocked(5), "new positive attempt AUTH not fenced")
        check(blocked(0), "missing owner cannot bypass matching physical fence")
        check(!lane.didUpdate(uuid: "ring", peripheralId: "replacement", characteristicId: "common", enabled: false, failed: false), "foreign physical callback ignored")
        lane.terminal(uuid: "ring", peripheralId: "replacement")
        check(blocked(), "foreign terminal cannot clear fence")
        lane.terminal(uuid: "ring", peripheralId: "peripheral")
        check(!blocked(), "real terminal releases old lane")

        // New attempt starts with ordinary initialization and is independent.
        request(1, false, identity(5))
        callback(false)
        check(results.last?.status == "confirmed" && results.last?.enabled == false && blocked(5), "new attempt can pause independently")
        request(2, true, identity(5))
        callback(true, failed: true)
        check(results.last?.status == "failed" && blocked(5), "native error cannot claim ready")
        request(3, true, identity(5))
        callback(true)
        check(results.last?.status == "confirmed" && !blocked(5), "later opportunity restores after consumed error")

        // A replacement object retires old waiters; old callbacks cannot satisfy it.
        request(4, false, identity(5))
        request(1, false, identity(6, "replacement"))
        check(results.last?.status == "stale", "replacement retires old waiter")
        check(!lane.didUpdate(uuid: "ring", peripheralId: "peripheral", characteristicId: "common", enabled: false, failed: false), "old object cannot acknowledge replacement")
        callback(false, object: "replacement")
        check(results.last?.status == "confirmed" && blocked(6, "replacement"), "new object requires own callback")
        lane.removeAll()
        check(clock.bodies.isEmpty, "terminal cancels request deadlines")

        // Completion re-entry must not resurrect a superseded caller.
        let reentrant = BleRuntimeCommonNotifications(schedule: clock.schedule)
        var reentrantWrites: [Bool] = []
        var stale = false
        reentrant.request(identity: identity(), revision: 1, enabled: false, physicalState: true,
            submit: { reentrantWrites.append($0); return true }) { result in
                if result.status == "stale" {
                    reentrant.request(identity: identity(), revision: 3, enabled: true, physicalState: true,
                        submit: { reentrantWrites.append($0); return true }) { _ in }
                }
            }
        reentrant.request(identity: identity(), revision: 2, enabled: true, physicalState: true,
            submit: { reentrantWrites.append($0); return true }) { result in stale = result.status == "stale" }
        check(stale && reentrantWrites == [false], "synchronous completion cannot install old revision")
        _ = reentrant.didUpdate(uuid: "ring", peripheralId: "peripheral", characteristicId: "common", enabled: false, failed: false)
        check(reentrantWrites == [false, true], "latest compensating true submitted once")
        let unsolicited = BleRuntimeCommonNotifications(schedule: clock.schedule)
        unsolicited.request(identity: identity(), revision: 1, enabled: true, physicalState: true,
            submit: { _ in fatalError("already confirmed true needs no new operation") }) { _ in }
        _ = unsolicited.didUpdate(uuid: "ring", peripheralId: "peripheral", characteristicId: "common", enabled: false, failed: false)
        check(unsolicited.blocksWrite(uuid: "ring", sessionGeneration: 3,
            attemptGeneration: 4, peripheralId: "peripheral"), "unsolicited false cannot preserve ready write fence")
        var compensated = false
        unsolicited.request(identity: identity(), revision: 2, enabled: true, physicalState: false,
            submit: { value in compensated = value; return true }) { _ in }
        check(compensated, "only a new explicit restore opportunity submits compensation")
        _ = unsolicited.didUpdate(uuid: "ring", peripheralId: "peripheral", characteristicId: "common", enabled: true, failed: false)
        check(!unsolicited.blocksWrite(uuid: "ring", sessionGeneration: 3,
            attemptGeneration: 4, peripheralId: "peripheral"), "own true confirmation restores unsolicited mismatch")
        print("runtime common notifications: all behavior checks passed")
    }
}
