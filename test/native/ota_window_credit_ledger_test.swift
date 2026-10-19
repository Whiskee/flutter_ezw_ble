import Foundation

@main
struct OtaWindowCreditLedgerTests {
    static func main() throws {
        try rejectsMalformedOwnersAndRegistrations()
        try requiresFullSubmissionBeforeReceipt()
        try rejectsWrongWireAndWrongOwner()
        try rejectsEveryOwnerFieldMismatch()
        try consumesReceiptOnceWithTiming()
        try clampsMalformedClockDeltas()
        try newRegistrationInvalidatesStaleReceipt()
        try oldFailureCannotInvalidateNewRegistration()
        try invalidateDropsOutstandingReceipt()
        print("OTA window credit ledger tests passed")
    }

    private static let ack = Data([0xAA, 0x12, 0x07, 0x04, 0x01, 0x01, 0xC1, 0x00, 0x02, 0x00, 0x6D, 0x7B])

    private static func owner(
        uuid: String = "left",
        sessionGeneration: Int64 = 10,
        attemptGeneration: Int64 = 20,
        transactionId: String = "tx",
        otaGeneration: Int64 = 30,
        instanceId: String = "instance"
    ) -> OtaWindowCreditOwner {
        guard let owner = OtaWindowCreditOwner(
            uuid: uuid,
            sessionGeneration: sessionGeneration,
            attemptGeneration: attemptGeneration,
            transactionId: transactionId,
            otaGeneration: otaGeneration,
            instanceId: instanceId
        ) else {
            fatalError("fixture owner should be valid")
        }
        return owner
    }

    private static func registration(
        windowId: String = "window-1",
        expectedAck: Data = ack,
        owner: OtaWindowCreditOwner = owner()
    ) -> OtaWindowCreditRegistration {
        guard let registration = OtaWindowCreditRegistration(
            windowId: windowId,
            expectedAck: expectedAck,
            owner: owner
        ) else {
            fatalError("fixture registration should be valid")
        }
        return registration
    }

    private static func rejectsMalformedOwnersAndRegistrations() throws {
        try assert(
            OtaWindowCreditOwner(
                uuid: "",
                sessionGeneration: 1,
                attemptGeneration: 1,
                transactionId: "tx",
                otaGeneration: 1,
                instanceId: "i"
            ) == nil,
            "empty uuid owner must be rejected"
        )
        try assert(
            OtaWindowCreditOwner(
                uuid: "left",
                sessionGeneration: 0,
                attemptGeneration: 1,
                transactionId: "tx",
                otaGeneration: 1,
                instanceId: "i"
            ) == nil,
            "zero session owner must be rejected"
        )
        try assert(
            OtaWindowCreditRegistration(windowId: "", expectedAck: ack, owner: owner()) == nil,
            "empty window id must be rejected"
        )
        try assert(
            OtaWindowCreditRegistration(
                windowId: String(repeating: "x", count: 129),
                expectedAck: ack,
                owner: owner()
            ) == nil,
            "oversized window id must be rejected"
        )
        try assert(
            OtaWindowCreditRegistration(windowId: "w", expectedAck: Data(), owner: owner()) == nil,
            "empty expected ACK must be rejected"
        )
        try assert(
            OtaWindowCreditRegistration(windowId: "w", expectedAck: Data([0xAA, 0x12]), owner: owner()) == nil,
            "non-canonical expected ACK must be rejected"
        )
    }

    private static func requiresFullSubmissionBeforeReceipt() throws {
        let ledger = OtaWindowCreditLedger(makeReceiptId: { "r1" })
        let owner = owner()
        ledger.register(registration(owner: owner))

        try assert(
            ledger.noteNotification(data: ack, owner: owner, monotonicNow: 1) == nil,
            "receipt must wait until the full RAW batch is submitted"
        )
        ledger.markSubmitted(windowId: "window-1", owner: owner)
        try assert(
            ledger.noteNotification(data: ack, owner: owner, monotonicNow: 2)?.receiptId == "r1",
            "receipt should be issued after exact ACK and submission"
        )
    }

    private static func rejectsWrongWireAndWrongOwner() throws {
        let ledger = OtaWindowCreditLedger(makeReceiptId: { "r1" })
        let owner = owner()
        ledger.register(registration(owner: owner))
        ledger.markSubmitted(windowId: "window-1", owner: owner)

        try assert(
            ledger.noteNotification(data: Data([0xAA, 0x12]), owner: owner, monotonicNow: 1) == nil,
            "partial ACK must be rejected"
        )
        var wrongAck = ack
        wrongAck[2] = 0x08
        try assert(
            ledger.noteNotification(data: wrongAck, owner: owner, monotonicNow: 1) == nil,
            "wrong sync ACK must be rejected"
        )
        try assert(
            ledger.noteNotification(data: ack, owner: Self.owner(uuid: "right"), monotonicNow: 1) == nil,
            "wrong owner ACK must be rejected"
        )
    }

    private static func rejectsEveryOwnerFieldMismatch() throws {
        let correctOwner = owner()
        let mismatchedOwners: [(label: String, owner: OtaWindowCreditOwner)] = [
            ("uuid", owner(uuid: "right")),
            ("session", owner(sessionGeneration: 11)),
            ("attempt", owner(attemptGeneration: 21)),
            ("transactionId", owner(transactionId: "tx-other")),
            ("otaGeneration", owner(otaGeneration: 31)),
            ("instanceId", owner(instanceId: "instance-other")),
        ]

        for mismatch in mismatchedOwners {
            let notificationLedger = OtaWindowCreditLedger(makeReceiptId: { "receipt-\(mismatch.label)-notify" })
            notificationLedger.register(registration(owner: correctOwner))
            notificationLedger.markSubmitted(windowId: "window-1", owner: correctOwner)
            try assert(
                notificationLedger.noteNotification(data: ack, owner: mismatch.owner, monotonicNow: 1) == nil,
                "mismatched \(mismatch.label) must not sign a receipt"
            )
            let receiptAfterMismatch = try require(
                notificationLedger.noteNotification(data: ack, owner: correctOwner, monotonicNow: 2),
                "correct owner should still sign after mismatched \(mismatch.label)"
            )
            let timingAfterMismatch = try require(
                notificationLedger.consume(
                    windowId: receiptAfterMismatch.windowId,
                    receiptId: receiptAfterMismatch.receiptId,
                    owner: correctOwner,
                    monotonicNow: 2.010
                ),
                "correct owner should consume after mismatched \(mismatch.label) notification"
            )
            try assert(
                timingAfterMismatch.nativeNotifyToCreditMs == 9 || timingAfterMismatch.nativeNotifyToCreditMs == 10,
                "correct owner consume should keep a bounded timing after \(mismatch.label) mismatch"
            )

            let consumeLedger = OtaWindowCreditLedger(makeReceiptId: { "receipt-\(mismatch.label)-consume" })
            consumeLedger.register(registration(owner: correctOwner))
            consumeLedger.markSubmitted(windowId: "window-1", owner: correctOwner)
            let receipt = try require(
                consumeLedger.noteNotification(data: ack, owner: correctOwner, monotonicNow: 3),
                "expected correct receipt before mismatched \(mismatch.label) consume"
            )
            try assert(
                consumeLedger.consume(
                    windowId: receipt.windowId,
                    receiptId: receipt.receiptId,
                    owner: mismatch.owner,
                    monotonicNow: 4
                ) == nil,
                "mismatched \(mismatch.label) must not consume the receipt"
            )
            let timing = try require(
                consumeLedger.consume(
                    windowId: receipt.windowId,
                    receiptId: receipt.receiptId,
                    owner: correctOwner,
                    monotonicNow: 4
                ),
                "correct owner should still consume once after mismatched \(mismatch.label)"
            )
            try assert(timing.nativeNotifyToCreditMs == 1_000, "correct consume timing should be preserved after \(mismatch.label) mismatch")
            try assert(
                consumeLedger.consume(
                    windowId: receipt.windowId,
                    receiptId: receipt.receiptId,
                    owner: correctOwner,
                    monotonicNow: 5
                ) == nil,
                "receipt should remain once-only after correct consume for \(mismatch.label)"
            )
        }
    }

    private static func consumesReceiptOnceWithTiming() throws {
        let ledger = OtaWindowCreditLedger(makeReceiptId: { "receipt-1" })
        let owner = owner()
        ledger.register(registration(owner: owner))
        ledger.markSubmitted(windowId: "window-1", owner: owner)
        let receipt = try require(
            ledger.noteNotification(data: ack, owner: owner, monotonicNow: 100.100),
            "expected receipt"
        )

        let timing = try require(
            ledger.consume(
                windowId: receipt.windowId,
                receiptId: receipt.receiptId,
                owner: owner,
                monotonicNow: 100.132
            ),
            "expected consume"
        )
        try assert(timing.nativeNotifyToCreditMs == 32, "expected32ms notify-to-credit admission timing")
        try assert(timing.nativeNotifyToCreditMs == 32, "expected same native boundary timing")
        try assert(
            ledger.consume(
                windowId: receipt.windowId,
                receiptId: receipt.receiptId,
                owner: owner,
                monotonicNow: 101
            ) == nil,
            "receipt must be consumed once"
        )
    }

    private static func clampsMalformedClockDeltas() throws {
        let negativeLedger = OtaWindowCreditLedger(makeReceiptId: { "negative" })
        let owner = owner()
        negativeLedger.register(registration(owner: owner))
        negativeLedger.markSubmitted(windowId: "window-1", owner: owner)
        let negativeReceipt = try require(
            negativeLedger.noteNotification(data: ack, owner: owner, monotonicNow: 10),
            "expected negative fixture receipt"
        )
        let negativeTiming = try require(
            negativeLedger.consume(
                windowId: negativeReceipt.windowId,
                receiptId: negativeReceipt.receiptId,
                owner: owner,
                monotonicNow: 9
            ),
            "negative clock deltas should still consume safely"
        )
        try assert(negativeTiming.nativeNotifyToCreditMs == 0, "negative deltas should clamp to zero")

        let overflowLedger = OtaWindowCreditLedger(makeReceiptId: { "overflow" })
        overflowLedger.register(registration(owner: owner))
        overflowLedger.markSubmitted(windowId: "window-1", owner: owner)
        let overflowReceipt = try require(
            overflowLedger.noteNotification(data: ack, owner: owner, monotonicNow: -Double.greatestFiniteMagnitude),
            "expected overflow fixture receipt"
        )
        let overflowTiming = try require(
            overflowLedger.consume(
                windowId: overflowReceipt.windowId,
                receiptId: overflowReceipt.receiptId,
                owner: owner,
                monotonicNow: Double.greatestFiniteMagnitude
            ),
            "overflow clock deltas should still consume safely"
        )
        try assert(overflowTiming.nativeNotifyToCreditMs == Int.max, "overflow deltas should clamp to Int.max")

        let nanLedger = OtaWindowCreditLedger(makeReceiptId: { "nan" })
        nanLedger.register(registration(owner: owner))
        nanLedger.markSubmitted(windowId: "window-1", owner: owner)
        try assert(
            nanLedger.noteNotification(data: ack, owner: owner, monotonicNow: .nan) == nil,
            "non-finite notification clocks must fail closed"
        )
    }

    private static func newRegistrationInvalidatesStaleReceipt() throws {
        let ledger = OtaWindowCreditLedger(makeReceiptId: { "receipt-1" })
        let owner = owner()
        ledger.register(registration(owner: owner))
        ledger.markSubmitted(windowId: "window-1", owner: owner)
        let stale = try require(
            ledger.noteNotification(data: ack, owner: owner, monotonicNow: 1),
            "expected stale receipt"
        )
        ledger.register(registration(windowId: "window-2", owner: owner))
        try assert(
            !ledger.register(registration(windowId: "window-2", owner: owner)),
            "same active window id must be rejected"
        )

        try assert(
            ledger.consume(
                windowId: stale.windowId,
                receiptId: stale.receiptId,
                owner: owner,
                monotonicNow: 2
            ) == nil,
            "new window registration must invalidate stale receipt"
        )
    }

    private static func invalidateDropsOutstandingReceipt() throws {
        let ledger = OtaWindowCreditLedger(makeReceiptId: { "receipt-1" })
        let owner = owner()
        ledger.register(registration(owner: owner))
        ledger.markSubmitted(windowId: "window-1", owner: owner)
        let receipt = try require(
            ledger.noteNotification(data: ack, owner: owner, monotonicNow: 1),
            "expected receipt"
        )
        ledger.invalidate()
        try assert(
            ledger.consume(
                windowId: receipt.windowId,
                receiptId: receipt.receiptId,
                owner: owner,
                monotonicNow: 2
            ) == nil,
            "invalidate must drop receipt"
        )
    }

    private static func oldFailureCannotInvalidateNewRegistration() throws {
        let ledger = OtaWindowCreditLedger(makeReceiptId: { "receipt-new" })
        let owner = owner()
        ledger.register(registration(windowId: "old", owner: owner))
        try assert(
            ledger.register(registration(windowId: "new", owner: owner)),
            "new registration should replace old unconsumed window"
        )
        try assert(
            !ledger.invalidate(windowId: "old", owner: owner),
            "old failed window must not invalidate current registration"
        )
        ledger.markSubmitted(windowId: "new", owner: owner)
        try assert(
            ledger.noteNotification(data: ack, owner: owner, monotonicNow: 3)?.windowId == "new",
            "current registration must remain valid after old failure"
        )
    }

    private static func assert(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() {
            throw NSError(domain: "OtaWindowCreditLedgerTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    private static func require<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else {
            throw NSError(domain: "OtaWindowCreditLedgerTests", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
        }
        return value
    }
}
