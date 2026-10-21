import Foundation

/// A long-lived endpoint owns its Code 1 budget. Activation/session changes do
/// not erase the deadline; only a successful business connection ends the episode.
struct BleInvalidParametersBackoff {
    private(set) var failureCount = 0
    private(set) var deadline: TimeInterval = 0
    private(set) var jobToken = UUID()

    /// Match the CoreBluetooth domain as well as the code: numeric 1 elsewhere
    /// is not invalidParameters and must retain its existing recovery policy.
    static func matches(domain: String?, code: Int?) -> Bool {
        domain == "CBErrorDomain" && code == 1
    }

    mutating func registerFailure(now: TimeInterval) {
        failureCount = min(failureCount + 1, 6)
        let delays: [TimeInterval] = [1, 2, 4, 8, 16, 30]
        deadline = now + delays[failureCount - 1]
        invalidateJob()
    }

    /// Escrow and the business owner represent the same endpoint episode.
    /// Moving ownership must retain its debt without counting one terminal twice.
    mutating func absorb(_ previous: BleInvalidParametersBackoff) {
        guard previous.failureCount > 0 else { return }
        failureCount = max(failureCount, previous.failureCount)
        deadline = max(deadline, previous.deadline)
        invalidateJob()
    }

    func remaining(now: TimeInterval) -> TimeInterval { max(0, deadline - now) }

    /// Replacing a timer invalidates its callback even if the run loop already
    /// dequeued it. Owner/session/epoch are checked separately by the ticket.
    mutating func invalidateJob() { jobToken = UUID() }
    mutating func businessConnected() { self = BleInvalidParametersBackoff() }
}

/// A timer cannot look up a replacement merely by UUID. Freeze the complete
/// owner/session/transport/token tuple before crossing the asynchronous boundary.
struct BleReconnectRetryTicket: Equatable {
    let owner: UUID
    let session: Int64
    let epoch: Int64
    let token: UUID
}

/// CoreBluetooth invalidates held objects below poweredOff, independently of
/// the Dart transport epoch (which also advances for ordinary Bluetooth off).
/// Weak entries avoid keeping discarded peripherals alive or accepting reused
/// ObjectIdentifier addresses after a peripheral is released.
final class BlePeripheralValidityRegistry {
    private final class Entry {
        weak var object: AnyObject?
        let generation: UUID
        init(_ object: AnyObject, generation: UUID) {
            self.object = object
            self.generation = generation
        }
    }
    private var generation = UUID()
    private var hasInvalidated = false
    private var isInvalidating = false
    private var hasObservedPoweredOn = false
    private var entries: [ObjectIdentifier: Entry] = [:]

    /// rawValue is Apple's stable CBManagerState ordering; 4 is poweredOff.
    func observeTransportState(rawValue: Int) {
        // Initial unknown is the newly constructed central's bootstrap state.
        // willRestoreState may precede its first poweredOn callback; those fresh
        // restored objects do not belong to a previous running transport.
        if rawValue == 5 { hasObservedPoweredOn = true }
        let invalidating = rawValue < 4 && (rawValue != 0 || hasObservedPoweredOn)
        if invalidating && !isInvalidating {
            generation = UUID()
            hasInvalidated = true
            entries.removeAll()
        }
        isInvalidating = invalidating
    }

    /// Only retrieve, didDiscover and explicit restoration inputs publish an
    /// object. didConnect/late terminal callbacks never bless an old instance.
    func observe(_ object: AnyObject) {
        entries = entries.filter { $0.value.object != nil }
        entries[ObjectIdentifier(object)] = Entry(object, generation: generation)
    }

    func isValid(_ object: AnyObject) -> Bool {
        guard let entry = entries[ObjectIdentifier(object)] else { return !hasInvalidated }
        return entry.object === object && entry.generation == generation
    }
}

/// An invalid restored object may retain a stable identity and retry debt, but
/// cannot take the connected/pending shortcut into the physical/GATT owner.
struct BleRestorationObjectResolution {
    let mayUseClaimedObject: Bool
    let fallbackUuid: String
    let retryDebt: BleInvalidParametersBackoff

    init(requestedUuid: String, claimedUuid: String?, claimedObjectIsValid: Bool,
         retryDebt: BleInvalidParametersBackoff) {
        mayUseClaimedObject = claimedUuid != nil && claimedObjectIsValid
        fallbackUuid = requestedUuid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (claimedUuid ?? requestedUuid) : requestedUuid
        self.retryDebt = retryDebt
    }

    func applyingDebt(to current: BleInvalidParametersBackoff) -> BleInvalidParametersBackoff {
        var merged = current
        merged.absorb(retryDebt)
        return merged
    }
}
