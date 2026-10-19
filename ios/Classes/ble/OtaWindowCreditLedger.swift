import Foundation

/// Exact owner for one G2 OTA RAW window credit receipt.
///
/// The receipt is only a native observation token: it never proves firmware
/// install success or authorize a queue budget reset. The historical Credit
/// names remain for compatibility; consume only associates the next FILE timing.
struct OtaWindowCreditOwner: Equatable {
    let uuid: String
    let sessionGeneration: Int64
    let attemptGeneration: Int64
    let transactionId: String
    let otaGeneration: Int64
    let instanceId: String

    init?(
        uuid: String,
        sessionGeneration: Int64,
        attemptGeneration: Int64,
        transactionId: String,
        otaGeneration: Int64,
        instanceId: String
    ) {
        let normalizedUuid = uuid.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedTransactionId = transactionId.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedInstanceId = instanceId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedUuid.isEmpty,
              sessionGeneration > 0,
              attemptGeneration > 0,
              !normalizedTransactionId.isEmpty,
              otaGeneration > 0,
              !normalizedInstanceId.isEmpty else {
            return nil
        }
        self.uuid = normalizedUuid
        self.sessionGeneration = sessionGeneration
        self.attemptGeneration = attemptGeneration
        self.transactionId = normalizedTransactionId
        self.otaGeneration = otaGeneration
        self.instanceId = normalizedInstanceId
    }
}

struct OtaWindowCreditRegistration {
    let windowId: String
    let expectedAck: Data
    let owner: OtaWindowCreditOwner

    init?(windowId: String, expectedAck: Data, owner: OtaWindowCreditOwner) {
        let normalizedWindowId = windowId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedWindowId.isEmpty,
              normalizedWindowId.count <= 128,
              Self.isCanonicalG2RawAck(expectedAck) else {
            return nil
        }
        self.windowId = normalizedWindowId
        self.expectedAck = expectedAck
        self.owner = owner
    }

    /// Firmware ACK bytes for a 4 KiB RAW window. The sync byte at index 2 is
    /// per-window; the rest must stay fixed so a caller cannot register an
    /// arbitrary notification as a credit source.
    private static func isCanonicalG2RawAck(_ data: Data) -> Bool {
        let bytes = [UInt8](data)
        return bytes.count == 12 &&
            bytes[0] == 0xAA &&
            bytes[1] == 0x12 &&
            bytes[3] == 0x04 &&
            bytes[4] == 0x01 &&
            bytes[5] == 0x01 &&
            bytes[6] == 0xC1 &&
            bytes[7] == 0x00 &&
            bytes[8] == 0x02 &&
            bytes[9] == 0x00 &&
            bytes[10] == 0x6D &&
            bytes[11] == 0x7B
    }
}

struct OtaWindowCreditReceipt {
    let windowId: String
    let receiptId: String
}

struct OtaWindowCreditConsumeResult {
    // Consumption is FILE admission, not the CoreBluetooth submission boundary.
    let notificationAtMonotonic: TimeInterval
    let nativeNotifyToCreditMs: Int
}

/// One-slot fail-closed ledger for OTA 4 KiB ACK observations.
///
/// It intentionally keeps no unbounded history. A new registration replaces
/// the previous active slot; stale receipts can no longer be consumed because
/// the window/receipt/owner triple must match the current slot exactly.
final class OtaWindowCreditLedger {
    private struct Slot {
        let registration: OtaWindowCreditRegistration
        var submitted = false
        var receipt: OtaWindowCreditReceipt?
        var notificationAt: TimeInterval?
        var consumed = false
    }

    private var slot: Slot?
    private var lastWindowId: String?
    private let makeReceiptId: () -> String

    init(makeReceiptId: @escaping () -> String = { UUID().uuidString }) {
        self.makeReceiptId = makeReceiptId
    }

    @discardableResult
    func register(_ registration: OtaWindowCreditRegistration) -> Bool {
        guard slot?.registration.windowId != registration.windowId,
              lastWindowId != registration.windowId else {
            return false
        }
        slot = Slot(registration: registration)
        return true
    }

    func markSubmitted(windowId: String, owner: OtaWindowCreditOwner) {
        guard var current = slot,
              current.registration.windowId == windowId,
              current.registration.owner == owner,
              !current.consumed else {
            return
        }
        current.submitted = true
        slot = current
    }

    func noteNotification(
        data: Data,
        owner: OtaWindowCreditOwner,
        monotonicNow: TimeInterval
    ) -> OtaWindowCreditReceipt? {
        guard monotonicNow.isFinite,
              var current = slot,
              current.submitted,
              !current.consumed,
              current.receipt == nil,
              current.registration.owner == owner,
              current.registration.expectedAck == data else {
            return nil
        }
        let receipt = OtaWindowCreditReceipt(
            windowId: current.registration.windowId,
            receiptId: makeReceiptId()
        )
        current.receipt = receipt
        current.notificationAt = monotonicNow
        slot = current
        return receipt
    }

    func consume(
        windowId: String,
        receiptId: String,
        owner: OtaWindowCreditOwner,
        monotonicNow: TimeInterval
    ) -> OtaWindowCreditConsumeResult? {
        guard monotonicNow.isFinite,
              var current = slot,
              !current.consumed,
              current.registration.windowId == windowId,
              current.registration.owner == owner,
              current.receipt?.receiptId == receiptId,
              let notificationAt = current.notificationAt else {
            return nil
        }
        current.consumed = true
        slot = current
        lastWindowId = current.registration.windowId
        let elapsedMs = Self.elapsedMilliseconds(from: notificationAt, to: monotonicNow)
        return OtaWindowCreditConsumeResult(
            notificationAtMonotonic: notificationAt,
            nativeNotifyToCreditMs: elapsedMs
        )
    }

    @discardableResult
    func invalidate(windowId: String, owner: OtaWindowCreditOwner) -> Bool {
        guard let current = slot,
              current.registration.windowId == windowId,
              current.registration.owner == owner else {
            return false
        }
        lastWindowId = current.registration.windowId
        slot = nil
        return true
    }

    func invalidate() {
        slot = nil
    }

    /// Clamp clock deltas before converting to Int so malformed virtual clocks
    /// fail closed instead of trapping or producing negative timing metrics.
    static func elapsedMilliseconds(from start: TimeInterval, to end: TimeInterval) -> Int {
        let elapsedSeconds = end - start
        if !elapsedSeconds.isFinite {
            return end > start ? Int.max : 0
        }
        guard elapsedSeconds > 0 else {
            return 0
        }
        let elapsedMs = elapsedSeconds * 1_000
        guard elapsedMs.isFinite else {
            return Int.max
        }
        if elapsedMs >= Double(Int.max) {
            return Int.max
        }
        return Int(elapsedMs)
    }
}
