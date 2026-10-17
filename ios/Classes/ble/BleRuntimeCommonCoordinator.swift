import CoreBluetooth
import Foundation
import Flutter

extension BleManager {
    /// Read only successful reconnect-owner metadata. A new/pending admission,
    /// an OTA transaction or a cache-only connected flag is insufficient.
    func getRuntimeCommonOwner(uuid: String) -> [String: Any]? {
        guard let snapshot = runtimeCommonSnapshot(uuid: uuid) else { return nil }
        return ["uuid": snapshot.identity.uuid,
                "sessionGeneration": snapshot.identity.sessionGeneration,
                "attemptGeneration": snapshot.identity.attemptGeneration]
    }

    /// Validate both generations and the current objects on every async submit.
    /// The lane itself fences common writes before it invokes CoreBluetooth.
    func setRuntimeCommonNotifications(uuid: String, sessionGeneration: Int64,
        attemptGeneration: Int64, revision: Int64, enabled: Bool,
        result: @escaping FlutterResult) {
        guard let snapshot = runtimeCommonSnapshot(uuid: uuid) else {
            result(BleRuntimeCommonResult(status: "notConnected", enabled: nil, revision: revision).raw)
            return
        }
        let identity = snapshot.identity
        guard identity.sessionGeneration == sessionGeneration,
              identity.attemptGeneration == attemptGeneration,
              sessionGeneration > 0, attemptGeneration > 0, revision > 0 else {
            result(BleRuntimeCommonResult(status: "stale", enabled: nil, revision: revision).raw)
            return
        }
        let peripheral = snapshot.device.peripheral
        let characteristic = snapshot.characteristic
        runtimeCommonNotifications.request(identity: identity, revision: revision,
            enabled: enabled, physicalState: characteristic.isNotifying,
            submit: { [weak self, weak peripheral, weak characteristic] value in
                guard let self, let peripheral, let characteristic,
                      let current = self.runtimeCommonSnapshot(uuid: identity.uuid),
                      current.identity == identity else { return false }
                peripheral.setNotifyValue(value, for: characteristic)
                self.loggerD(msg: "runtime common submit uuid=\(identity.uuid) revision=\(revision) enabled=\(value) session=\(sessionGeneration) attempt=\(attemptGeneration)")
                return true
            }, completion: { [weak self] confirmation in
                self?.loggerD(msg: "runtime common result uuid=\(identity.uuid) revision=\(confirmation.revision) status=\(confirmation.status) enabled=\(String(describing: confirmation.enabled))")
                result(confirmation.raw)
            })
    }

    /// Permanently missing CCCD callbacks have a bounded exit: once per exact
    /// physical lane request a real cancel, preserving the existing reconnect
    /// owner. Only didDisconnect releases the old lane; no fake state or OTA
    /// marker/queue mutation is allowed here.
    func disconnectForRuntimeNotificationRecovery(uuid: String, sessionGeneration: Int64,
        attemptGeneration: Int64, revision: Int64) -> [String: Any] {
        guard let snapshot = runtimeCommonSnapshot(uuid: uuid) else {
            return BleRuntimeCommonResult(status: "unavailable", enabled: nil, revision: revision).raw
        }
        guard snapshot.identity.sessionGeneration == sessionGeneration,
              snapshot.identity.attemptGeneration == attemptGeneration,
              sessionGeneration > 0, attemptGeneration > 0 else {
            return BleRuntimeCommonResult(status: "stale", enabled: nil, revision: revision).raw
        }
        return runtimeCommonNotifications.requestRecovery(identity: snapshot.identity, revision: revision) {
            centralManager.cancelPeripheralConnection(snapshot.device.peripheral)
        }.raw
    }

    /// Used only at actual common writeValue edges. During a new initialization
    /// admission its positive pair supersedes the old lane, so AUTH is unblocked.
    func runtimeCommonWriteError(uuid: String, psType: Int, device: BleConnectedDevice) -> FlutterError? {
        guard psType == 0 else { return nil }
        let admission = currentConnectionAdmission(uuid: uuid)
        let task = reconnectTasks.values.first { $0.uuid.caseInsensitiveCompare(uuid) == .orderedSame }
        let metadata = BleExplicitCancellationMetadataPolicy.resolve(currentAdmission: admission, reconnectTask: task)
        guard runtimeCommonNotifications.blocksWrite(uuid: uuid,
            sessionGeneration: metadata?.sessionGeneration ?? 0,
            attemptGeneration: metadata?.attemptGeneration ?? 0,
            peripheralId: ObjectIdentifier(device.peripheral)) else { return nil }
        return FlutterError(code: "COMMON_NOT_READY",
            message: "Runtime common notification is paused or unconfirmed",
            details: ["uuid": uuid, "psType": psType])
    }

    func runtimeCommonSnapshot(uuid: String) ->
        (identity: BleRuntimeCommonIdentity, device: BleConnectedDevice, characteristic: CBCharacteristic)? {
        guard checkIsFunctionCanBeCalled(),
              !upgradeStateRegistry.contains(uuid),
              g2OtaTransactions.shouldAllowLegacyCleanup(endpointId: uuid),
              currentConnectionAdmission(uuid: uuid) == nil,
              let device = connectedDevices.first(where: { $0.peripheral.identifier.uuidString == uuid }),
              device.isConnected, device.isBleFlowCompleted, device.peripheral.state == .connected,
              let characteristic = device.readCharsDic[0], device.writeCharsDic[0] != nil,
              let task = reconnectTasks.values.first(where: { $0.uuid.caseInsensitiveCompare(uuid) == .orderedSame }),
              let session = task.lastConnectedGeneration, session > 0,
              task.sessionGeneration == session,
              let attempt = task.lastConnectedAttemptGeneration, attempt > 0 else { return nil }
        let identity = BleRuntimeCommonIdentity(uuid: device.peripheral.identifier.uuidString,
            sessionGeneration: session, attemptGeneration: attempt,
            peripheralId: ObjectIdentifier(device.peripheral),
            characteristicId: ObjectIdentifier(characteristic))
        return (identity, device, characteristic)
    }
}
