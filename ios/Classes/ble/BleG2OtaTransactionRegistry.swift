//
//  BleG2OtaTransactionRegistry.swift
//  flutter_ezw_ble
//
//  Native ownership ledger for one G2 OTA transaction.  The registry is pure
//  state so XCTest can lock the race rules without mocking CoreBluetooth.
//

import Foundation

struct BleG2OtaEndpoint: Equatable {
    let uuid: String
    let name: String
    let sessionGeneration: Int64
    let attemptGeneration: Int64

    init?(data: [String: Any]) {
        let uuid = (data["uuid"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !uuid.isEmpty else { return nil }
        self.uuid = uuid
        self.name = data["name"] as? String ?? ""
        guard let sessionGeneration = BleG2OtaInteger.parseRequired(data["sessionGeneration"]),
              let attemptGeneration = BleG2OtaInteger.parseRequired(data["attemptGeneration"]),
              sessionGeneration >= 0,
              attemptGeneration >= 0,
              (sessionGeneration == 0) == (attemptGeneration == 0) else {
            return nil
        }
        self.sessionGeneration = sessionGeneration
        self.attemptGeneration = attemptGeneration
    }

    var key: String { uuid.lowercased() }
}

struct BleG2OtaTransactionScope: Equatable {
    let transactionId: String
    let generation: Int64
    let config: String
    let sn: String
    let endpoints: [BleG2OtaEndpoint]

    init?(data: [String: Any]) {
        let transactionId = (data["transactionId"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let generation = BleG2OtaInteger.parseOptional(data["generation"]) ?? 0
        let config = (data["config"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let sn = (data["sn"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let endpointData = data["endpoints"] as? [[String: Any]] ?? []
        let endpoints = endpointData.compactMap(BleG2OtaEndpoint.init(data:))
        let uniqueEndpointCount = Set(endpoints.map(\.key)).count
        guard !transactionId.isEmpty,
              generation > 0,
              !config.isEmpty,
              !sn.isEmpty,
              !endpoints.isEmpty,
              endpoints.count == endpointData.count,
              uniqueEndpointCount == endpoints.count else {
            return nil
        }
        self.transactionId = transactionId
        self.generation = generation
        self.config = config
        self.sn = sn
        self.endpoints = endpoints
    }

    func matchesRequest(data: [String: Any]) -> Bool {
        BleG2OtaTransactionScope(data: data) == self
    }
}

struct BleG2OtaContext: Equatable {
    let transactionId: String
    let generation: Int64
    let instanceId: String

    init(transactionId: String, generation: Int64, instanceId: String) {
        self.transactionId = transactionId
        self.generation = generation
        self.instanceId = instanceId
    }

    init?(data: [String: Any]?) {
        guard let data else { return nil }
        let transactionId = (data["transactionId"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let generation = BleG2OtaInteger.parseOptional(data["generation"]) ?? 0
        let instanceId = (data["instanceId"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transactionId.isEmpty, generation > 0, !instanceId.isEmpty else { return nil }
        self.transactionId = transactionId
        self.generation = generation
        self.instanceId = instanceId
    }
}

enum BleG2OtaEndpointPhase: String {
    case waiting
    case active
    case recovering
    case parked
    case retiring
    case retired
}

enum BleG2OtaUpdateAction: String {
    case bind
    case recover
    case park
}

enum BleG2OtaAdmissionPurpose {
    case activation
    case write
}

enum BleG2OtaFinishReason: String {
    case success
    case failed
    case cancelled
    case revoked
}

enum BleG2OtaTransactionStatus: String {
    case accepted
    case committed
    case alreadyCommitted
    case active
    case staleOwner
    case invalidRequest
    case unavailable
    case unknown
    case invalidated
    case revoked
}

struct BleG2OtaTransactionResult: Equatable {
    let status: BleG2OtaTransactionStatus
    let transactionId: String
    let generation: Int64
    let instanceId: String
    let reason: String?

    var raw: [String: Any] {
        var value: [String: Any] = [
            "status": status.rawValue,
            "transactionId": transactionId,
            "generation": generation,
            "instanceId": instanceId
        ]
        if let reason {
            value["reason"] = reason
        }
        return value
    }
}

struct BleG2OtaEndpointSnapshot: Equatable {
    let uuid: String
    let name: String
    let sessionGeneration: Int64
    let attemptGeneration: Int64
    let hasBoundPhysicalPair: Bool
    let phase: BleG2OtaEndpointPhase
}

struct BleG2OtaNativeEndpointState: Equatable {
    let uuid: String
    let name: String
    let belongConfig: String
    let isNativeKnown: Bool
    let isBusinessConnected: Bool
    let isPeripheralConnected: Bool
    let sessionGeneration: Int64
    let attemptGeneration: Int64
}

enum BleG2OtaNativeBeginPolicy {
    static func rejectionReason(
        scope: BleG2OtaTransactionScope,
        states: [String: BleG2OtaNativeEndpointState]
    ) -> String? {
        for endpoint in scope.endpoints {
            guard let state = states[endpoint.key],
                  state.belongConfig == scope.config,
                  state.isNativeKnown else {
                return "nativeEndpointUnknown"
            }
            if endpoint.sessionGeneration == 0 && endpoint.attemptGeneration == 0 {
                // Waiting endpoints are allowed to be registered before their
                // physical pair exists.  They still need a native-known target
                // so Dart cannot invent a peer outside the configured device.
                continue
            }
            guard endpoint.sessionGeneration > 0,
                  endpoint.attemptGeneration > 0,
                  state.isBusinessConnected,
                  state.isPeripheralConnected,
                  state.sessionGeneration == endpoint.sessionGeneration,
                  state.attemptGeneration == endpoint.attemptGeneration else {
                return "nativePhysicalOwnerMismatch"
            }
        }
        return nil
    }
}

enum BleG2OtaConfigPolicy {
    private static let g2OtaServiceUUID = "00002760-08C2-11E1-9073-0E8AC72E1001"

    /// G2 OTA transactions are admitted only for the production OTA private
    /// service.  The Dart config string is not an authority boundary.
    static func supportsG2Ota(privateServices: [(type: Int, service: String)]) -> Bool {
        privateServices.contains { privateService in
            privateService.type == 1 &&
                privateService.service.uppercased() == g2OtaServiceUUID
        }
    }
}

struct BleG2OtaRetirementEndpointState: Equatable {
    let uuid: String
    let hasConnectedCache: Bool
    let isPeripheralConnected: Bool
    let sessionGeneration: Int64
    let attemptGeneration: Int64
}

struct BleG2OtaRetirementDecision: Equatable {
    let shouldClearLocalState: Bool
    let shouldIsolateCache: Bool
    let shouldInstallCancellationBarrier: Bool
    let shouldCancelPeripheral: Bool
}

enum BleG2OtaRetirementPolicy {
    static func decide(
        snapshot: BleG2OtaEndpointSnapshot?,
        state: BleG2OtaRetirementEndpointState
    ) -> BleG2OtaRetirementDecision {
        guard state.hasConnectedCache else {
            return BleG2OtaRetirementDecision(
                shouldClearLocalState: snapshot != nil,
                shouldIsolateCache: false,
                shouldInstallCancellationBarrier: false,
                shouldCancelPeripheral: false
            )
        }
        let exactBoundPair =
            snapshot != nil &&
            snapshot?.hasBoundPhysicalPair == true &&
            snapshot?.sessionGeneration == state.sessionGeneration &&
            snapshot?.attemptGeneration == state.attemptGeneration &&
            state.sessionGeneration > 0 &&
            state.attemptGeneration > 0
        guard exactBoundPair else {
            return BleG2OtaRetirementDecision(
                shouldClearLocalState: false,
                shouldIsolateCache: false,
                shouldInstallCancellationBarrier: false,
                shouldCancelPeripheral: false
            )
        }
        return BleG2OtaRetirementDecision(
            shouldClearLocalState: true,
            shouldIsolateCache: true,
            shouldInstallCancellationBarrier: state.isPeripheralConnected,
            shouldCancelPeripheral: state.isPeripheralConnected
        )
    }
}

private struct BleG2OtaEndpointLease: Equatable {
    let uuid: String
    let name: String
    var sessionGeneration: Int64
    var attemptGeneration: Int64
    var hasBoundPhysicalPair: Bool
    var phase: BleG2OtaEndpointPhase
}

private struct BleG2OtaTransactionRecord: Equatable {
    let scope: BleG2OtaTransactionScope
    let instanceId: String
    var endpoints: [String: BleG2OtaEndpointLease]
}

private struct BleG2OtaTerminalRecord: Equatable {
    let scope: BleG2OtaTransactionScope
    let instanceId: String
    let reason: BleG2OtaFinishReason
    let revoked: Bool
}

/**
 * G2 OTA transaction authority lives below Dart.  Dart IDs describe the user
 * transaction, but the native instance nonce decides whether a late ACK or old
 * cleanup call still has authority over current native resources.
 */
final class BleG2OtaTransactionRegistry {
    let nativeInstanceId: String
    private var activeRecords: [String: BleG2OtaTransactionRecord] = [:]
    private var terminalRecords: [String: BleG2OtaTerminalRecord] = [:]

    init(nativeInstanceId: String = UUID().uuidString) {
        self.nativeInstanceId = nativeInstanceId
    }

    @discardableResult
    func begin(data: [String: Any]) -> BleG2OtaTransactionResult {
        guard let scope = BleG2OtaTransactionScope(data: data) else {
            return result(.invalidRequest, data: data, reason: "invalidBeginRequest")
        }
        if let terminal = terminalRecords[scope.transactionId] {
            guard terminal.scope == scope else {
                return result(.invalidRequest, scope: scope, reason: "terminalScopeMismatch")
            }
            return result(
                terminal.revoked ? .revoked : .alreadyCommitted,
                transactionId: scope.transactionId,
                generation: scope.generation,
                instanceId: terminal.instanceId,
                reason: terminal.reason.rawValue
            )
        }
        if let active = activeRecords[scope.transactionId] {
            guard active.scope == scope else {
                return result(.invalidRequest, scope: scope, reason: "beginConflict")
            }
            return result(.accepted, scope: scope, instanceId: active.instanceId)
        }
        guard !hasEndpointOverlap(scope) else {
            return result(.invalidRequest, scope: scope, reason: "endpointAlreadyOwned")
        }
        let leases = Dictionary(uniqueKeysWithValues: scope.endpoints.map { endpoint in
            (
                endpoint.key,
                BleG2OtaEndpointLease(
                    uuid: endpoint.uuid,
                    name: endpoint.name,
                    sessionGeneration: endpoint.sessionGeneration,
                    attemptGeneration: endpoint.attemptGeneration,
                    hasBoundPhysicalPair: endpoint.sessionGeneration > 0 && endpoint.attemptGeneration > 0,
                    phase: .waiting
                )
            )
        })
        activeRecords[scope.transactionId] = BleG2OtaTransactionRecord(
            scope: scope,
            instanceId: nativeInstanceId,
            endpoints: leases
        )
        return result(.accepted, scope: scope, instanceId: nativeInstanceId)
    }

    @discardableResult
    func update(data: [String: Any]) -> BleG2OtaTransactionResult {
        guard let context = context(from: data),
              let action = BleG2OtaUpdateAction(rawValue: data["action"] as? String ?? ""),
              let uuid = endpointKey(from: data) else {
            return result(.invalidRequest, data: data, reason: "invalidUpdateRequest")
        }
        guard var record = activeRecords[context.transactionId],
              record.scope.generation == context.generation else {
            return result(.unavailable, context: context, reason: "missingTransaction")
        }
        guard record.instanceId == context.instanceId else {
            return result(.staleOwner, context: context, reason: "instanceMismatch")
        }
        guard var endpoint = record.endpoints[uuid] else {
            return result(.invalidRequest, context: context, reason: "endpointNotInTransaction")
        }
        guard let sessionGeneration = BleG2OtaInteger.parseRequired(data["sessionGeneration"]),
              let attemptGeneration = BleG2OtaInteger.parseRequired(data["attemptGeneration"]),
              sessionGeneration >= 0,
              attemptGeneration >= 0,
              (sessionGeneration == 0) == (attemptGeneration == 0) else {
            return result(.invalidRequest, context: context, reason: "invalidPhysicalPair")
        }
        switch action {
        case .bind:
            guard sessionGeneration > 0, attemptGeneration > 0,
                  endpoint.phase == .waiting || endpoint.phase == .recovering || endpoint.phase == .active else {
                return result(.invalidRequest, context: context, reason: "invalidBindTransition")
            }
            endpoint.sessionGeneration = sessionGeneration
            endpoint.attemptGeneration = attemptGeneration
            endpoint.hasBoundPhysicalPair = true
            endpoint.phase = .active
        case .recover:
            if endpoint.hasBoundPhysicalPair {
                guard sessionGeneration > 0,
                      attemptGeneration > 0,
                      endpoint.phase == .waiting || endpoint.phase == .active || endpoint.phase == .recovering,
                      endpoint.sessionGeneration == sessionGeneration,
                      endpoint.attemptGeneration == attemptGeneration else {
                    return result(.staleOwner, context: context, reason: "recoverPhysicalMismatch")
                }
            } else {
                guard endpoint.phase == .waiting,
                      sessionGeneration == 0,
                      attemptGeneration == 0 else {
                    return result(.invalidRequest, context: context, reason: "recoverWithoutWaiting")
                }
            }
            endpoint.sessionGeneration = sessionGeneration
            endpoint.attemptGeneration = attemptGeneration
            endpoint.hasBoundPhysicalPair = sessionGeneration > 0 && attemptGeneration > 0
            endpoint.phase = .recovering
        case .park:
            guard sessionGeneration > 0,
                  attemptGeneration > 0,
                  endpoint.hasBoundPhysicalPair,
                  endpoint.phase == .active,
                  sessionGeneration == endpoint.sessionGeneration,
                  attemptGeneration == endpoint.attemptGeneration else {
                return result(.invalidRequest, context: context, reason: "invalidParkTransition")
            }
            endpoint.phase = .parked
        }
        record.endpoints[uuid] = endpoint
        activeRecords[context.transactionId] = record
        return result(.accepted, context: context, reason: action.rawValue)
    }

    @discardableResult
    func prepareFinish(data: [String: Any]) -> (result: BleG2OtaTransactionResult, endpointIds: [String]) {
        let transactionId = (data["transactionId"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let generation = BleG2OtaInteger.parseOptional(data["generation"]) ?? 0
        let requestedInstanceId = (data["instanceId"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let reason = BleG2OtaFinishReason(rawValue: data["reason"] as? String ?? "") else {
            return (result(.invalidRequest, data: data, reason: "invalidFinishReason"), [])
        }
        if let terminal = terminalRecords[transactionId] {
            guard terminal.scope.generation == generation,
                  terminal.scope.matchesRequest(data: data) else {
                return (result(.invalidRequest, data: data, reason: "terminalScopeMismatch"), [])
            }
            if !requestedInstanceId.isEmpty, requestedInstanceId != terminal.instanceId {
                return (result(
                    .staleOwner,
                    transactionId: transactionId,
                    generation: generation,
                    instanceId: requestedInstanceId,
                    reason: "instanceMismatch"
                ), [])
            }
            return (result(
                terminal.revoked ? .revoked : .alreadyCommitted,
                transactionId: transactionId,
                generation: generation,
                instanceId: terminal.instanceId,
                reason: terminal.reason.rawValue
            ), [])
        }
        if let record = activeRecords[transactionId] {
            guard record.scope.generation == generation,
                  record.scope.matchesRequest(data: data) else {
                return (result(.invalidRequest, data: data, reason: "finishScopeMismatch"), [])
            }
            if requestedInstanceId.isEmpty, reason == .cancelled {
                let endpointIds = markTransactionRetiring(transactionId: transactionId)
                return (result(.committed, scope: record.scope, instanceId: record.instanceId, reason: reason.rawValue), endpointIds)
            }
            guard !requestedInstanceId.isEmpty,
                  record.instanceId == requestedInstanceId else {
                return (result(
                    .staleOwner,
                    transactionId: transactionId,
                    generation: generation,
                    instanceId: requestedInstanceId,
                    reason: "instanceMismatch"
                ), [])
            }
            let endpointIds = markTransactionRetiring(transactionId: transactionId)
            return (result(.committed, scope: record.scope, instanceId: record.instanceId, reason: reason.rawValue), endpointIds)
        }
        guard reason == .cancelled,
              requestedInstanceId.isEmpty,
              let scope = BleG2OtaTransactionScope(data: data) else {
            return (result(.unavailable, data: data, reason: "missingTransaction"), [])
        }
        return (result(.committed, scope: scope, instanceId: nativeInstanceId, reason: reason.rawValue), [])
    }

    @discardableResult
    func commitPreparedFinish(data: [String: Any]) -> BleG2OtaTransactionResult {
        let prepared = prepareFinish(data: data)
        guard prepared.result.status == .committed,
              let reason = BleG2OtaFinishReason(rawValue: data["reason"] as? String ?? ""),
              let scope = BleG2OtaTransactionScope(data: data) else {
            return prepared.result
        }
        let instanceId = activeRecords[scope.transactionId]?.instanceId ?? prepared.result.instanceId
        terminalRecords[scope.transactionId] = BleG2OtaTerminalRecord(
            scope: scope,
            instanceId: instanceId,
            reason: reason,
            revoked: reason == .revoked
        )
        activeRecords.removeValue(forKey: scope.transactionId)
        return result(.committed, scope: scope, instanceId: instanceId, reason: reason.rawValue)
    }

    func query(data: [String: Any]) -> BleG2OtaTransactionResult {
        let transactionId = (data["transactionId"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let generation = BleG2OtaInteger.parseOptional(data["generation"]) ?? 0
        let instanceId = (data["instanceId"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transactionId.isEmpty, generation > 0 else {
            return result(.invalidRequest, data: data, reason: "invalidQueryRequest")
        }
        if let terminal = terminalRecords[transactionId] {
            guard terminal.scope.generation == generation else {
                return result(.invalidRequest, data: data, reason: "terminalGenerationMismatch")
            }
            if !instanceId.isEmpty, instanceId != terminal.instanceId {
                return result(.staleOwner, transactionId: transactionId, generation: generation, instanceId: instanceId, reason: "instanceMismatch")
            }
            return result(
                terminal.revoked ? .revoked : .alreadyCommitted,
                transactionId: transactionId,
                generation: generation,
                instanceId: terminal.instanceId,
                reason: terminal.reason.rawValue
            )
        }
        guard let record = activeRecords[transactionId],
              record.scope.generation == generation else {
            if !instanceId.isEmpty, instanceId != nativeInstanceId {
                return result(.invalidated, transactionId: transactionId, generation: generation, instanceId: instanceId, reason: "nativeInstanceRecreated")
            }
            return result(.unavailable, transactionId: transactionId, generation: generation, instanceId: instanceId, reason: "missingTransaction")
        }
        if !instanceId.isEmpty, instanceId != record.instanceId {
            return result(.staleOwner, transactionId: transactionId, generation: generation, instanceId: instanceId, reason: "instanceMismatch")
        }
        return result(.active, scope: record.scope, instanceId: record.instanceId)
    }

    func clearActive(reason: BleG2OtaFinishReason) -> [String] {
        let endpointIds = activeRecords.values.flatMap { record in
            record.endpoints.values.map(\.uuid)
        }
        for (_, record) in activeRecords {
            terminalRecords[record.scope.transactionId] = BleG2OtaTerminalRecord(
                scope: record.scope,
                instanceId: record.instanceId,
                reason: reason,
                revoked: reason == .revoked
            )
        }
        activeRecords.removeAll()
        return endpointIds
    }

    func revokeEndpoints(_ endpointIds: Set<String>) -> [String] {
        let revokedKeys = Set(endpointIds.map { $0.lowercased() })
        guard !revokedKeys.isEmpty else { return [] }
        var retiredEndpointIds: [String] = []
        for (transactionId, record) in activeRecords {
            guard !revokedKeys.isDisjoint(with: record.endpoints.keys) else { continue }
            retiredEndpointIds.append(contentsOf: record.endpoints.values.map(\.uuid))
            terminalRecords[transactionId] = BleG2OtaTerminalRecord(
                scope: record.scope,
                instanceId: record.instanceId,
                reason: .revoked,
                revoked: true
            )
            activeRecords.removeValue(forKey: transactionId)
        }
        return retiredEndpointIds
    }

    func isEndpointOwned(_ uuid: String) -> Bool {
        let key = uuid.lowercased()
        // Missing keys must not count as owned: `nil != .retired` is true in Swift
        // and would let one G2 transaction gate every unrelated UUID, including R1.
        return activeRecords.values.contains { record in
            guard let lease = record.endpoints[key] else { return false }
            return lease.phase != .retired
        }
    }

    func shouldAllowAdmission(
        endpointId: String,
        otaContext: BleG2OtaContext?,
        purpose: BleG2OtaAdmissionPurpose
    ) -> (allowed: Bool, reason: String) {
        let endpointKey = endpointId.lowercased()
        guard let context = otaContext else {
            let owned = activeRecords.values.contains { record in
                if let lease = record.endpoints[endpointKey] {
                    return lease.phase != .retired
                }
                return false
            }
            return owned ? (false, "otaTransactionGate") : (true, "")
        }
        guard let record = activeRecords[context.transactionId],
              record.scope.generation == context.generation else {
            return (false, "otaContextMissing")
        }
        guard record.instanceId == context.instanceId else {
            return (false, "otaContextStaleOwner")
        }
        guard let endpoint = record.endpoints[endpointKey] else {
            return (false, "otaContextEndpointMismatch")
        }
        switch endpoint.phase {
        case .waiting:
            return purpose == .activation ? (true, "") : (false, "otaContextEndpointNotActive")
        case .active, .recovering:
            if purpose == .write && !endpoint.hasBoundPhysicalPair {
                return (false, "otaContextMissingPhysicalPair")
            }
            return (true, "")
        case .parked, .retired:
            return (false, "otaContextEndpointCompleted")
        case .retiring:
            return (false, "otaContextEndpointRetiring")
        }
    }

    func shouldAllowLegacyCleanup(endpointId: String) -> Bool {
        !isEndpointOwned(endpointId)
    }

    func activeContext(for endpointId: String) -> BleG2OtaContext? {
        let key = endpointId.lowercased()
        for record in activeRecords.values {
            if let endpoint = record.endpoints[key],
               endpoint.phase == .active || endpoint.phase == .recovering {
                return BleG2OtaContext(
                    transactionId: record.scope.transactionId,
                    generation: record.scope.generation,
                    instanceId: record.instanceId
                )
            }
        }
        return nil
    }

    /// Resolve immutable transaction metadata only for the exact live native
    /// owner. Endpoint updates intentionally do not repeat config/SN because
    /// accepting mutable Dart copies would weaken the scope frozen by begin.
    func activeScope(for context: BleG2OtaContext) -> BleG2OtaTransactionScope? {
        guard let record = activeRecords[context.transactionId],
              record.scope.generation == context.generation,
              record.instanceId == context.instanceId else {
            return nil
        }
        return record.scope
    }

    func scopeEndpointIds(data: [String: Any]) -> [String] {
        BleG2OtaTransactionScope(data: data)?.endpoints.map(\.uuid) ?? []
    }

    func hasKnownTransaction(data: [String: Any]) -> Bool {
        guard let scope = BleG2OtaTransactionScope(data: data) else { return false }
        return activeRecords[scope.transactionId] != nil || terminalRecords[scope.transactionId] != nil
    }

    func endpointSnapshots(endpointIds: [String]) -> [String: BleG2OtaEndpointSnapshot] {
        let keys = Set(endpointIds.map { $0.lowercased() })
        guard !keys.isEmpty else { return [:] }
        var snapshots: [String: BleG2OtaEndpointSnapshot] = [:]
        for record in activeRecords.values {
            for (key, lease) in record.endpoints where keys.contains(key) {
                snapshots[key] = BleG2OtaEndpointSnapshot(
                    uuid: lease.uuid,
                    name: lease.name,
                    sessionGeneration: lease.sessionGeneration,
                    attemptGeneration: lease.attemptGeneration,
                    hasBoundPhysicalPair: lease.hasBoundPhysicalPair,
                    phase: lease.phase
                )
            }
        }
        return snapshots
    }

    func endpointContexts(endpointIds: [String]) -> [String: BleG2OtaContext] {
        let keys = Set(endpointIds.map { $0.lowercased() })
        guard !keys.isEmpty else { return [:] }
        var contexts: [String: BleG2OtaContext] = [:]
        for record in activeRecords.values {
            for key in record.endpoints.keys where keys.contains(key) {
                contexts[key] = BleG2OtaContext(
                    transactionId: record.scope.transactionId,
                    generation: record.scope.generation,
                    instanceId: record.instanceId
                )
            }
        }
        return contexts
    }

    func allEndpointSnapshots() -> [String: BleG2OtaEndpointSnapshot] {
        var snapshots: [String: BleG2OtaEndpointSnapshot] = [:]
        for record in activeRecords.values {
            for (key, lease) in record.endpoints {
                snapshots[key] = BleG2OtaEndpointSnapshot(
                    uuid: lease.uuid,
                    name: lease.name,
                    sessionGeneration: lease.sessionGeneration,
                    attemptGeneration: lease.attemptGeneration,
                    hasBoundPhysicalPair: lease.hasBoundPhysicalPair,
                    phase: lease.phase
                )
            }
        }
        return snapshots
    }

    func allEndpointContexts() -> [String: BleG2OtaContext] {
        var contexts: [String: BleG2OtaContext] = [:]
        for record in activeRecords.values {
            for key in record.endpoints.keys {
                contexts[key] = BleG2OtaContext(
                    transactionId: record.scope.transactionId,
                    generation: record.scope.generation,
                    instanceId: record.instanceId
                )
            }
        }
        return contexts
    }

    private func context(from data: [String: Any]) -> BleG2OtaContext? {
        BleG2OtaContext(data: data)
    }

    private func endpointKey(from data: [String: Any]) -> String? {
        let uuid = (data["uuid"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return uuid.isEmpty ? nil : uuid.lowercased()
    }

    private func result(
        _ status: BleG2OtaTransactionStatus,
        scope: BleG2OtaTransactionScope,
        instanceId: String? = nil,
        reason: String? = nil
    ) -> BleG2OtaTransactionResult {
        result(
            status,
            transactionId: scope.transactionId,
            generation: scope.generation,
            instanceId: instanceId ?? nativeInstanceId,
            reason: reason
        )
    }

    private func result(
        _ status: BleG2OtaTransactionStatus,
        context: BleG2OtaContext,
        reason: String? = nil
    ) -> BleG2OtaTransactionResult {
        result(
            status,
            transactionId: context.transactionId,
            generation: context.generation,
            instanceId: context.instanceId,
            reason: reason
        )
    }

    private func result(
        _ status: BleG2OtaTransactionStatus,
        data: [String: Any],
        reason: String? = nil
    ) -> BleG2OtaTransactionResult {
        result(
            status,
            transactionId: data["transactionId"] as? String ?? "",
            generation: BleG2OtaInteger.parseOptional(data["generation"]) ?? 0,
            instanceId: data["instanceId"] as? String ?? nativeInstanceId,
            reason: reason
        )
    }

    private func result(
        _ status: BleG2OtaTransactionStatus,
        transactionId: String,
        generation: Int64,
        instanceId: String,
        reason: String? = nil
    ) -> BleG2OtaTransactionResult {
        BleG2OtaTransactionResult(
            status: status,
            transactionId: transactionId,
            generation: generation,
            instanceId: instanceId,
            reason: reason
        )
    }

    private func hasEndpointOverlap(_ scope: BleG2OtaTransactionScope) -> Bool {
        let candidateKeys = Set(scope.endpoints.map(\.key))
        return activeRecords.values.contains { record in
            !candidateKeys.isDisjoint(with: record.endpoints.keys)
        }
    }

    private func markTransactionRetiring(transactionId: String) -> [String] {
        guard var record = activeRecords[transactionId] else { return [] }
        let endpointIds = record.endpoints.values.map(\.uuid)
        for key in record.endpoints.keys {
            record.endpoints[key]?.phase = .retiring
        }
        activeRecords[transactionId] = record
        return endpointIds
    }
}

enum BleG2OtaFinishOrchestrator {
    /// Shared finish sequence used by BleManager and behavior tests.  The
    /// registry enters retiring before the retire closure so re-entrant native
    /// callbacks cannot write or recover while physical teardown is running.
    static func finish(
        data: [String: Any],
        registry: BleG2OtaTransactionRegistry,
        retire: (
            _ endpointIds: [String],
            _ snapshots: [String: BleG2OtaEndpointSnapshot],
            _ contextsByEndpoint: [String: BleG2OtaContext],
            _ preparedResult: BleG2OtaTransactionResult
        ) -> Void,
        wake: (_ endpointIds: [String]) -> Void
    ) -> BleG2OtaTransactionResult {
        let prepared = registry.prepareFinish(data: data)
        guard prepared.result.status == .committed else {
            return prepared.result
        }
        let snapshots = registry.endpointSnapshots(endpointIds: prepared.endpointIds)
        let contexts = registry.endpointContexts(endpointIds: prepared.endpointIds)
        retire(prepared.endpointIds, snapshots, contexts, prepared.result)
        let result = registry.commitPreparedFinish(data: data)
        if result.status == .committed, result.reason != BleG2OtaFinishReason.revoked.rawValue {
            wake(prepared.endpointIds)
        }
        return result
    }
}

enum BleG2OtaInteger {
    /// MethodChannel numeric IDs must be integral NSNumber values. Bool and
    /// floating-point NSNumbers are rejected so Dart wire IDs cannot be accepted
    /// via lossy truncation, and unsigned values must fit in Int64.
    static func parseOptional(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber else { return nil }
        let type = String(cString: number.objCType)
        switch type {
        case "s", "i", "l", "q":
            return number.int64Value
        case "C", "S", "I", "L", "Q":
            let unsignedValue = number.uint64Value
            guard unsignedValue <= UInt64(Int64.max) else { return nil }
            return Int64(unsignedValue)
        default:
            return nil
        }
    }

    static func parseRequired(_ value: Any?) -> Int64? {
        guard value != nil else { return nil }
        return parseOptional(value)
    }
}
