import Foundation

/// Runs the query on the central manager's existing queue only when its host
/// lifecycle and transport permit synchronous XPC. Denial is a deferred lookup,
/// not evidence that the requested peripheral is missing.
enum BleSynchronousCoreBluetoothLookup {
    /// Share the exact predicate with activation and failure-defer decisions.
    static func isAllowed(isAppActive: Bool, isBluetoothPoweredOn: Bool) -> Bool {
        isAppActive && isBluetoothPoweredOn
    }

    /// Keep the query closure lazy so unavailable paths never enter CoreBluetooth
    /// synchronous XPC; retain the caller's existing queue and ownership domain.
    static func retrieve<Peripheral>(
        isAppActive: Bool,
        isBluetoothPoweredOn: Bool,
        query: () -> [Peripheral],
        onDeferred: () -> Void = {}
    ) -> [Peripheral] {
        guard isAllowed(
            isAppActive: isAppActive,
            isBluetoothPoweredOn: isBluetoothPoweredOn
        ) else {
            onDeferred()
            return []
        }
        return query()
    }
}
