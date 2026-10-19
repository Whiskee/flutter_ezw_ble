import Foundation

/// Fake time executes the production deadline/object policy. No timer sleeps,
/// CoreBluetooth daemon or hardware are needed to cover hostile interleavings.
@main
struct ResetReconnectFailureTests {
    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        precondition(value(), message)
    }
    static func main() {
        var now: TimeInterval = 100
        var policy = BleInvalidParametersBackoff()
        check(BleInvalidParametersBackoff.matches(domain: "CBErrorDomain", code: 1), "Code 1 must match")
        check(!BleInvalidParametersBackoff.matches(domain: "ATTErrorDomain", code: 1), "other domain must not count")
        check(!BleInvalidParametersBackoff.matches(domain: "CBErrorDomain", code: 14), "Code 14 must not count")
        check(!BleInvalidParametersBackoff.matches(domain: nil, code: nil), "nil error must not count")
        for delay: TimeInterval in [1, 2, 4, 8, 16, 30, 30, 30] {
            let oldToken = policy.jobToken
            policy.registerFailure(now: now)
            check(policy.remaining(now: now) == delay, "wrong backoff")
            check(policy.jobToken != oldToken, "failure must invalidate queued callback")
            // Activation/scan/lifecycle all read the same deadline; repeated
            // scheduling only revokes a job token, never advances the deadline.
            let deadline = policy.deadline
            for _ in 0..<100 {
                policy.invalidateJob()
                check(policy.deadline == deadline && policy.remaining(now: now) > 0, "reentry bypassed deadline")
            }
            now += delay - 0.001
            check(policy.remaining(now: now) > 0, "retry fired early")
            now += 0.001
            check(policy.remaining(now: now) < 0.000001, "retry failed to become ready")
        }
        check(policy.failureCount == 6, "counter must saturate")
        let owner = UUID()
        let old = BleReconnectRetryTicket(owner: owner, session: 2, epoch: 4, token: policy.jobToken)
        check(old != BleReconnectRetryTicket(owner: UUID(), session: 2, epoch: 4, token: policy.jobToken), "cancel/new owner accepted old timer")
        check(old != BleReconnectRetryTicket(owner: owner, session: 3, epoch: 4, token: policy.jobToken), "new session accepted old timer")
        check(old != BleReconnectRetryTicket(owner: owner, session: 2, epoch: 5, token: policy.jobToken), "new reset accepted old timer")
        policy.invalidateJob()
        check(old != BleReconnectRetryTicket(owner: owner, session: 2, epoch: 4, token: policy.jobToken), "replacement job accepted old timer")
        policy.businessConnected()
        check(policy.failureCount == 0 && policy.remaining(now: now) == 0, "business success did not reset episode")
        policy.registerFailure(now: now)
        check(policy.remaining(now: now) == 1, "new successful episode must restart at one second")
        let absentClaim = BleRestorationObjectResolution(requestedUuid: "REQUESTED", claimedUuid: nil, claimedObjectIsValid: true, retryDebt: BleInvalidParametersBackoff())
        check(!absentClaim.mayUseClaimedObject && absentClaim.fallbackUuid == "REQUESTED" && absentClaim.retryDebt.failureCount == 0, "absent SR claim changed default identity/debt")
        let whitespaceClaim = BleRestorationObjectResolution(requestedUuid: "  ", claimedUuid: "CLAIMED", claimedObjectIsValid: false, retryDebt: BleInvalidParametersBackoff())
        check(whitespaceClaim.fallbackUuid == "CLAIMED", "blank SR target did not retain claimed UUID")
        var escrowDebt = BleInvalidParametersBackoff()
        escrowDebt.registerFailure(now: 500)
        for requested in ["", "STABLE_UUID"] {
            let invalidClaim = BleRestorationObjectResolution(requestedUuid: requested, claimedUuid: "OLD_UUID", claimedObjectIsValid: false, retryDebt: escrowDebt)
            check(!invalidClaim.mayUseClaimedObject, "invalid SR object entered connected/pending shortcut")
            check(invalidClaim.fallbackUuid == (requested.isEmpty ? "OLD_UUID" : requested), "invalid SR claim lost stable/name-only UUID")
            let merged = invalidClaim.applyingDebt(to: BleInvalidParametersBackoff())
            check(merged.failureCount == 1 && merged.remaining(now: 500) == 1, "invalid SR fallback lost deadline")
            let freshReplacement = BleRestorationObjectResolution(requestedUuid: invalidClaim.fallbackUuid, claimedUuid: "FRESH_UUID", claimedObjectIsValid: true, retryDebt: merged)
            check(freshReplacement.mayUseClaimedObject && freshReplacement.applyingDebt(to: BleInvalidParametersBackoff()).remaining(now: 500.5) == 0.5, "fresh SR/retrieve replacement erased endpoint debt")
        }
        print("PASS: exact Code 1 domain, fake-clock 1/2/4/8/16/30 backoff, reentry deadline, owner/session/epoch/token and success reset")

        let bootRegistry = BlePeripheralValidityRegistry()
        let restoredBeforeFirstState = NSObject()
        bootRegistry.observe(restoredBeforeFirstState)
        bootRegistry.observeTransportState(rawValue: 0)
        bootRegistry.observeTransportState(rawValue: 5)
        check(bootRegistry.isValid(restoredBeforeFirstState), "bootstrap unknown discarded fresh restoration object")
        bootRegistry.observeTransportState(rawValue: 0)
        check(!bootRegistry.isValid(restoredBeforeFirstState), "running transport unknown failed invalidation")
        let registry = BlePeripheralValidityRegistry()
        let oldLeft = NSObject(), oldRight = NSObject(), ring = NSObject()
        [oldLeft, oldRight, ring].forEach { registry.observe($0) }
        registry.observeTransportState(rawValue: 4)
        registry.observeTransportState(rawValue: 5)
        check(registry.isValid(oldLeft) && registry.isValid(oldRight) && registry.isValid(ring), "ordinary off/on invalidated objects")
        registry.observeTransportState(rawValue: 1)
        check(!registry.isValid(oldLeft) && !registry.isValid(oldRight) && !registry.isValid(ring), "reset retained cached objects")
        registry.observeTransportState(rawValue: 5)
        let freshLeft = NSObject()
        registry.observe(freshLeft)
        check(registry.isValid(freshLeft) && !registry.isValid(oldLeft), "fresh object did not replace old object")
        registry.observe(oldRight) // valid foreground retrieve may return same instance
        check(registry.isValid(oldRight), "fresh retrieve provenance rejected")
        registry.observeTransportState(rawValue: 1)
        registry.observeTransportState(rawValue: 5)
        check(!registry.isValid(freshLeft) && !registry.isValid(oldRight), "consecutive reset accepted prior objects")
        let freshRing = NSObject()
        registry.observe(freshRing)
        check(registry.isValid(freshRing) && !registry.isValid(ring), "R1 object isolation failed")
        for state in [0, 2, 3] {
            registry.observeTransportState(rawValue: 5)
            registry.observe(freshRing)
            registry.observeTransportState(rawValue: state)
            check(!registry.isValid(freshRing), "below poweredOff failed invalidation")
        }
        print("PASS: reset/continuous reset invalidate all held objects, retrieve/discover restore validity, ordinary off/on and independent G2/R1 objects")
    }
}
