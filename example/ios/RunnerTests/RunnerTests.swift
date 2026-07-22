import Flutter
import UIKit
import XCTest


@testable import flutter_ezw_ble

// This demonstrates a simple unit test of the Swift portion of this plugin's implementation.
//
// See https://developer.apple.com/documentation/xctest for more information about using XCTest.

class RunnerTests: XCTestCase {

  func testBleConnectModelEncodesSessionAndAttemptGenerations() throws {
    let model = BleConnectModel(
      uuid: "g2-left",
      name: "Even G2",
      connectState: .contactDevice,
      source: .autoReconnect,
      generation: 42,
      attemptGeneration: 7
    )

    let data = try JSONEncoder().encode(model)
    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

    XCTAssertEqual(json["generation"] as? Int, 42)
    XCTAssertEqual(json["sessionGeneration"] as? Int, 42)
    XCTAssertEqual(json["attemptGeneration"] as? Int, 7)
  }

  func testPendingReconnectIdentityRequiresExactConfigNameAndMacSuffix() {
    let pending = BlePendingReconnectIdentity(
      belongConfig: "ring_bcl_1",
      name: "EVEN R1_2639B0",
      expectedMacSuffix: "2639B0",
      source: .manualReconnect
    )

    XCTAssertTrue(pending.matches(
      belongConfig: "ring_bcl_1",
      advertisedName: "EVEN R1_2639B0"
    ))
    XCTAssertFalse(pending.matches(
      belongConfig: "ring_bcl_1",
      advertisedName: "EVEN R1_84E0C7"
    ))
    XCTAssertFalse(pending.matches(
      belongConfig: "g2_glasses",
      advertisedName: "EVEN R1_2639B0"
    ))
  }

  func testGetPlatformVersion() {
    let plugin = FlutterEzwBlePlugin()

    let call = FlutterMethodCall(methodName: "getPlatformVersion", arguments: [])

    let resultExpectation = expectation(description: "result block must be called.")
    plugin.handle(call) { result in
      XCTAssertEqual(result as! String, "iOS " + UIDevice.current.systemVersion)
      resultExpectation.fulfill()
    }
    waitForExpectations(timeout: 1)
  }

  func testConnectionAdmissionGatePrioritizesManualWaitersWithoutPreemption() {
    let gate = BleConnectionAdmissionGate()
    let first = BleConnectionAdmission(endpointId: "auto-1", generation: 1, sessionId: 11, source: .autoReconnect)
    let second = BleConnectionAdmission(endpointId: "auto-2", generation: 1, sessionId: 12, source: .autoReconnect)
    let manual = BleConnectionAdmission(endpointId: "manual", generation: 1, sessionId: 13, source: .manualReconnect)
    [first, second, manual].forEach { gate.registerAttempt(endpointId: $0.endpointId, generation: $0.generation) }

    XCTAssertEqual(gate.onPhysicalConnected(first), .granted)
    XCTAssertEqual(gate.onPhysicalConnected(second), .queued)
    XCTAssertEqual(gate.onPhysicalConnected(manual), .queued)
    XCTAssertEqual(gate.complete(first), manual)
    XCTAssertEqual(gate.complete(manual), second)
    XCTAssertNil(gate.complete(second))
  }

  func testConnectionAdmissionGateRejectsStaleAndDuplicateCallbacks() {
    let gate = BleConnectionAdmissionGate()
    let current = BleConnectionAdmission(endpointId: "g2-left", generation: 2, sessionId: 21, source: .autoReconnect)
    gate.registerAttempt(endpointId: current.endpointId, generation: current.generation)

    XCTAssertEqual(
      gate.onPhysicalConnected(BleConnectionAdmission(endpointId: current.endpointId, generation: 1, sessionId: 20, source: current.source)),
      .stale
    )
    XCTAssertEqual(gate.onPhysicalConnected(current), .granted)
    XCTAssertEqual(gate.onPhysicalConnected(current), .duplicate)
  }

  func testConnectionAdmissionGateRejectsBlankEndpointIdentity() {
    let gate = BleConnectionAdmissionGate()
    let blank = BleConnectionAdmission(endpointId: "   ", generation: 1, sessionId: 22, source: .autoReconnect)
    gate.registerAttempt(endpointId: blank.endpointId, generation: blank.generation)

    XCTAssertEqual(gate.onPhysicalConnected(blank), .invalidIdentity)
    XCTAssertNil(gate.cancelEndpoint(blank.endpointId))
  }

  func testConnectionAdmissionGateResetAndManualPromotion() {
    let gate = BleConnectionAdmissionGate()
    let active = BleConnectionAdmission(endpointId: "active", generation: 1, sessionId: 31, source: .autoReconnect)
    let promoted = BleConnectionAdmission(endpointId: "promoted", generation: 1, sessionId: 32, source: .autoReconnect)
    let peer = BleConnectionAdmission(endpointId: "peer", generation: 1, sessionId: 33, source: .autoReconnect)
    [active, promoted, peer].forEach { gate.registerAttempt(endpointId: $0.endpointId, generation: $0.generation) }
    _ = gate.onPhysicalConnected(active)
    _ = gate.onPhysicalConnected(promoted)
    _ = gate.onPhysicalConnected(peer)

    gate.promote(endpointId: promoted.endpointId, generation: promoted.generation, sessionId: promoted.sessionId)
    XCTAssertEqual(
      gate.complete(active),
      BleConnectionAdmission(endpointId: promoted.endpointId, generation: promoted.generation, sessionId: promoted.sessionId, source: .manualReconnect)
    )

    gate.suspendAndReset()
    XCTAssertEqual(gate.onPhysicalConnected(peer), .suspended)
    gate.resume()
  }

  func testCancellationBarrierWatchdogIsBoundedAndOldTokenCannotReleaseNewBarrier() {
    let gate = BlePeripheralCancellationBarrierGate()
    let first = gate.begin(endpointId: "g2-left")!
    XCTAssertTrue(first.isNew)
    XCTAssertTrue(gate.timeout(endpointId: "g2-left", token: first.token))
    XCTAssertFalse(gate.isBlocking(endpointId: "g2-left"))

    let second = gate.begin(endpointId: "g2-left")!
    XCTAssertTrue(second.isNew)
    XCTAssertFalse(gate.timeout(endpointId: "g2-left", token: first.token))
    XCTAssertTrue(gate.isBlocking(endpointId: "g2-left"))

    XCTAssertEqual(
      gate.consumeCallback(endpointId: "g2-left"),
      .timedOutBarrier
    )
    XCTAssertTrue(gate.isBlocking(endpointId: "g2-left"))
    XCTAssertEqual(
      gate.consumeCallback(endpointId: "g2-left"),
      .activeBarrier(second.token)
    )
    XCTAssertFalse(gate.isBlocking(endpointId: "g2-left"))
  }

  func testPendingPhysicalConnectWatchdogRejectsStaleGenerationAndHardCancel() {
    let registry = BlePendingPhysicalConnectWatchdogRegistry()
    let endpoint = "414A6CD4-E205-5EA7-C3E5-58050A352306"
    let first = BleConnectionAdmission(
      endpointId: endpoint,
      generation: 5,
      sessionId: 105,
      source: .autoReconnect
    )
    let replacement = BleConnectionAdmission(
      endpointId: endpoint,
      generation: 6,
      sessionId: 106,
      source: .autoReconnect
    )
    let firstWork = DispatchWorkItem {}
    let replacementWork = DispatchWorkItem {}

    XCTAssertNil(registry.replace(admission: first, workItem: firstWork))
    XCTAssertTrue(
      registry.replace(admission: replacement, workItem: replacementWork) === firstWork
    )
    XCTAssertNil(registry.takeIfCurrent(first))
    XCTAssertTrue(registry.takeIfCurrent(replacement) === replacementWork)
    XCTAssertNil(registry.takeIfCurrent(replacement))

    registry.replace(admission: replacement, workItem: replacementWork)
    let removed = registry.remove(endpointIds: Set([endpoint]))
    XCTAssertEqual(removed.count, 1)
    XCTAssertTrue(removed.first === replacementWork)
    XCTAssertNil(registry.takeIfCurrent(replacement))
  }

  func testPendingPhysicalConnectWatchdogObservesAutoReconnectWithoutRecyclingSystemRequest() {
    XCTAssertEqual(
      BlePendingPhysicalConnectWatchdogMode.resolve(autoReconnect: true),
      .observeLongLivedAutoReconnect
    )
    XCTAssertEqual(
      BlePendingPhysicalConnectWatchdogMode.resolve(autoReconnect: false),
      .recycleForegroundAttempt
    )
  }

  func testRepeatedCancellationDebtsCannotBeMisappliedToNewGeneration() {
    let gate = BlePeripheralCancellationBarrierGate()
    for _ in 0..<1_000 {
      let barrier = gate.begin(endpointId: "ring")!
      XCTAssertTrue(gate.timeout(endpointId: "ring", token: barrier.token))
    }
    XCTAssertEqual(gate.timedOutDebtEndpointCountForTesting, 1)
    XCTAssertEqual(gate.timedOutDebtCountForTesting(endpointId: "ring"), 1_000)

    let current = gate.begin(endpointId: "ring")!
    for _ in 0..<1_000 {
      XCTAssertEqual(gate.consumeCallback(endpointId: "ring"), .timedOutBarrier)
      XCTAssertTrue(gate.isBlocking(endpointId: "ring"))
    }
    XCTAssertEqual(gate.timedOutDebtEndpointCountForTesting, 0)
    XCTAssertEqual(gate.consumeCallback(endpointId: "ring"), .activeBarrier(current.token))
    XCTAssertEqual(gate.consumeCallback(endpointId: "ring"), .none)
  }

  func testTimedOutDebtDoesNotHideBusinessConnectedSystemDisconnect() {
    XCTAssertEqual(
      BleTimedOutCancellationDebtPolicy.action(
        hasCurrentAdmission: false,
        isBusinessConnected: true
      ),
      .handleCurrentDisconnect
    )
    XCTAssertEqual(
      BleTimedOutCancellationDebtPolicy.action(
        hasCurrentAdmission: true,
        isBusinessConnected: false
      ),
      .redriveCurrentAttempt
    )
    XCTAssertEqual(
      BleTimedOutCancellationDebtPolicy.action(
        hasCurrentAdmission: false,
        isBusinessConnected: false
      ),
      .consumeStaleCallback
    )

    let gate = BlePeripheralCancellationBarrierGate()
    for _ in 0..<2 {
      let barrier = gate.begin(endpointId: "connected-ring")!
      XCTAssertTrue(gate.timeout(endpointId: "connected-ring", token: barrier.token))
    }
    var disconnectEvents = 0
    for isBusinessConnected in [true, false] {
      XCTAssertEqual(gate.consumeCallback(endpointId: "connected-ring"), .timedOutBarrier)
      let action = BleTimedOutCancellationDebtPolicy.action(
        hasCurrentAdmission: false,
        isBusinessConnected: isBusinessConnected
      )
      if action == .handleCurrentDisconnect {
        disconnectEvents += 1
      }
    }
    XCTAssertEqual(disconnectEvents, 1)
    XCTAssertEqual(gate.timedOutDebtCountForTesting(endpointId: "connected-ring"), 0)
  }

  func testIdentityDriftAndCompletedAdmissionsKeepBoundedState() {
    let aliases = BleReconnectIdentityAliasIndex()
    let original = "identity-0"
    var current = original
    for index in 1...1_000 {
      let next = "identity-\(index)"
      aliases.migrate(from: current, to: next)
      current = next
      XCTAssertLessThanOrEqual(
        aliases.aliasCountForTesting(canonicalUuid: current),
        BleReconnectIdentityAliasIndex.maxAliasesPerCanonical
      )
    }
    XCTAssertEqual(aliases.resolvedCanonical(uuid: original), current)
    XCTAssertLessThanOrEqual(
      aliases.totalAliasCountForTesting,
      BleReconnectIdentityAliasIndex.maxAliasesPerCanonical
    )

    let gate = BleConnectionAdmissionGate()
    for index in 1...1_000 {
      let admission = BleConnectionAdmission(
        endpointId: "endpoint-\(index)",
        generation: Int64(index),
        sessionId: Int64(index),
        source: .autoReconnect
      )
      gate.registerAttempt(endpointId: admission.endpointId, generation: admission.generation)
      XCTAssertEqual(gate.onPhysicalConnected(admission), .granted)
      XCTAssertNil(gate.complete(admission))
    }
    XCTAssertEqual(gate.trackedEndpointCountForTesting, 0)
  }

  func testReconnectIdentityMigrationPreservesAttemptSourceAndPersistentOwner() {
    var task = BleReconnectTask(
      belongConfig: "g2",
      uuid: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
      name: "Even G2_L_1234",
      source: .manualReconnect
    )
    task.attempt = 7
    task.pausedByBluetoothOff = true
    task.lastConnectedGeneration = 19
    let newUuid = "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"
    let migrated = BleReconnectIdentityPolicy.migratedTask(
      task,
      peripheralUuid: newUuid,
      peripheralName: task.name
    )

    XCTAssertEqual(migrated?.uuid, newUuid)
    XCTAssertEqual(migrated?.attempt, 7)
    XCTAssertEqual(migrated?.source, .manualReconnect)
    XCTAssertEqual(migrated?.pausedByBluetoothOff, true)
    XCTAssertEqual(migrated?.lastConnectedGeneration, 19)
    XCTAssertNil(BleReconnectIdentityPolicy.migratedTask(
      task,
      peripheralUuid: newUuid,
      peripheralName: "another-device"
    ))

    let suite = "flutter_ezw_ble.identity_migration.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = BleReconnectStore(defaults: defaults)
    store.upsert(target: BleReconnectTarget(
      belongConfig: task.belongConfig,
      uuid: task.uuid,
      name: task.name
    ))
    store.migrate(
      oldUuid: task.uuid,
      oldName: task.name,
      to: BleReconnectTarget(
        belongConfig: task.belongConfig,
        uuid: newUuid,
        name: task.name
      )
    )
    XCTAssertNil(store.target(uuid: task.uuid))
    XCTAssertEqual(store.target(uuid: newUuid)?.uuid, newUuid)
  }

  func testSystemConnectedIdentityTakeoverRequiresExactStableIdentity() {
    let staleUuid = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
    let currentUuid = "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"

    XCTAssertTrue(BleReconnectIdentityPolicy.matchesSystemConnectedPeripheral(
      taskUuid: staleUuid,
      taskName: "Even G2_32_R_18B77C",
      peripheralUuid: currentUuid,
      peripheralName: "Even G2_32_R_18B77C"
    ))
    XCTAssertTrue(BleReconnectIdentityPolicy.matchesSystemConnectedPeripheral(
      taskUuid: staleUuid,
      taskName: "Even G2_32_R_18B77C",
      peripheralUuid: staleUuid.lowercased(),
      peripheralName: "unexpected-name"
    ))
    XCTAssertFalse(BleReconnectIdentityPolicy.matchesSystemConnectedPeripheral(
      taskUuid: staleUuid,
      taskName: "Even G2_32_R_18B77C",
      peripheralUuid: currentUuid,
      peripheralName: "Even G2_32_R_OTHER"
    ))
    XCTAssertFalse(BleReconnectIdentityPolicy.matchesSystemConnectedPeripheral(
      taskUuid: "",
      taskName: "",
      peripheralUuid: currentUuid,
      peripheralName: ""
    ))
  }

  func testBluetoothResetStartsANewAutomaticSourceAttempt() {
    XCTAssertEqual(BleReconnectSourcePolicy.afterTransportReset(), .autoReconnect)
  }

  func testBusinessConnectedSystemDisconnectReusesLastAcceptedGeneration() {
    var task = BleReconnectTask(
      belongConfig: "ring_bcl_1",
      uuid: "ring",
      name: "EVEN R1_2639B0",
      source: .autoReconnect
    )
    task.lastConnectedGeneration = 9

    XCTAssertEqual(
      BleTerminalConnectionMetadataPolicy.resolve(
        state: .disconnectFromSys,
        currentAdmission: nil,
        reconnectTask: task
      ),
      BleTerminalConnectionMetadata(source: .autoReconnect, generation: 9)
    )
  }

  func testTerminalEpochSurvivesVolatileConnectedCacheReset() {
    var task = BleReconnectTask(
      belongConfig: "ring_bcl_1",
      uuid: "ring",
      name: "EVEN R1_2639B0",
      source: .autoReconnect
    )
    task.lastConnectedGeneration = 9

    // didDisconnect 进入 manager 前，connectedDevices 的本地 bool 可能已被底层清理。
    // 只要 reconnect task 仍持有最后一次真实业务成功 epoch，就必须保持同代终态，
    // 否则 Dart epoch guard 会把真实断连误判为陈旧回调。
    XCTAssertEqual(BleTerminalConnectionMetadataPolicy.resolve(
      state: .disconnectFromSys,
      currentAdmission: nil,
      reconnectTask: task
    ), BleTerminalConnectionMetadata(source: .autoReconnect, generation: 9))
    XCTAssertNil(BleTerminalConnectionMetadataPolicy.resolve(
      state: .disconnectByUser,
      currentAdmission: nil,
      reconnectTask: task
    ))
  }

  func testCurrentAdmissionPrecedesHistoricalConnectedGeneration() {
    var task = BleReconnectTask(
      belongConfig: "ring_bcl_1",
      uuid: "ring",
      name: "EVEN R1_2639B0",
      source: .autoReconnect
    )
    task.lastConnectedGeneration = 9
    let admission = BleConnectionAdmission(
      endpointId: "ring",
      generation: 10,
      sessionId: 100,
      source: .manualReconnect
    )

    XCTAssertEqual(
      BleTerminalConnectionMetadataPolicy.resolve(
        state: .disconnectFromSys,
        currentAdmission: admission,
        reconnectTask: task
      ),
      BleTerminalConnectionMetadata(source: .manualReconnect, generation: 10)
    )
  }

  func testCancellationBarrierManualReplacementReleasesOldSessionAndStartsExactlyOnce() {
    let gate = BleConnectionAdmissionGate()
    let deferred = BleDeferredPeripheralReconnectRegistry()
    let endpoint = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
    let old = BleConnectionAdmission(
      endpointId: endpoint,
      generation: 1,
      sessionId: 101,
      source: .autoReconnect
    )
    let manualReplacement = BleConnectionAdmission(
      endpointId: endpoint,
      generation: 2,
      sessionId: 102,
      source: .manualReconnect
    )
    gate.registerAttempt(endpointId: endpoint, generation: old.generation)
    XCTAssertEqual(gate.onPhysicalConnected(old), .granted)

    // 旧 generation 仍 active 时，手动请求先注册新 generation，但不 promote 旧 session。
    gate.registerAttempt(endpointId: endpoint, generation: manualReplacement.generation)
    deferred.deferConnection(endpointId: endpoint, autoReconnect: true)
    XCTAssertNil(gate.cancelSession(old))
    XCTAssertEqual(gate.onPhysicalConnected(old), .stale)
    XCTAssertEqual(gate.onPhysicalConnected(manualReplacement), .granted)

    // didDisconnect 与 watchdog 无论谁先到，都只能原子 take 一次。
    XCTAssertEqual(deferred.take(endpointId: endpoint), true)
    XCTAssertNil(deferred.take(endpointId: endpoint))
  }

  func testConnectionAdmissionGateRevokesActiveWaitingAndPrephysicalInOneBatch() {
    let gate = BleConnectionAdmissionGate()
    let active = BleConnectionAdmission(endpointId: "revoked-active", generation: 1, sessionId: 201, source: .autoReconnect)
    let waiting = BleConnectionAdmission(endpointId: "revoked-waiting", generation: 1, sessionId: 202, source: .autoReconnect)
    let prephysical = BleConnectionAdmission(endpointId: "revoked-prephysical", generation: 1, sessionId: 203, source: .autoReconnect)
    let allowed = BleConnectionAdmission(endpointId: "allowed", generation: 1, sessionId: 204, source: .autoReconnect)
    [active, waiting, prephysical, allowed].forEach {
      gate.registerAttempt(endpointId: $0.endpointId, generation: $0.generation)
    }
    XCTAssertEqual(gate.onPhysicalConnected(active), .granted)
    XCTAssertEqual(gate.onPhysicalConnected(waiting), .queued)
    XCTAssertEqual(gate.onPhysicalConnected(allowed), .queued)

    XCTAssertEqual(
      gate.cancelEndpoints(Set([active.endpointId, waiting.endpointId, prephysical.endpointId])),
      allowed
    )
    XCTAssertEqual(gate.onPhysicalConnected(active), .stale)
    XCTAssertEqual(gate.onPhysicalConnected(waiting), .stale)
    XCTAssertEqual(gate.onPhysicalConnected(prephysical), .stale)
  }

  func testValidCallerUuidReplacesPersistedSameNameUuidAtomically() {
    let suite = "flutter_ezw_ble.caller_identity.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = BleReconnectStore(defaults: defaults)
    let oldUuid = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
    let callerUuid = "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"
    let name = "Even G2_L_2607"
    store.upsert(target: BleReconnectTarget(belongConfig: "g2", uuid: oldUuid, name: name))

    let canonical = BleReconnectTargetIdentityPolicy.canonicalUuid(
      callerUuid: callerUuid,
      aliasCanonicalUuid: nil,
      persistedUuid: store.target(uuid: "", name: name)?.uuid
    )
    XCTAssertEqual(canonical, callerUuid)
    store.upsert(target: BleReconnectTarget(belongConfig: "g2", uuid: canonical, name: name))
    XCTAssertNil(store.target(uuid: oldUuid))
    XCTAssertEqual(store.target(uuid: callerUuid)?.uuid, callerUuid)
  }

  func testInitConfigDiffAndStoreRemoveRevokedReconnectOwners() {
    let previous = [makeConfig(name: "removed", autoReconnect: true),
                    makeConfig(name: "disabled", autoReconnect: true),
                    makeConfig(name: "kept", autoReconnect: true)]
    let current = [makeConfig(name: "disabled", autoReconnect: false),
                   makeConfig(name: "kept", autoReconnect: true)]
    XCTAssertEqual(
      BleReconnectConfigDiff.revokedConfigNames(previous: previous, current: current),
      Set(["removed", "disabled"])
    )

    let suite = "flutter_ezw_ble.config_revoke.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = BleReconnectStore(defaults: defaults)
    store.upsert(target: BleReconnectTarget(belongConfig: "removed", uuid: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA", name: "left"))
    store.upsert(target: BleReconnectTarget(belongConfig: "kept", uuid: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB", name: "right"))
    let removed = store.removeTargets(configNames: Set(["removed"]))
    XCTAssertEqual(removed.map(\.belongConfig), ["removed"])
    XCTAssertEqual(store.targets().map(\.belongConfig), ["kept"])
  }

  func testStateRestorationRejectsSingleConfigWithoutPersistedOrRuntimeOwner() {
    let singleConfig = makeConfig(name: "g2", autoReconnect: true)
    XCTAssertNil(BleStateRestorationAuthorization.config(
      persistedTarget: nil,
      runtimeTask: nil,
      configs: [singleConfig]
    ))
    XCTAssertEqual(
      BleStateRestorationAuthorization.replayDecision(
        configsInitialized: true,
        hasAuthorizedConfig: false
      ),
      .rejectUnauthorized
    )
    XCTAssertEqual(
      BleStateRestorationAuthorization.replayDecision(
        configsInitialized: false,
        hasAuthorizedConfig: false
      ),
      .deferUntilConfigsReady
    )
    XCTAssertNil(BleStateRestorationAuthorization.config(
      persistedTarget: BleReconnectTarget(
        belongConfig: "g2",
        uuid: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
        name: "left"
      ),
      runtimeTask: nil,
      configs: [makeConfig(name: "g2", autoReconnect: false)]
    ))
  }

  func testResetBlePreservesPersistentOwnerAndInvalidatesRuntimeGate() {
    let manager = BleManager.shared
    let uuid = UUID().uuidString
    let target = BleReconnectTarget(belongConfig: "reset-test", uuid: uuid, name: "reset-owner")
    manager.reconnectStore.upsert(target: target)
    defer { manager.reconnectStore.remove(uuid: uuid, name: target.name) }
    let old = BleConnectionAdmission(
      endpointId: uuid,
      generation: 9,
      sessionId: 909,
      source: .autoReconnect
    )
    manager.connectionAdmissionGate.registerAttempt(endpointId: uuid, generation: old.generation)

    manager.reset()

    XCTAssertEqual(manager.reconnectStore.target(uuid: uuid)?.uuid, uuid)
    XCTAssertEqual(manager.connectionAdmissionGate.onPhysicalConnected(old), .stale)
  }

  private func makeConfig(name: String, autoReconnect: Bool) -> BleConfig {
    BleConfig(
      name: name,
      scan: BleScan.empty(),
      privateServices: [BlePrivateService(
        service: "180A",
        writeChars: nil,
        readChars: nil,
        type: 0
      )],
      autoReconnect: autoReconnect
    )
  }

}
