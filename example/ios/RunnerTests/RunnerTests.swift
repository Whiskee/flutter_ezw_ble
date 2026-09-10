import Flutter
import UIKit
import XCTest


@testable import flutter_ezw_ble

// This demonstrates a simple unit test of the Swift portion of this plugin's implementation.
//
// See https://developer.apple.com/documentation/xctest for more information about using XCTest.

class RunnerTests: XCTestCase {

  func testReconnectOwnerHealthRequiresExactLiveAdmissionSession() {
    XCTAssertEqual(
      BleReconnectPendingOwnerPolicy.evaluate(
        taskSessionGeneration: 41,
        admissionSessionGeneration: 41,
        hasSession: true,
        sessionMatchesAdmission: true,
        peripheralIsConnectedOrConnecting: true,
        pendingTeardown: false
      ),
      .healthy
    )

    XCTAssertEqual(
      BleReconnectPendingOwnerPolicy.evaluate(
        taskSessionGeneration: 41,
        admissionSessionGeneration: 41,
        hasSession: false,
        sessionMatchesAdmission: false,
        peripheralIsConnectedOrConnecting: false,
        pendingTeardown: false
      ),
      .missingSession
    )
    XCTAssertEqual(
      BleReconnectPendingOwnerPolicy.evaluate(
        taskSessionGeneration: 42,
        admissionSessionGeneration: 41,
        hasSession: true,
        sessionMatchesAdmission: true,
        peripheralIsConnectedOrConnecting: true,
        pendingTeardown: false
      ),
      .sessionMismatch
    )
    XCTAssertEqual(
      BleReconnectPendingOwnerPolicy.evaluate(
        taskSessionGeneration: 41,
        admissionSessionGeneration: 41,
        hasSession: true,
        sessionMatchesAdmission: false,
        peripheralIsConnectedOrConnecting: true,
        pendingTeardown: false
      ),
      .sessionMismatch
    )
    XCTAssertEqual(
      BleReconnectPendingOwnerPolicy.evaluate(
        taskSessionGeneration: 41,
        admissionSessionGeneration: 41,
        hasSession: true,
        sessionMatchesAdmission: true,
        peripheralIsConnectedOrConnecting: false,
        pendingTeardown: false
      ),
      .stalePeripheral
    )
    XCTAssertEqual(
      BleReconnectPendingOwnerPolicy.evaluate(
        taskSessionGeneration: 41,
        admissionSessionGeneration: 41,
        hasSession: true,
        sessionMatchesAdmission: true,
        peripheralIsConnectedOrConnecting: true,
        pendingTeardown: true
      ),
      .teardownPending
    )
  }

  func testReconnectActivationDispositionNeverReusesTaskWithoutLiveOwner() {
    XCTAssertEqual(
      BleReconnectActivationDispositionPolicy.resolve(
        hasLiveOwner: true,
        hasDeferredWork: false,
        successDisposition: .reused,
        successReason: "",
        deferredReason: "nativeOwnerDeferred"
      ).disposition,
      .reused
    )
    XCTAssertEqual(
      BleReconnectActivationDispositionPolicy.resolve(
        hasLiveOwner: false,
        hasDeferredWork: true,
        successDisposition: .reused,
        successReason: "",
        deferredReason: "nativeOwnerDeferred"
      ),
      BleReconnectOwnerActivationOutcome(
        disposition: .deferred,
        reason: "nativeOwnerDeferred"
      )
    )
    XCTAssertEqual(
      BleReconnectActivationDispositionPolicy.resolve(
        hasLiveOwner: false,
        hasDeferredWork: false,
        successDisposition: .reused,
        successReason: "",
        deferredReason: "nativeOwnerDeferred"
      ).disposition,
      .rejected
    )
  }

  func testAutomaticPairingRecoveryUsesTenSecondWindowsAndFiveSecondRetryDelay() {
    XCTAssertEqual(BlePeerPairingRecoveryPolicy.scanWindow(for: .autoReconnect), 10)
    XCTAssertEqual(BlePeerPairingRecoveryPolicy.retryDelay, 5)
    XCTAssertEqual(
      BlePeerPairingRecoveryPolicy.actionAfterWindowMiss(source: .autoReconnect),
      .retryAfterDelay
    )
  }

  func testManualPairingRecoveryKeepsBoundedExistingWindow() {
    XCTAssertEqual(BlePeerPairingRecoveryPolicy.scanWindow(for: .manualReconnect), 20)
    XCTAssertEqual(
      BlePeerPairingRecoveryPolicy.actionAfterWindowMiss(source: .manualReconnect),
      .finishManualAttempt
    )
  }

  func testSecurityGateFailurePolicyStopsAutomaticAttemptFiveAndManualAttemptOne() {
    for failureCount in 1..<BlePeerPairingRecoveryPolicy.maxSecurityGateAttempts {
      XCTAssertEqual(
        BlePeerPairingRecoveryPolicy.actionAfterSecurityGateFailure(
          source: .autoReconnect,
          failureCount: failureCount
        ),
        .retryFreshAdvertisement
      )
    }
    XCTAssertEqual(
      BlePeerPairingRecoveryPolicy.actionAfterSecurityGateFailure(
        source: .autoReconnect,
        failureCount: BlePeerPairingRecoveryPolicy.maxSecurityGateAttempts
      ),
      .securityRecoveryExhausted
    )
    XCTAssertEqual(
      BlePeerPairingRecoveryPolicy.actionAfterSecurityGateFailure(
        source: .manualReconnect,
        failureCount: 1
      ),
      .stopAttempt
    )
  }

  func testAutomaticSecurityGateFailureFiveRetiresOwnerAndRejectsAttemptSix() {
    let manager = BleManager.shared
    let originalConfigs = manager.bleConfigs
    let configName = "security-recovery-\(UUID().uuidString)"
    let target = BleReconnectTarget(
      belongConfig: configName,
      uuid: UUID().uuidString,
      name: "Even G2_L_\(UUID().uuidString)"
    )
    defer {
      manager.cancelReconnectTask(uuid: target.uuid, name: target.name)
      manager.reconnectStore.remove(uuid: target.uuid, name: target.name)
      manager.bleConfigs = originalConfigs
    }
    manager.bleConfigs = [makeConfig(name: configName, autoReconnect: true)]
    XCTAssertNotNil(manager.armReconnectTarget(
      target,
      source: .autoReconnect,
      sessionGeneration: 901
    ))

    for failureCount in 1..<BlePeerPairingRecoveryPolicy.maxSecurityGateAttempts {
      XCTAssertEqual(
        manager.registerSecurityGateFailure(
          uuid: target.uuid,
          name: target.name,
          source: .autoReconnect
        ),
        .retryFreshAdvertisement,
        "attempt \(failureCount) must keep the exact automatic owner"
      )
    }
    XCTAssertEqual(
      manager.registerSecurityGateFailure(
        uuid: target.uuid,
        name: target.name,
        source: .autoReconnect
      ),
      .securityRecoveryExhausted
    )
    XCTAssertNil(manager.reconnectStore.target(uuid: target.uuid, name: target.name))

    let attemptSix = manager.activateAutoReconnectTargets(
      [target],
      source: .autoReconnect,
      sessionGeneration: 902
    ).first
    XCTAssertEqual(attemptSix?.state, .rejected)
    XCTAssertEqual(attemptSix?.reason, "securityRecoveryExhaustedPersisted")
    XCTAssertNil(manager.reconnectTasks[target.uuid.lowercased()])
  }

  func testSecurityGateTimeoutAndCallbackCanConsumeExactAttemptOnlyOnce() {
    let registry = BleSecurityGateAttemptRegistry()
    let first = BleConnectionAdmission(
      endpointId: "g2-left",
      generation: 1,
      sessionId: 101,
      source: .autoReconnect,
      sessionGeneration: 11
    )
    registry.start(admission: first, characteristicUUID: "5403")

    XCTAssertNil(registry.consumeTimeout(
      characteristicUUID: "5404",
      currentAdmission: first
    ))
    XCTAssertEqual(registry.consumeTimeout(
      characteristicUUID: "5403",
      currentAdmission: first
    )?.admission, first)
    XCTAssertNil(registry.consumeTimeout(
      characteristicUUID: "5403",
      currentAdmission: first
    ))
    XCTAssertNil(registry.complete(
      endpointId: first.endpointId,
      characteristicUUID: "5403",
      currentAdmission: first
    ))

    let replacement = BleConnectionAdmission(
      endpointId: first.endpointId,
      generation: 2,
      sessionId: 102,
      source: .autoReconnect,
      sessionGeneration: 11
    )
    registry.start(admission: replacement, characteristicUUID: "5403")
    XCTAssertNil(registry.consumeTimeout(
      characteristicUUID: "5403",
      currentAdmission: first
    ))
    XCTAssertEqual(
      registry.complete(
        endpointId: replacement.endpointId,
        characteristicUUID: "5403",
        currentAdmission: replacement
      )?.admission,
      replacement
    )
  }

  func testSecurityRecoveryBudgetPersistsAndKeepsPeerEndpointsIndependent() {
    let suite = "flutter_ezw_ble.security_recovery.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let leftName = "Even G2_L_260827"
    let rightName = "Even G2_R_260827"
    let store = BleReconnectStore(defaults: defaults)
    store.upsertSecurityRecoveryRecord(
      belongConfig: "g2",
      name: leftName,
      uuid: "left-uuid",
      failureCount: 4
    )
    store.upsertSecurityRecoveryRecord(
      belongConfig: "g2",
      name: rightName,
      uuid: "right-uuid",
      failureCount: 2
    )

    let relaunchedStore = BleReconnectStore(defaults: defaults)
    XCTAssertEqual(
      relaunchedStore.securityRecoveryRecord(belongConfig: "G2", name: leftName)?.failureCount,
      4
    )
    XCTAssertEqual(
      relaunchedStore.securityRecoveryRecord(belongConfig: "g2", name: rightName)?.failureCount,
      2
    )
    relaunchedStore.upsertSecurityRecoveryRecord(
      belongConfig: "g2",
      name: leftName,
      uuid: "left-uuid",
      failureCount: 5
    )
    XCTAssertEqual(
      relaunchedStore.securityRecoveryRecord(belongConfig: "g2", name: leftName)?.exhausted,
      true
    )
    XCTAssertEqual(
      relaunchedStore.securityRecoveryRecord(belongConfig: "g2", name: rightName)?.failureCount,
      2
    )

    relaunchedStore.removeSecurityRecoveryRecord(belongConfig: "g2", name: leftName)
    XCTAssertNil(relaunchedStore.securityRecoveryRecord(belongConfig: "g2", name: leftName))
    XCTAssertEqual(
      relaunchedStore.securityRecoveryRecord(belongConfig: "g2", name: rightName)?.failureCount,
      2
    )
  }

  func testSecurityRecoveryRejectsCorruptDefaultEntries() {
    let suite = "flutter_ezw_ble.security_recovery_corrupt.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(
      [[
        "belongConfig": "g2",
        "name": "Even G2_L_260827",
        "lastUuid": "left-uuid",
        "failureCount": "5",
        "exhausted": "false"
      ]],
      forKey: "flutter_ezw_ble.reconnect.security_recovery"
    )

    XCTAssertTrue(BleReconnectStore(defaults: defaults).securityRecoveryRecords().isEmpty)
  }

  func testExhaustedSecurityRecoverySurvivesReconnectTargetRetirement() {
    let suite = "flutter_ezw_ble.security_recovery_retire.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = BleReconnectStore(defaults: defaults)
    let target = BleReconnectTarget(
      belongConfig: "g2",
      uuid: "left-uuid",
      name: "Even G2_L_260827"
    )
    store.upsert(target: target)
    store.upsertSecurityRecoveryRecord(
      belongConfig: target.belongConfig,
      name: target.name,
      uuid: target.uuid,
      failureCount: 5
    )
    store.remove(uuid: target.uuid, name: target.name)

    let relaunchedStore = BleReconnectStore(defaults: defaults)
    XCTAssertNil(relaunchedStore.target(uuid: target.uuid, name: target.name))
    XCTAssertEqual(
      relaunchedStore.securityRecoveryRecord(
        belongConfig: target.belongConfig,
        name: target.name
      )?.exhausted,
      true
    )
  }

  func testSecurityRecoveryTargetReplacementClearsOnlyChangedStableIdentity() {
    let suite = "flutter_ezw_ble.security_recovery_replace.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = BleReconnectStore(defaults: defaults)
    let oldTarget = BleReconnectTarget(
      belongConfig: "g2-old",
      uuid: "left-uuid",
      name: "Even G2_L_260827"
    )
    let peerTarget = BleReconnectTarget(
      belongConfig: "g2",
      uuid: "right-uuid",
      name: "Even G2_R_260827"
    )
    store.upsert(target: oldTarget)
    store.upsert(target: peerTarget)
    store.upsertSecurityRecoveryRecord(
      belongConfig: oldTarget.belongConfig,
      name: oldTarget.name,
      uuid: oldTarget.uuid,
      failureCount: 4
    )
    store.upsertSecurityRecoveryRecord(
      belongConfig: peerTarget.belongConfig,
      name: peerTarget.name,
      uuid: peerTarget.uuid,
      failureCount: 3
    )

    store.upsert(target: BleReconnectTarget(
      belongConfig: "g2-new",
      uuid: oldTarget.uuid,
      name: "Even G2_L_260828"
    ))

    XCTAssertNil(store.securityRecoveryRecord(
      belongConfig: oldTarget.belongConfig,
      name: oldTarget.name
    ))
    XCTAssertEqual(
      store.securityRecoveryRecord(
        belongConfig: peerTarget.belongConfig,
        name: peerTarget.name
      )?.failureCount,
      3
    )
  }

  func testBusinessConnectionStaleAbortDoesNotRemoveReplacementLease() {
    let registry = BleBusinessConnectionLeaseRegistry()
    let attemptA = businessAttempt(generation: 1)
    let attemptB = businessAttempt(generation: 2)
    registry.prepare(endpointKey: "g2-left", attempt: attemptA, at: Date())
    registry.prepare(endpointKey: "g2-left", attempt: attemptB, at: Date())

    XCTAssertFalse(registry.abort(endpointKey: "g2-left", attempt: attemptA))
    XCTAssertEqual(registry.attempt(for: "g2-left"), attemptB)
    XCTAssertTrue(registry.abort(endpointKey: "g2-left", attempt: attemptB))
    XCTAssertNil(registry.attempt(for: "g2-left"))
  }

  func testBusinessConnectionCommitRejectsStaleDisconnectedAndIncompleteReadiness() {
    let attemptA = businessAttempt(generation: 1)
    let attemptB = businessAttempt(generation: 2)

    XCTAssertEqual(evaluateBusinessCommit(attempt: attemptA, admission: attemptB), .attemptMismatch)
    XCTAssertEqual(evaluateBusinessCommit(attempt: attemptA, isConnected: false), .deviceDisconnected)
    XCTAssertEqual(evaluateBusinessCommit(attempt: attemptA, isGattReady: false), .gattNotReady)
  }

  func testBusinessConnectionAcceptedTokenCannotCommitTwice() {
    let registry = BleBusinessConnectionLeaseRegistry()
    let attempt = businessAttempt(generation: 1)
    registry.prepare(endpointKey: "g2-left", attempt: attempt, at: Date())

    XCTAssertEqual(
      evaluateBusinessCommit(attempt: attempt, prepared: registry.attempt(for: "g2-left")),
      .accepted
    )
    registry.remove(endpointKey: "g2-left")
    XCTAssertEqual(
      evaluateBusinessCommit(attempt: attempt, hasPrepare: false),
      .missingPrepare
    )
  }

  private func businessAttempt(generation: Int64) -> BleBusinessConnectionAttempt {
    BleBusinessConnectionAttempt(
      uuid: "g2-left",
      sessionGeneration: 10,
      attemptGeneration: generation
    )
  }

  private func evaluateBusinessCommit(
    attempt: BleBusinessConnectionAttempt,
    admission: BleBusinessConnectionAttempt? = nil,
    prepared: BleBusinessConnectionAttempt? = nil,
    hasPrepare: Bool = true,
    isConnected: Bool = true,
    isGattReady: Bool = true
  ) -> BleBusinessConnectionStatus {
    BleBusinessConnectionCommitPolicy.evaluate(
      attempt: attempt,
      admissionAttempt: admission ?? attempt,
      preparedAttempt: hasPrepare ? (prepared ?? attempt) : nil,
      requirePrepare: true,
      hasSession: true,
      hasDevice: true,
      isSamePeripheral: true,
      isPeripheralConnected: isConnected,
      isGattReady: isGattReady
    )
  }

  func testUpgradeStateRegistryInstallsAndConsumesMarkerIdempotently() {
    let registry = BleUpgradeStateRegistry()

    XCTAssertTrue(registry.enter("g2-left"))
    XCTAssertFalse(registry.enter("g2-left"))
    XCTAssertTrue(registry.contains("g2-left"))
    XCTAssertEqual(registry.countForTesting, 1)
    XCTAssertTrue(registry.consume("g2-left"))
    XCTAssertFalse(registry.consume("g2-left"))
    XCTAssertEqual(registry.countForTesting, 0)
  }

  func testUpgradeStateRegistryKeepsDefaultDenyAndExplicitBypassMatrix() {
    let registry = BleUpgradeStateRegistry()
    registry.enter("g2-right")

    XCTAssertFalse(registry.canSend(endpointId: "g2-right", psType: 0))
    XCTAssertTrue(registry.canSend(endpointId: "g2-right", psType: 1))
    XCTAssertTrue(
      registry.canSend(
        endpointId: "g2-right",
        psType: 0,
        allowDuringUpgrade: true
      )
    )
    XCTAssertTrue(registry.canSend(endpointId: "other", psType: 0))

    registry.clear()
    XCTAssertTrue(registry.canSend(endpointId: "g2-right", psType: 0))
  }

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
    task.lastConnectedAttemptGeneration = 27
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
    XCTAssertEqual(migrated?.lastConnectedAttemptGeneration, 27)
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

  func testBusinessConnectedSystemDisconnectReusesLastAcceptedExactOwner() {
    var task = BleReconnectTask(
      belongConfig: "ring_bcl_1",
      uuid: "ring",
      name: "EVEN R1_2639B0",
      source: .autoReconnect
    )
    task.lastConnectedGeneration = 9
    task.lastConnectedAttemptGeneration = 21

    XCTAssertEqual(
      BleTerminalConnectionMetadataPolicy.resolve(
        state: .disconnectFromSys,
        currentAdmission: nil,
        reconnectTask: task
      ),
      BleTerminalConnectionMetadata(
        source: .autoReconnect,
        generation: 9,
        attemptGeneration: 21
      )
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
    task.lastConnectedAttemptGeneration = 21

    // didDisconnect 进入 manager 前，connectedDevices 的本地 bool 可能已被底层清理。
    // 只要 reconnect task 仍持有最后一次真实业务成功 epoch，就必须保持同代终态，
    // 否则 Dart epoch guard 会把真实断连误判为陈旧回调。
    XCTAssertEqual(BleTerminalConnectionMetadataPolicy.resolve(
      state: .disconnectFromSys,
      currentAdmission: nil,
      reconnectTask: task
    ), BleTerminalConnectionMetadata(
      source: .autoReconnect,
      generation: 9,
      attemptGeneration: 21
    ))
    XCTAssertNil(BleTerminalConnectionMetadataPolicy.resolve(
      state: .disconnectByUser,
      currentAdmission: nil,
      reconnectTask: task
    ))
  }

  func testExplicitCancellationPrefersCurrentAdmissionIdentity() {
    var task = BleReconnectTask(
      belongConfig: "g2_glasses",
      uuid: "left",
      name: "Even G2_32_L_123456",
      source: .autoReconnect
    )
    task.sessionGeneration = 9
    task.lastConnectedGeneration = 8
    let admission = BleConnectionAdmission(
      endpointId: "left",
      generation: 17,
      sessionId: 100,
      source: .manualReconnect,
      sessionGeneration: 12
    )

    XCTAssertEqual(
      BleExplicitCancellationMetadataPolicy.resolve(
        currentAdmission: admission,
        reconnectTask: task
      ),
      BleExplicitCancellationMetadata(
        source: .manualReconnect,
        sessionGeneration: 12,
        attemptGeneration: 17
      )
    )
  }

  func testExplicitCancellationReusesOwnerSessionAfterGateRelease() {
    var task = BleReconnectTask(
      belongConfig: "g2_glasses",
      uuid: "right",
      name: "Even G2_32_R_654321",
      source: .autoReconnect
    )
    task.sessionGeneration = 13
    task.lastConnectedGeneration = 13
    task.lastConnectedAttemptGeneration = 31

    XCTAssertEqual(
      BleExplicitCancellationMetadataPolicy.resolve(
        currentAdmission: nil,
        reconnectTask: task
      ),
      BleExplicitCancellationMetadata(
        source: .autoReconnect,
        sessionGeneration: 13,
        attemptGeneration: 31
      )
    )
  }

  func testExplicitCancellationRejectsMissingAcceptedSession() {
    let task = BleReconnectTask(
      belongConfig: "g2_glasses",
      uuid: "right",
      name: "Even G2_32_R_654321",
      source: .autoReconnect
    )

    XCTAssertNil(BleExplicitCancellationMetadataPolicy.resolve(
      currentAdmission: nil,
      reconnectTask: task
    ))
  }

  func testExplicitCancellationDoesNotPairHistoricalAttemptWithNewSession() {
    var task = BleReconnectTask(
      belongConfig: "g2_glasses",
      uuid: "right",
      name: "Even G2_32_R_654321",
      source: .autoReconnect
    )
    task.lastConnectedGeneration = 12
    task.lastConnectedAttemptGeneration = 17
    task.sessionGeneration = 13

    XCTAssertEqual(
      BleExplicitCancellationMetadataPolicy.resolve(
        currentAdmission: nil,
        reconnectTask: task
      ),
      BleExplicitCancellationMetadata(
        source: .autoReconnect,
        sessionGeneration: 13,
        attemptGeneration: 0
      )
    )
  }

  func testCurrentAdmissionPrecedesHistoricalConnectedGeneration() {
    var task = BleReconnectTask(
      belongConfig: "ring_bcl_1",
      uuid: "ring",
      name: "EVEN R1_2639B0",
      source: .autoReconnect
    )
    task.lastConnectedGeneration = 9
    task.lastConnectedAttemptGeneration = 18
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
      BleTerminalConnectionMetadata(
        source: .manualReconnect,
        generation: 10,
        attemptGeneration: 10
      )
    )
  }

  func testNewAdmissionPreventsHistoricalAttemptFromTerminatingReplacement() {
    var task = BleReconnectTask(
      belongConfig: "g2_glasses",
      uuid: "right",
      name: "Even G2_32_R_654321",
      source: .autoReconnect
    )
    task.lastConnectedGeneration = 12
    task.lastConnectedAttemptGeneration = 17
    let replacement = BleConnectionAdmission(
      endpointId: "right",
      generation: 18,
      sessionId: 101,
      source: .manualReconnect,
      sessionGeneration: 12
    )

    XCTAssertEqual(
      BleTerminalConnectionMetadataPolicy.resolve(
        state: .disconnectFromSys,
        currentAdmission: replacement,
        reconnectTask: task
      ),
      BleTerminalConnectionMetadata(
        source: .manualReconnect,
        generation: 12,
        attemptGeneration: 18
      )
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

  func testOtaWriteQueueCompletesSuccessOnlyAfterCoreBluetoothSubmission() {
    let peripheral = FakeOtaPeripheral(endpointId: "g2-left")
    var results: [Any?] = []
    var submitted: [Data] = []
    let target = OtaWriteTarget(characteristicUUID: "OTA") { _, data in
      XCTAssertTrue(results.isEmpty)
      submitted.append(data)
      return true
    }
    let queue = OtaWriteQueue(
      peripheral: peripheral,
      scheduler: FakeOtaScheduler()
    )

    queue.enqueue(data: Data([0x01]), target: target) { value in
      results.append(value)
    }

    XCTAssertEqual(submitted, [Data([0x01])])
    XCTAssertEqual(results.count, 1)
    XCTAssertNil(results.first!)
  }

  func testOtaWriteQueueWaitsForReadyBeforeSubmittingBackpressuredWrite() {
    let peripheral = FakeOtaPeripheral(endpointId: "g2-left", canSend: false)
    var results: [Any?] = []
    var submitCount = 0
    let queue = OtaWriteQueue(
      peripheral: peripheral,
      scheduler: FakeOtaScheduler()
    )

    queue.enqueue(data: Data([0x02]), target: makeFakeOtaTarget { _ in
      submitCount += 1
      return true
    }) { value in
      results.append(value)
    }

    XCTAssertEqual(submitCount, 0)
    XCTAssertTrue(results.isEmpty)

    peripheral.canSendWriteWithoutResponse = true
    queue.onPeripheralReadyToSendWriteWithoutResponse()

    XCTAssertEqual(submitCount, 1)
    XCTAssertEqual(results.count, 1)
    XCTAssertNil(results.first!)
  }

  func testOtaWriteQueueKeepsPendingBeforeFifteenSecondStallDeadline() {
    let peripheral = FakeOtaPeripheral(endpointId: "g2-left", canSend: false)
    let clock = FakeOtaClock()
    let scheduler = FakeOtaScheduler()
    var results: [Any?] = []
    var logs: [String] = []
    let queue = OtaWriteQueue(
      peripheral: peripheral,
      logger: { logs.append($0) },
      clock: clock,
      scheduler: scheduler
    )

    queue.enqueue(data: Data([0x03]), target: makeFakeOtaTarget { _ in
      XCTFail("stalled write must not be submitted")
      return true
    }) { value in
      results.append(value)
    }
    clock.advance(by: 14.9)
    scheduler.runNext()

    XCTAssertTrue(results.isEmpty)
    XCTAssertTrue(queue.hasPending)
    XCTAssertFalse(logs.contains { $0.contains("stage=grace") })
    XCTAssertFalse(logs.contains { $0.contains("stalled") })
  }

  func testOtaWriteQueueSubmitsOnceWhenReadyArrivesBeforeFifteenSecondDeadline() {
    let peripheral = FakeOtaPeripheral(endpointId: "g2-left", canSend: false)
    let clock = FakeOtaClock()
    let scheduler = FakeOtaScheduler()
    var results: [Any?] = []
    var submitCount = 0
    var logs: [String] = []
    let queue = OtaWriteQueue(
      peripheral: peripheral,
      logger: { logs.append($0) },
      clock: clock,
      scheduler: scheduler
    )

    queue.enqueue(data: Data([0x03]), target: makeFakeOtaTarget { _ in
      submitCount += 1
      return true
    }) { value in
      results.append(value)
    }
    clock.advance(by: 14.9)
    scheduler.runNext()
    peripheral.canSendWriteWithoutResponse = true
    queue.onPeripheralReadyToSendWriteWithoutResponse()
    // 被 ready 取消的 watchdog 即使仍留在 fake scheduler，也不能二次结算。
    scheduler.runNext()

    XCTAssertEqual(submitCount, 1)
    XCTAssertEqual(results.count, 1)
    XCTAssertNil(results.first!)
    XCTAssertFalse(queue.hasPending)
    XCTAssertTrue(logs.contains {
      $0.contains("resumed") &&
        $0.contains("wait=14.900s") &&
        $0.contains("source=callback")
    })
  }

  func testOtaWriteQueueCompletesExactHeadAfterFifteenSecondStallWithIdentity() {
    let peripheral = FakeOtaPeripheral(endpointId: "g2-left", canSend: false)
    let clock = FakeOtaClock()
    let scheduler = FakeOtaScheduler()
    var results: [Any?] = []
    var secondResults: [Any?] = []
    var logs: [String] = []
    let queue = OtaWriteQueue(
      peripheral: peripheral,
      logger: { logs.append($0) },
      clock: clock,
      scheduler: scheduler
    )

    queue.enqueue(
      data: Data([0x04]),
      target: makeFakeOtaTarget { _ in
        XCTFail("stalled write must not be submitted")
        return true
      },
      expectedSessionGeneration: 1001,
      expectedAttemptGeneration: 2002
    ) { value in
      results.append(value)
    }
    queue.enqueue(
      data: Data([0x05]),
      target: makeFakeOtaTarget { _ in
        XCTFail("tail write must wait for exact OTA recovery cleanup")
        return true
      },
      expectedSessionGeneration: 1001,
      expectedAttemptGeneration: 2003
    ) { value in
      secondResults.append(value)
    }
    clock.advance(by: 15.0)
    scheduler.runNext()

    let error = results.first as? FlutterError
    XCTAssertEqual(error?.code, "ota_write_stalled")
    let details = error?.details as? [String: Any]
    XCTAssertEqual(details?["endpoint"] as? String, "g2-left")
    XCTAssertEqual(details?["reason"] as? String, "canSend=false")
    XCTAssertEqual(details?["session"] as? Int64, 1001)
    XCTAssertEqual(details?["attempt"] as? Int64, 2002)
    XCTAssertEqual(details?["pending"] as? Int, 2)
    XCTAssertGreaterThanOrEqual(details?["wait"] as? TimeInterval ?? 0, 15.0)
    XCTAssertTrue(secondResults.isEmpty)
    XCTAssertTrue(queue.hasPending)
    XCTAssertTrue(logs.contains { $0.contains("stalled") && $0.contains("episode=") })
  }

  func testOtaWriteQueueStallRejectsLateReadyUntilExactRecoveryCleanup() {
    let peripheral = FakeOtaPeripheral(endpointId: "g2-left", canSend: false)
    let clock = FakeOtaClock()
    let scheduler = FakeOtaScheduler()
    var results: [Any?] = []
    var secondResults: [Any?] = []
    var submitCount = 0
    let queue = OtaWriteQueue(
      peripheral: peripheral,
      clock: clock,
      scheduler: scheduler
    )

    queue.enqueue(data: Data([0x05]), target: makeFakeOtaTarget { _ in
      submitCount += 1
      return true
    }) { value in
      results.append(value)
    }
    queue.enqueue(data: Data([0x06]), target: makeFakeOtaTarget { _ in
      submitCount += 1
      return true
    }) { value in
      secondResults.append(value)
    }
    clock.advance(by: 15.0)
    scheduler.runNext()

    peripheral.canSendWriteWithoutResponse = true
    queue.onPeripheralReadyToSendWriteWithoutResponse()
    scheduler.runNext()

    XCTAssertEqual(submitCount, 0)
    XCTAssertEqual(results.count, 1)
    XCTAssertEqual((results.first as? FlutterError)?.code, "ota_write_stalled")
    XCTAssertTrue(secondResults.isEmpty)
    XCTAssertTrue(queue.hasPending)
  }

  func testOtaWriteQueueRecoveryCleanupStartsFreshEpisodeThatCanSend() {
    let peripheral = FakeOtaPeripheral(endpointId: "g2-left", canSend: false)
    let clock = FakeOtaClock()
    let scheduler = FakeOtaScheduler()
    var stalledResults: [Any?] = []
    var recoveredResults: [Any?] = []
    var recoveredSubmitCount = 0
    let queue = OtaWriteQueue(
      peripheral: peripheral,
      clock: clock,
      scheduler: scheduler
    )

    queue.enqueue(data: Data([0x05]), target: makeFakeOtaTarget { _ in
      XCTFail("stalled write must not be submitted")
      return true
    }) { value in
      stalledResults.append(value)
    }
    clock.advance(by: 15.0)
    scheduler.runNext()
    queue.cancelAll(reason: "ota recovery")

    peripheral.canSendWriteWithoutResponse = true
    queue.enqueue(data: Data([0x06]), target: makeFakeOtaTarget { _ in
      recoveredSubmitCount += 1
      return true
    }) { value in
      recoveredResults.append(value)
    }
    scheduler.runNextIgnoringCancellation()

    XCTAssertEqual((stalledResults.first as? FlutterError)?.code, "ota_write_stalled")
    XCTAssertEqual(recoveredSubmitCount, 1)
    XCTAssertEqual(recoveredResults.count, 1)
    XCTAssertNil(recoveredResults.first!)
    XCTAssertFalse(queue.hasPending)
  }

  func testOtaWriteQueueStaleEpisodeTimerCannotDriveNewPendingWrite() {
    let peripheral = FakeOtaPeripheral(endpointId: "g2-left", canSend: false)
    let scheduler = FakeOtaScheduler()
    var firstResults: [Any?] = []
    var secondResults: [Any?] = []
    var secondSubmitCount = 0
    let queue = OtaWriteQueue(
      peripheral: peripheral,
      scheduler: scheduler
    )

    queue.enqueue(data: Data([0x06]), target: makeFakeOtaTarget { _ in
      XCTFail("cancelled first episode must not submit")
      return true
    }) { value in
      firstResults.append(value)
    }
    queue.cancelAll(reason: "replace")
    queue.enqueue(data: Data([0x07]), target: makeFakeOtaTarget { _ in
      secondSubmitCount += 1
      return true
    }) { value in
      secondResults.append(value)
    }

    // 强制执行已取消的旧 block，验证 episode guard，而不是只依赖 scheduler cancel。
    scheduler.runNextIgnoringCancellation()
    XCTAssertEqual((firstResults.first as? FlutterError)?.code, "ota_write_cancelled")
    XCTAssertTrue(secondResults.isEmpty)
    XCTAssertEqual(secondSubmitCount, 0)
    XCTAssertTrue(queue.hasPending)

    peripheral.canSendWriteWithoutResponse = true
    queue.onPeripheralReadyToSendWriteWithoutResponse()

    XCTAssertEqual(secondSubmitCount, 1)
    XCTAssertEqual(secondResults.count, 1)
    XCTAssertNil(secondResults.first!)
  }

  func testOtaWriteQueueCompletesCancelledPendingWritesWithTypedFlutterError() {
    let peripheral = FakeOtaPeripheral(endpointId: "g2-left", canSend: false)
    var results: [Any?] = []
    let queue = OtaWriteQueue(
      peripheral: peripheral,
      scheduler: FakeOtaScheduler()
    )

    queue.enqueue(data: Data([0x04]), target: makeFakeOtaTarget { _ in
      XCTFail("cancelled write must not be submitted")
      return true
    }) { value in
      results.append(value)
    }
    queue.cancelAll(reason: "reset")

    let error = results.first as? FlutterError
    XCTAssertEqual(error?.code, "ota_write_cancelled")
    let details = error?.details as? [String: Any]
    XCTAssertEqual(details?["endpoint"] as? String, "g2-left")
    XCTAssertEqual(details?["reason"] as? String, "reset")
    XCTAssertEqual(details?["pending"] as? Int, 1)
  }

  func testOtaWriteQueueCompletesSubmitFailureWithUnavailableFlutterError() {
    let peripheral = FakeOtaPeripheral(endpointId: "g2-left")
    var results: [Any?] = []
    let queue = OtaWriteQueue(
      peripheral: peripheral,
      scheduler: FakeOtaScheduler()
    )

    queue.enqueue(data: Data([0x05]), target: makeFakeOtaTarget { _ in
      return false
    }) { value in
      results.append(value)
    }

    let error = results.first as? FlutterError
    XCTAssertEqual(error?.code, "ota_write_unavailable")
    let details = error?.details as? [String: Any]
    XCTAssertEqual(details?["endpoint"] as? String, "g2-left")
    XCTAssertEqual(details?["reason"] as? String, "peripheral released before submit")
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

  private func makeFakeOtaTarget(
    submit: @escaping (Data) -> Bool
  ) -> OtaWriteTarget {
    OtaWriteTarget(characteristicUUID: "OTA") { _, data in
      submit(data)
    }
  }

  func testG2OtaBeginIsIdempotentButRejectsTerminalScopeConflictAndEndpointOverlap() {
    let registry = BleG2OtaTransactionRegistry(nativeInstanceId: "native-A")
    let left = g2OtaScope(id: "tx-1", generation: 10, endpoints: ["left": (0, 0)])

    let first = registry.begin(data: left)
    XCTAssertEqual(first.status, .accepted)
    XCTAssertEqual(first.instanceId, "native-A")
    XCTAssertEqual(registry.begin(data: left).status, .accepted)

    var conflictingSameId = left
    conflictingSameId["generation"] = NSNumber(value: 11)
    XCTAssertEqual(registry.begin(data: conflictingSameId).status, .invalidRequest)

    let overlappingOtherId = g2OtaScope(id: "tx-2", generation: 12, endpoints: ["left": (0, 0), "right": (0, 0)])
    let overlap = registry.begin(data: overlappingOtherId)
    XCTAssertEqual(overlap.status, .invalidRequest)
    XCTAssertEqual(overlap.reason, "endpointAlreadyOwned")

    let finish = registry.commitPreparedFinish(data: g2OtaFinish(from: left, instanceId: "native-A", reason: "success"))
    XCTAssertEqual(finish.status, .committed)
    XCTAssertEqual(registry.begin(data: left).status, .alreadyCommitted)
    XCTAssertEqual(registry.begin(data: conflictingSameId).status, .invalidRequest)
  }

  func testG2OtaEndpointOwnershipIgnoresUnrelatedRingUuid() {
    let registry = BleG2OtaTransactionRegistry(nativeInstanceId: "native-A")
    let glasses = g2OtaScope(id: "tx-owned", generation: 10, endpoints: ["left": (0, 0), "right": (0, 0)])
    XCTAssertEqual(registry.begin(data: glasses).status, .accepted)

    XCTAssertTrue(registry.isEndpointOwned("left"))
    XCTAssertTrue(registry.isEndpointOwned("right"))
    XCTAssertFalse(registry.isEndpointOwned("r1-unrelated"))
    XCTAssertTrue(registry.shouldAllowLegacyCleanup(endpointId: "r1-unrelated"))

    let ringAdmission = registry.shouldAllowAdmission(
      endpointId: "r1-unrelated",
      otaContext: nil,
      purpose: .activation
    )
    XCTAssertTrue(ringAdmission.allowed)
    XCTAssertEqual(ringAdmission.reason, "")
  }

  func testG2OtaRegistryRejectsBoolFractionalAndNegativeIdentities() {
    let registry = BleG2OtaTransactionRegistry(nativeInstanceId: "native-A")
    var boolGeneration = g2OtaScope(id: "tx-bool", generation: 1, endpoints: ["left": (0, 0)])
    boolGeneration["generation"] = NSNumber(value: true)
    XCTAssertEqual(registry.begin(data: boolGeneration).status, .invalidRequest)

    var doubleWholeGeneration = g2OtaScope(id: "tx-double-whole", generation: 1, endpoints: ["left": (0, 0)])
    doubleWholeGeneration["generation"] = NSNumber(value: 10.0)
    XCTAssertEqual(registry.begin(data: doubleWholeGeneration).status, .invalidRequest)

    var fractionalGeneration = g2OtaScope(id: "tx-fraction", generation: 1, endpoints: ["left": (0, 0)])
    fractionalGeneration["generation"] = NSNumber(value: 1.5)
    XCTAssertEqual(registry.begin(data: fractionalGeneration).status, .invalidRequest)

    var overflowGeneration = g2OtaScope(id: "tx-overflow", generation: 1, endpoints: ["left": (0, 0)])
    overflowGeneration["generation"] = NSNumber(value: UInt64(Int64.max) + 1)
    XCTAssertEqual(registry.begin(data: overflowGeneration).status, .invalidRequest)

    let negativeEndpoint = g2OtaScope(id: "tx-negative", generation: 1, endpoints: ["left": (-1, 1)])
    XCTAssertEqual(registry.begin(data: negativeEndpoint).status, .invalidRequest)

    var boolEndpoint = g2OtaScope(id: "tx-bool-endpoint", generation: 1, endpoints: ["left": (0, 0)])
    if var endpoints = boolEndpoint["endpoints"] as? [[String: Any]] {
      endpoints[0]["sessionGeneration"] = NSNumber(value: true)
      boolEndpoint["endpoints"] = endpoints
    }
    XCTAssertEqual(registry.begin(data: boolEndpoint).status, .invalidRequest)

    var doubleEndpoint = g2OtaScope(id: "tx-double-endpoint", generation: 1, endpoints: ["left": (0, 0)])
    if var endpoints = doubleEndpoint["endpoints"] as? [[String: Any]] {
      endpoints[0]["attemptGeneration"] = NSNumber(value: 10.0)
      doubleEndpoint["endpoints"] = endpoints
    }
    XCTAssertEqual(registry.begin(data: doubleEndpoint).status, .invalidRequest)

    var fractionalEndpoint = g2OtaScope(id: "tx-fraction-endpoint", generation: 1, endpoints: ["left": (0, 0)])
    if var endpoints = fractionalEndpoint["endpoints"] as? [[String: Any]] {
      endpoints[0]["sessionGeneration"] = NSNumber(value: 10.5)
      endpoints[0]["attemptGeneration"] = NSNumber(value: 10)
      fractionalEndpoint["endpoints"] = endpoints
    }
    XCTAssertEqual(registry.begin(data: fractionalEndpoint).status, .invalidRequest)

    let halfPairEndpoint = g2OtaScope(id: "tx-half-pair", generation: 1, endpoints: ["left": (0, 1)])
    XCTAssertEqual(registry.begin(data: halfPairEndpoint).status, .invalidRequest)

    let valid = g2OtaScope(id: "tx-valid", generation: 2, endpoints: ["left": (0, 0)])
    let begin = registry.begin(data: valid)
    XCTAssertEqual(begin.status, .accepted)

    let negativeUpdate = g2OtaUpdate(from: valid, instanceId: begin.instanceId, uuid: "left", action: "bind", session: -1, attempt: 1)
    XCTAssertEqual(registry.update(data: negativeUpdate).status, .invalidRequest)

    var boolAttempt = g2OtaUpdate(from: valid, instanceId: begin.instanceId, uuid: "left", action: "bind", session: 1, attempt: 1)
    boolAttempt["attemptGeneration"] = NSNumber(value: true)
    XCTAssertEqual(registry.update(data: boolAttempt).status, .invalidRequest)
  }

  func testG2OtaRecoverPreservesRegisteredPhysicalOwner() {
    let registry = BleG2OtaTransactionRegistry(nativeInstanceId: "native-A")
    let scope = g2OtaScope(id: "tx-recover", generation: 10, endpoints: ["left": (4, 5), "right": (0, 0)])
    let begin = registry.begin(data: scope)
    XCTAssertEqual(begin.status, .accepted)

    let mismatchedRecover = registry.update(data: g2OtaUpdate(from: scope, instanceId: begin.instanceId, uuid: "left", action: "recover", session: 6, attempt: 7))
    XCTAssertEqual(mismatchedRecover.status, .staleOwner)
    XCTAssertEqual(mismatchedRecover.reason, "recoverPhysicalMismatch")

    let exactRecover = registry.update(data: g2OtaUpdate(from: scope, instanceId: begin.instanceId, uuid: "left", action: "recover", session: 4, attempt: 5))
    XCTAssertEqual(exactRecover.status, .accepted)

    let waitingRecover = registry.update(data: g2OtaUpdate(from: scope, instanceId: begin.instanceId, uuid: "right", action: "recover", session: 0, attempt: 0))
    XCTAssertEqual(waitingRecover.status, .accepted)
    let context = BleG2OtaContext(data: [
      "transactionId": "tx-recover",
      "generation": NSNumber(value: 10),
      "instanceId": begin.instanceId
    ])
    let writeGate = registry.shouldAllowAdmission(endpointId: "right", otaContext: context, purpose: .write)
    XCTAssertFalse(writeGate.allowed)
    XCTAssertEqual(writeGate.reason, "otaContextMissingPhysicalPair")

    let firstBoundRecover = registry.update(data: g2OtaUpdate(from: scope, instanceId: begin.instanceId, uuid: "right", action: "recover", session: 8, attempt: 9))
    XCTAssertEqual(firstBoundRecover.status, .invalidRequest)

    let replacedRecover = registry.update(data: g2OtaUpdate(from: scope, instanceId: begin.instanceId, uuid: "right", action: "recover", session: 9, attempt: 10))
    XCTAssertEqual(replacedRecover.status, .invalidRequest)
  }

  func testG2OtaParkRequiresActivePositiveExactPair() {
    let registry = BleG2OtaTransactionRegistry(nativeInstanceId: "native-A")
    let scope = g2OtaScope(id: "tx-park", generation: 10, endpoints: ["left": (0, 0)])
    let begin = registry.begin(data: scope)

    XCTAssertEqual(
      registry.update(data: g2OtaUpdate(from: scope, instanceId: begin.instanceId, uuid: "left", action: "park", session: 0, attempt: 0)).status,
      .invalidRequest
    )
    XCTAssertEqual(
      registry.update(data: g2OtaUpdate(from: scope, instanceId: begin.instanceId, uuid: "left", action: "park", session: 1, attempt: 1)).status,
      .invalidRequest
    )

    XCTAssertEqual(
      registry.update(data: g2OtaUpdate(from: scope, instanceId: begin.instanceId, uuid: "left", action: "recover", session: 0, attempt: 0)).status,
      .accepted
    )
    XCTAssertEqual(
      registry.update(data: g2OtaUpdate(from: scope, instanceId: begin.instanceId, uuid: "left", action: "park", session: 1, attempt: 1)).status,
      .invalidRequest
    )
    XCTAssertEqual(
      registry.update(data: g2OtaUpdate(from: scope, instanceId: begin.instanceId, uuid: "left", action: "bind", session: 1, attempt: 1)).status,
      .accepted
    )
    XCTAssertEqual(
      registry.update(data: g2OtaUpdate(from: scope, instanceId: begin.instanceId, uuid: "left", action: "park", session: 1, attempt: 1)).status,
      .accepted
    )
  }

  func testG2OtaFinishRequiresInstanceAndReplaysWithoutReleasingGateBeforeCommit() {
    let registry = BleG2OtaTransactionRegistry(nativeInstanceId: "native-A")
    let scope = g2OtaScope(id: "tx-finish", generation: 10, endpoints: ["left": (1, 1), "right": (2, 2)])
    let begin = registry.begin(data: scope)

    let stale = registry.prepareFinish(data: g2OtaFinish(from: scope, instanceId: "old-native", reason: "success"))
    XCTAssertEqual(stale.result.status, .staleOwner)

    let prepared = registry.prepareFinish(data: g2OtaFinish(from: scope, instanceId: begin.instanceId, reason: "success"))
    XCTAssertEqual(prepared.result.status, .committed)
    XCTAssertEqual(Set(prepared.endpointIds), Set(["left", "right"]))
    XCTAssertFalse(registry.shouldAllowAdmission(endpointId: "left", otaContext: nil, purpose: .activation).allowed)
    let finishingContext = BleG2OtaContext(data: [
      "transactionId": "tx-finish",
      "generation": NSNumber(value: 10),
      "instanceId": begin.instanceId
    ])
    XCTAssertEqual(
      registry.shouldAllowAdmission(endpointId: "left", otaContext: finishingContext, purpose: .write).reason,
      "otaContextEndpointRetiring"
    )
    XCTAssertEqual(
      registry.shouldAllowAdmission(endpointId: "left", otaContext: finishingContext, purpose: .activation).reason,
      "otaContextEndpointRetiring"
    )
    XCTAssertEqual(registry.prepareFinish(data: g2OtaFinish(from: scope, instanceId: begin.instanceId, reason: "success")).result.status, .committed)

    let committed = registry.commitPreparedFinish(data: g2OtaFinish(from: scope, instanceId: begin.instanceId, reason: "success"))
    XCTAssertEqual(committed.status, .committed)
    XCTAssertTrue(registry.shouldAllowAdmission(endpointId: "left", otaContext: nil, purpose: .activation).allowed)

    let replay = registry.commitPreparedFinish(data: g2OtaFinish(from: scope, instanceId: begin.instanceId, reason: "success"))
    XCTAssertEqual(replay.status, .alreadyCommitted)
    let staleReplay = registry.commitPreparedFinish(data: g2OtaFinish(from: scope, instanceId: "wrong-native", reason: "success"))
    XCTAssertEqual(staleReplay.status, .staleOwner)
    XCTAssertEqual(registry.query(data: ["transactionId": "tx-finish", "generation": NSNumber(value: 10), "instanceId": "wrong-native"]).status, .staleOwner)
    XCTAssertEqual(registry.query(data: ["transactionId": "tx-finish", "generation": NSNumber(value: 10), "instanceId": begin.instanceId]).status, .alreadyCommitted)
    let recreatedRegistry = BleG2OtaTransactionRegistry(nativeInstanceId: "native-B")
    let recreatedQuery = recreatedRegistry.query(data: ["transactionId": "tx-finish", "generation": NSNumber(value: 10), "instanceId": begin.instanceId])
    XCTAssertEqual(recreatedQuery.status, .invalidated)
    XCTAssertEqual(recreatedQuery.reason, "nativeInstanceRecreated")

    var conflict = scope
    conflict["generation"] = NSNumber(value: 11)
    XCTAssertEqual(registry.commitPreparedFinish(data: g2OtaFinish(from: conflict, instanceId: begin.instanceId, reason: "success")).status, .invalidRequest)

    let unackedScope = g2OtaScope(id: "tx-unacked-cancel", generation: 12, endpoints: ["lost-ack": (1, 2)])
    let unackedBegin = registry.begin(data: unackedScope)
    XCTAssertEqual(unackedBegin.status, .accepted)
    XCTAssertEqual(registry.prepareFinish(data: g2OtaFinish(from: unackedScope, instanceId: "", reason: "success")).result.status, .staleOwner)
    XCTAssertEqual(registry.prepareFinish(data: g2OtaFinish(from: unackedScope, instanceId: "", reason: "failed")).result.status, .staleOwner)
    let unackedCancel = registry.prepareFinish(data: g2OtaFinish(from: unackedScope, instanceId: "", reason: "cancelled"))
    XCTAssertEqual(unackedCancel.result.status, .committed)
    XCTAssertEqual(unackedCancel.result.instanceId, unackedBegin.instanceId)
    XCTAssertEqual(unackedCancel.endpointIds, ["lost-ack"])
    let unackedContext = BleG2OtaContext(data: [
      "transactionId": "tx-unacked-cancel",
      "generation": NSNumber(value: 12),
      "instanceId": unackedBegin.instanceId
    ])
    XCTAssertEqual(
      registry.shouldAllowAdmission(endpointId: "lost-ack", otaContext: unackedContext, purpose: .write).reason,
      "otaContextEndpointRetiring"
    )
    XCTAssertEqual(registry.commitPreparedFinish(data: g2OtaFinish(from: unackedScope, instanceId: "", reason: "cancelled")).status, .committed)
  }

  func testG2OtaWriteAdmissionDiffersFromActivationAdmission() {
    let registry = BleG2OtaTransactionRegistry(nativeInstanceId: "native-A")
    let scope = g2OtaScope(id: "tx-admit", generation: 10, endpoints: ["left": (0, 0)])
    let begin = registry.begin(data: scope)
    let context = BleG2OtaContext(data: [
      "transactionId": "tx-admit",
      "generation": NSNumber(value: 10),
      "instanceId": begin.instanceId
    ])

    XCTAssertTrue(registry.shouldAllowAdmission(endpointId: "left", otaContext: context, purpose: .activation).allowed)
    XCTAssertFalse(registry.shouldAllowAdmission(endpointId: "left", otaContext: context, purpose: .write).allowed)

    XCTAssertEqual(
      registry.update(data: g2OtaUpdate(from: scope, instanceId: begin.instanceId, uuid: "left", action: "bind", session: 1, attempt: 1)).status,
      .accepted
    )
    XCTAssertTrue(registry.shouldAllowAdmission(endpointId: "left", otaContext: context, purpose: .write).allowed)
  }

  func testG2OtaNativeBeginPolicyRequiresNativeKnownTargetsAndExactLivePairs() {
    guard let scope = BleG2OtaTransactionScope(data: g2OtaScope(id: "tx-native-begin", generation: 10, endpoints: [
      "left": (11, 12),
      "right": (0, 0)
    ])) else {
      XCTFail("scope should parse")
      return
    }

    let accepted: [String: BleG2OtaNativeEndpointState] = [
      "left": BleG2OtaNativeEndpointState(
        uuid: "left",
        name: "Even left",
        belongConfig: "Even-G2",
        isNativeKnown: true,
        isBusinessConnected: true,
        isPeripheralConnected: true,
        sessionGeneration: 11,
        attemptGeneration: 12
      ),
      "right": BleG2OtaNativeEndpointState(
        uuid: "right",
        name: "Even right",
        belongConfig: "Even-G2",
        isNativeKnown: true,
        isBusinessConnected: false,
        isPeripheralConnected: false,
        sessionGeneration: 0,
        attemptGeneration: 0
      )
    ]
    XCTAssertNil(BleG2OtaNativeBeginPolicy.rejectionReason(scope: scope, states: accepted))

    var missingWaiting = accepted
    missingWaiting["right"] = BleG2OtaNativeEndpointState(
      uuid: "right",
      name: "Even right",
      belongConfig: "Even-G2",
      isNativeKnown: false,
      isBusinessConnected: false,
      isPeripheralConnected: false,
      sessionGeneration: 0,
      attemptGeneration: 0
    )
    XCTAssertEqual(BleG2OtaNativeBeginPolicy.rejectionReason(scope: scope, states: missingWaiting), "nativeEndpointUnknown")

    var stalePositivePair = accepted
    stalePositivePair["left"] = BleG2OtaNativeEndpointState(
      uuid: "left",
      name: "Even left",
      belongConfig: "Even-G2",
      isNativeKnown: true,
      isBusinessConnected: true,
      isPeripheralConnected: true,
      sessionGeneration: 11,
      attemptGeneration: 13
    )
    XCTAssertEqual(BleG2OtaNativeBeginPolicy.rejectionReason(scope: scope, states: stalePositivePair), "nativePhysicalOwnerMismatch")
  }

  func testG2OtaNativeUpdateUsesConfigFrozenByBeginWhenWirePayloadOmitsConfig() {
    let manager = BleManager.shared
    let uuid = "OTA-BIND-\(UUID().uuidString)"
    let scope = g2OtaScope(
      id: "tx-native-bind-\(UUID().uuidString)",
      generation: 10,
      endpoints: [uuid: (0, 0)]
    )
    let begin = manager.g2OtaTransactions.begin(data: scope)
    XCTAssertEqual(begin.status, .accepted)
    defer {
      _ = manager.g2OtaTransactions.clearActive(reason: .revoked)
      manager.upgradeStateRegistry.consume(uuid)
    }

    // This is the production MethodChannel shape: config/SN/endpoints are
    // frozen by begin and are intentionally not repeated on endpoint updates.
    let update: [String: Any] = [
      "transactionId": begin.transactionId,
      "generation": NSNumber(value: begin.generation),
      "instanceId": begin.instanceId,
      "uuid": uuid,
      "action": "bind",
      "sessionGeneration": NSNumber(value: 41),
      "attemptGeneration": NSNumber(value: 42)
    ]

    let result = manager.updateG2OtaEndpoint(update)
    XCTAssertEqual(result.status, .staleOwner)
    XCTAssertEqual(result.reason, "nativePhysicalOwnerMismatch")
  }

  func testG2OtaConfigPolicyRequiresProductionOtaPrivateService() {
    XCTAssertTrue(BleG2OtaConfigPolicy.supportsG2Ota(privateServices: [
      (type: 0, service: "0000180A-0000-1000-8000-00805F9B34FB"),
      (type: 1, service: "00002760-08C2-11E1-9073-0E8AC72E1001")
    ]))
    XCTAssertFalse(BleG2OtaConfigPolicy.supportsG2Ota(privateServices: [
      (type: 1, service: "00009999-08C2-11E1-9073-0E8AC72E1001")
    ]))
    XCTAssertFalse(BleG2OtaConfigPolicy.supportsG2Ota(privateServices: [
      (type: 0, service: "00002760-08C2-11E1-9073-0E8AC72E1001")
    ]))
  }

  func testG2OtaRecoveryGrantAllowsNativeNoDeviceRetryUntilTransactionInvalidates() {
    let manager = BleManager.shared
    let uuid = "OTA-NODEVICE-\(UUID().uuidString)"
    let scope = g2OtaScope(id: "tx-native-retry-\(UUID().uuidString)", generation: 90, endpoints: [uuid: (0, 0)])
    let begin = manager.g2OtaTransactions.begin(data: scope)
    XCTAssertEqual(begin.status, .accepted)
    manager.upgradeStateRegistry.enter(uuid)
    defer {
      _ = manager.g2OtaTransactions.clearActive(reason: .revoked)
      manager.upgradeStateRegistry.consume(uuid)
      manager.cancelReconnectTask(uuid: uuid, name: "Even \(uuid)")
      manager.reconnectStore.remove(uuid: uuid, name: "Even \(uuid)")
    }

    let context = BleG2OtaContext(data: [
      "transactionId": begin.transactionId,
      "generation": NSNumber(value: begin.generation),
      "instanceId": begin.instanceId
    ])
    var task = BleReconnectTask(
      belongConfig: "g2_glasses",
      uuid: uuid,
      name: "Even \(uuid)",
      source: .autoReconnect
    )
    task.g2OtaRecoveryContext = context
    task.g2OtaRecoveryEndpointId = uuid

    let admitted = manager.otaReconnectSchedulingAdmission(task: task, observedUuid: uuid)
    XCTAssertTrue(admitted.allowed)
    XCTAssertTrue(admitted.isOtaGranted)
    let migratedPeripheralRetry = manager.otaReconnectSchedulingAdmission(task: task, observedUuid: UUID().uuidString)
    XCTAssertTrue(migratedPeripheralRetry.allowed)
    XCTAssertTrue(migratedPeripheralRetry.isOtaGranted)

    manager.reconnectTasks[uuid.lowercased()] = task
    let contexts = manager.g2OtaTransactions.endpointContexts(endpointIds: [uuid])
    manager.clearG2OtaRecoveryGrants(contextsByEndpoint: contexts)
    let clearedTask = manager.reconnectTasks[uuid.lowercased()]
    XCTAssertNil(clearedTask?.g2OtaRecoveryContext)
    XCTAssertNil(clearedTask?.g2OtaRecoveryEndpointId)

    let committed = manager.g2OtaTransactions.commitPreparedFinish(data: g2OtaFinish(from: scope, instanceId: begin.instanceId, reason: "cancelled"))
    XCTAssertEqual(committed.status, .committed)
    manager.upgradeStateRegistry.consume(uuid)
    let afterFinish = manager.otaReconnectSchedulingAdmission(task: clearedTask!, observedUuid: uuid)
    XCTAssertTrue(afterFinish.allowed)
    XCTAssertFalse(afterFinish.isOtaGranted)

    var legacyTask = clearedTask!
    legacyTask.g2OtaRecoveryContext = nil
    legacyTask.g2OtaRecoveryEndpointId = nil
    let legacyAfterFinish = manager.otaReconnectSchedulingAdmission(task: legacyTask, observedUuid: uuid)
    XCTAssertTrue(legacyAfterFinish.allowed)
    XCTAssertFalse(legacyAfterFinish.isOtaGranted)
  }

  func testG2OtaRetirementPolicyKeepsGateClosedAndConsumesLateCallbacks() {
    let registry = BleG2OtaTransactionRegistry(nativeInstanceId: "native-A")
    let scope = g2OtaScope(id: "tx-retire", generation: 10, endpoints: ["left": (21, 22)])
    let begin = registry.begin(data: scope)
    XCTAssertEqual(begin.status, .accepted)
    XCTAssertEqual(registry.update(data: g2OtaUpdate(from: scope, instanceId: begin.instanceId, uuid: "left", action: "bind", session: 21, attempt: 22)).status, .accepted)

    let prepared = registry.prepareFinish(data: g2OtaFinish(from: scope, instanceId: begin.instanceId, reason: "success"))
    XCTAssertEqual(prepared.result.status, .committed)
    XCTAssertFalse(registry.shouldAllowAdmission(endpointId: "left", otaContext: nil, purpose: .activation).allowed)
    let snapshot = registry.endpointSnapshots(endpointIds: ["left"])["left"]
    let finishDecision = BleG2OtaRetirementPolicy.decide(
      snapshot: snapshot,
      state: BleG2OtaRetirementEndpointState(
        uuid: "left",
        hasConnectedCache: true,
        isPeripheralConnected: true,
        sessionGeneration: 21,
        attemptGeneration: 22
      )
    )
    XCTAssertEqual(finishDecision, BleG2OtaRetirementDecision(
      shouldClearLocalState: true,
      shouldIsolateCache: true,
      shouldInstallCancellationBarrier: true,
      shouldCancelPeripheral: true
    ))

    let gattReleasedDecision = BleG2OtaRetirementPolicy.decide(
      snapshot: snapshot,
      state: BleG2OtaRetirementEndpointState(
        uuid: "left",
        hasConnectedCache: false,
        isPeripheralConnected: false,
        sessionGeneration: 0,
        attemptGeneration: 0
      )
    )
    XCTAssertEqual(gattReleasedDecision, BleG2OtaRetirementDecision(
      shouldClearLocalState: true,
      shouldIsolateCache: false,
      shouldInstallCancellationBarrier: false,
      shouldCancelPeripheral: false
    ))

    let barrier = BlePeripheralCancellationBarrierGate()
    XCTAssertEqual(barrier.begin(endpointId: "left")?.isNew, true)
    XCTAssertTrue(barrier.isBlocking(endpointId: "left"))
    XCTAssertEqual(barrier.consumeCallback(endpointId: "left"), .activeBarrier(1))
    XCTAssertFalse(barrier.isBlocking(endpointId: "left"))

    let committed = registry.commitPreparedFinish(data: g2OtaFinish(from: scope, instanceId: begin.instanceId, reason: "success"))
    XCTAssertEqual(committed.status, .committed)
    XCTAssertTrue(registry.shouldAllowAdmission(endpointId: "left", otaContext: nil, purpose: .activation).allowed)

    let lateDecision = BleG2OtaRetirementPolicy.decide(
      snapshot: snapshot,
      state: BleG2OtaRetirementEndpointState(
        uuid: "left",
        hasConnectedCache: true,
        isPeripheralConnected: true,
        sessionGeneration: 21,
        attemptGeneration: 23
      )
    )
    XCTAssertEqual(lateDecision, BleG2OtaRetirementDecision(
      shouldClearLocalState: false,
      shouldIsolateCache: false,
      shouldInstallCancellationBarrier: false,
      shouldCancelPeripheral: false
    ))

    let parkedScope = g2OtaScope(id: "tx-park-retire", generation: 11, endpoints: ["right": (31, 32)])
    let parkedBegin = registry.begin(data: parkedScope)
    XCTAssertEqual(parkedBegin.status, .accepted)
    XCTAssertEqual(registry.update(data: g2OtaUpdate(from: parkedScope, instanceId: parkedBegin.instanceId, uuid: "right", action: "bind", session: 31, attempt: 32)).status, .accepted)
    XCTAssertEqual(registry.update(data: g2OtaUpdate(from: parkedScope, instanceId: parkedBegin.instanceId, uuid: "right", action: "park", session: 31, attempt: 32)).status, .accepted)
    let parkedContext = BleG2OtaContext(data: [
      "transactionId": "tx-park-retire",
      "generation": NSNumber(value: 11),
      "instanceId": parkedBegin.instanceId
    ])
    XCTAssertFalse(registry.shouldAllowAdmission(endpointId: "right", otaContext: parkedContext, purpose: .write).allowed)
    let parkedSnapshot = registry.endpointSnapshots(endpointIds: ["right"])["right"]
    XCTAssertEqual(parkedSnapshot?.phase, .parked)
    let parkedDecision = BleG2OtaRetirementPolicy.decide(
      snapshot: parkedSnapshot,
      state: BleG2OtaRetirementEndpointState(
        uuid: "right",
        hasConnectedCache: true,
        isPeripheralConnected: true,
        sessionGeneration: 31,
        attemptGeneration: 32
      )
    )
    XCTAssertEqual(parkedDecision, BleG2OtaRetirementDecision(
      shouldClearLocalState: true,
      shouldIsolateCache: true,
      shouldInstallCancellationBarrier: true,
      shouldCancelPeripheral: true
    ))
  }

  func testG2OtaFinishOrchestratorRejectsReentrantWorkAndReplaysWithoutSideEffects() {
    let registry = BleG2OtaTransactionRegistry(nativeInstanceId: "native-A")
    let scope = g2OtaScope(id: "tx-orchestrated-finish", generation: 20, endpoints: [
      "left": (101, 102),
      "right": (201, 202)
    ])
    let begin = registry.begin(data: scope)
    XCTAssertEqual(begin.status, .accepted)
    XCTAssertEqual(registry.update(data: g2OtaUpdate(from: scope, instanceId: begin.instanceId, uuid: "left", action: "bind", session: 101, attempt: 102)).status, .accepted)
    XCTAssertEqual(registry.update(data: g2OtaUpdate(from: scope, instanceId: begin.instanceId, uuid: "right", action: "bind", session: 201, attempt: 202)).status, .accepted)
    let context = BleG2OtaContext(data: [
      "transactionId": begin.transactionId,
      "generation": NSNumber(value: begin.generation),
      "instanceId": begin.instanceId
    ])
    var retireCalls = 0
    var wakeCalls = 0
    var retiredEndpointCounts: [Int] = []

    let result = BleG2OtaFinishOrchestrator.finish(
      data: g2OtaFinish(from: scope, instanceId: begin.instanceId, reason: "success"),
      registry: registry,
      retire: { endpointIds, snapshots, contextsByEndpoint, _ in
        retireCalls += 1
        retiredEndpointCounts.append(endpointIds.count)
        XCTAssertEqual(Set(endpointIds), Set(["left", "right"]))
        XCTAssertEqual(Set(snapshots.keys), Set(["left", "right"]))
        XCTAssertEqual(Set(contextsByEndpoint.keys), Set(["left", "right"]))
        XCTAssertEqual(
          registry.shouldAllowAdmission(endpointId: "left", otaContext: context, purpose: .write).reason,
          "otaContextEndpointRetiring"
        )
        XCTAssertEqual(
          registry.shouldAllowAdmission(endpointId: "right", otaContext: context, purpose: .activation).reason,
          "otaContextEndpointRetiring"
        )
        // Recover is rejected while finish has atomically moved the group into
        // retiring.  The exact failure status may reflect either the retiring
        // phase or the now-invalid recovery ownership, but it must never accept
        // a new transport transition between prepare and commit.
        XCTAssertNotEqual(
          registry.update(data: g2OtaUpdate(from: scope, instanceId: begin.instanceId, uuid: "left", action: "recover", session: 101, attempt: 102)).status,
          .accepted
        )
        XCTAssertEqual(
          registry.prepareFinish(data: g2OtaFinish(from: scope, instanceId: begin.instanceId, reason: "success")).result.status,
          .committed
        )
      },
      wake: { endpointIds in
        wakeCalls += 1
        XCTAssertEqual(Set(endpointIds), Set(["left", "right"]))
      }
    )
    XCTAssertEqual(result.status, .committed)
    XCTAssertEqual(retireCalls, 1)
    XCTAssertEqual(wakeCalls, 1)
    XCTAssertEqual(retiredEndpointCounts, [2])

    let replay = BleG2OtaFinishOrchestrator.finish(
      data: g2OtaFinish(from: scope, instanceId: begin.instanceId, reason: "success"),
      registry: registry,
      retire: { _, _, _, _ in retireCalls += 1 },
      wake: { _ in wakeCalls += 1 }
    )
    XCTAssertEqual(replay.status, .alreadyCommitted)
    XCTAssertEqual(retireCalls, 1)
    XCTAssertEqual(wakeCalls, 1)
  }

  func testG2OtaFinishOrchestratorWakesOnlyReconnectableReasons() {
    let reasons = ["success", "failed", "cancelled", "revoked"]
    var wakeCountsByReason: [String: Int] = [:]

    for (index, reason) in reasons.enumerated() {
      let registry = BleG2OtaTransactionRegistry(nativeInstanceId: "native-A")
      let scope = g2OtaScope(id: "tx-finish-reason-\(reason)", generation: Int64(30 + index), endpoints: [
        "left": (Int64(301 + index), Int64(401 + index))
      ])
      let begin = registry.begin(data: scope)
      XCTAssertEqual(begin.status, .accepted)
      XCTAssertEqual(registry.update(data: g2OtaUpdate(from: scope, instanceId: begin.instanceId, uuid: "left", action: "bind", session: Int64(301 + index), attempt: Int64(401 + index))).status, .accepted)

      var retireCalls = 0
      var wakeCalls = 0
      let result = BleG2OtaFinishOrchestrator.finish(
        data: g2OtaFinish(from: scope, instanceId: begin.instanceId, reason: reason),
        registry: registry,
        retire: { endpointIds, snapshots, contextsByEndpoint, _ in
          retireCalls += 1
          XCTAssertEqual(endpointIds, ["left"])
          XCTAssertEqual(Set(snapshots.keys), Set(["left"]))
          XCTAssertEqual(Set(contextsByEndpoint.keys), Set(["left"]))
        },
        wake: { endpointIds in
          wakeCalls += 1
          XCTAssertEqual(endpointIds, ["left"])
        }
      )
      XCTAssertEqual(result.status, .committed)
      XCTAssertEqual(retireCalls, 1)
      wakeCountsByReason[reason] = wakeCalls
    }

    XCTAssertEqual(wakeCountsByReason["success"], 1)
    XCTAssertEqual(wakeCountsByReason["failed"], 1)
    XCTAssertEqual(wakeCountsByReason["cancelled"], 1)
    XCTAssertEqual(wakeCountsByReason["revoked"], 0)
  }

  private func g2OtaScope(
    id: String,
    generation: Int64,
    endpoints: [String: (Int64, Int64)]
  ) -> [String: Any] {
    [
      "transactionId": id,
      "generation": NSNumber(value: generation),
      "config": "Even-G2",
      "sn": "S200LABK140060",
      "endpoints": endpoints.map { uuid, pair in
        [
          "uuid": uuid,
          "name": "Even \(uuid)",
          "sessionGeneration": NSNumber(value: pair.0),
          "attemptGeneration": NSNumber(value: pair.1)
        ] as [String: Any]
      }
    ]
  }

  private func g2OtaUpdate(
    from scope: [String: Any],
    instanceId: String,
    uuid: String,
    action: String,
    session: Int64,
    attempt: Int64
  ) -> [String: Any] {
    var data = scope
    data["instanceId"] = instanceId
    data["uuid"] = uuid
    data["action"] = action
    data["sessionGeneration"] = NSNumber(value: session)
    data["attemptGeneration"] = NSNumber(value: attempt)
    return data
  }

  private func g2OtaFinish(
    from scope: [String: Any],
    instanceId: String,
    reason: String
  ) -> [String: Any] {
    var data = scope
    data["instanceId"] = instanceId
    data["reason"] = reason
    return data
  }

}

private final class FakeOtaPeripheral: OtaWritePeripheral {
  let otaEndpointId: String
  var canSendWriteWithoutResponse: Bool

  init(endpointId: String, canSend: Bool = true) {
    self.otaEndpointId = endpointId
    self.canSendWriteWithoutResponse = canSend
  }
}

private final class FakeOtaClock: OtaWriteClock {
  private(set) var now = Date(timeIntervalSince1970: 0)

  func advance(by interval: TimeInterval) {
    now = now.addingTimeInterval(interval)
  }
}

private final class FakeOtaCancellable: OtaWriteCancellable {
  private(set) var isCancelled = false

  func cancel() {
    isCancelled = true
  }
}

private final class FakeOtaScheduler: OtaWriteScheduler {
  private var blocks: [(FakeOtaCancellable, () -> Void)] = []

  func schedule(after interval: TimeInterval, _ block: @escaping () -> Void) -> OtaWriteCancellable {
    let cancellable = FakeOtaCancellable()
    blocks.append((cancellable, block))
    return cancellable
  }

  func runNext() {
    guard !blocks.isEmpty else {
      return
    }
    let (cancellable, block) = blocks.removeFirst()
    if !cancellable.isCancelled {
      block()
    }
  }

  func runNextIgnoringCancellation() {
    guard !blocks.isEmpty else {
      return
    }
    let (_, block) = blocks.removeFirst()
    block()
  }
}
