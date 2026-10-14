import Foundation

/// Native receive provenance sent with EventChannel notify payloads.
///
/// The outer `sessionGeneration` / `attemptGeneration` fields remain for
/// legacy OTA consumers. This nested identity is the callback-scoped proof that
/// Dart must use for ordinary AUTH/notify acceptance.
struct BleReceiveIdentity: Codable, Equatable {
    let uuid: String
    let sessionGeneration: Int64
    let attemptGeneration: Int64

    func toMap() -> [String: Any] {
        [
            "uuid": uuid,
            "sessionGeneration": sessionGeneration,
            "attemptGeneration": attemptGeneration
        ]
    }
}

/// Fail-closed policy for freezing iOS notify provenance before EventChannel emit.
///
/// CoreBluetooth does not expose a per-notification GATT handle token. The best
/// available native boundary is therefore the current CBPeripheral object,
/// connected state, cached read-characteristic object, and either the active
/// Gate admission or the last accepted business connection pair.
enum BleReceiveIdentityPolicy {
    static func currentAdmissionIdentity(
        uuid: String,
        sessionGeneration: Int64,
        attemptGeneration: Int64,
        isCurrentPipeline: Bool,
        isPeripheralConnected: Bool,
        isCachedReadCharacteristic: Bool
    ) -> BleReceiveIdentity? {
        guard isCurrentPipeline,
              isPeripheralConnected,
              isCachedReadCharacteristic,
              sessionGeneration > 0,
              attemptGeneration > 0 else {
            return nil
        }
        return BleReceiveIdentity(
            uuid: uuid,
            sessionGeneration: sessionGeneration,
            attemptGeneration: attemptGeneration
        )
    }

    static func acceptedConnectionIdentity(
        uuid: String,
        sessionGeneration: Int64,
        attemptGeneration: Int64,
        isPeripheralConnected: Bool,
        isBusinessConnected: Bool,
        isUpgradeActive: Bool,
        isCachedReadCharacteristic: Bool
    ) -> BleReceiveIdentity? {
        guard isPeripheralConnected,
              (isBusinessConnected || isUpgradeActive),
              isCachedReadCharacteristic,
              sessionGeneration > 0,
              attemptGeneration > 0 else {
            return nil
        }
        return BleReceiveIdentity(
            uuid: uuid,
            sessionGeneration: sessionGeneration,
            attemptGeneration: attemptGeneration
        )
    }
}
