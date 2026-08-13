import Flutter
import UIKit
import XCTest


@testable import flutter_ezw_ble

// This demonstrates a simple unit test of the Swift portion of this plugin's implementation.
//
// See https://developer.apple.com/documentation/xctest for more information about using XCTest.

class RunnerTests: XCTestCase {

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

  func testStateRestorationEscrowRearmsDisconnectedLeftLegBeforeClaim() {
    let escrow = BleStateRestorationEscrowStateMachine()
    let left = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"

    XCTAssertEqual(
      escrow.stage(endpointId: left, peripheralState: .connected),
      .holdConnected
    )
    XCTAssertEqual(
      escrow.didTerminate(endpointId: left, systemIsReconnecting: false),
      .rearm
    )
    XCTAssertEqual(escrow.didConnect(endpointId: left), .holdConnected)
    XCTAssertEqual(escrow.claim(endpointId: left), .connected)
    XCTAssertEqual(escrow.countForTesting, 0)
  }

  func testStateRestorationEscrowKeepsSystemReconnectAndBoundsThreeEndpoints() {
    let escrow = BleStateRestorationEscrowStateMachine()
    let endpoints = ["g2-left", "g2-right", "r1"]
    endpoints.forEach {
      XCTAssertEqual(
        escrow.stage(endpointId: $0, peripheralState: .connecting),
        .keepPending
      )
    }
    XCTAssertEqual(escrow.countForTesting, 3)
    XCTAssertEqual(
      escrow.didTerminate(endpointId: "g2-left", systemIsReconnecting: true),
      .keepPending
    )
    XCTAssertEqual(escrow.claim(endpointId: "g2-right"), .pending)
    XCTAssertEqual(escrow.didConnect(endpointId: "historical"), .ignore)
    escrow.remove(endpointIds: Set(["g2-left", "r1"]))
    XCTAssertEqual(escrow.countForTesting, 0)
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

  func testOtaWriteQueueCompletesStalledBackpressureWithTypedFlutterError() {
    let peripheral = FakeOtaPeripheral(endpointId: "g2-left", canSend: false)
    let clock = FakeOtaClock()
    let scheduler = FakeOtaScheduler()
    var results: [Any?] = []
    let queue = OtaWriteQueue(
      peripheral: peripheral,
      clock: clock,
      scheduler: scheduler
    )

    queue.enqueue(data: Data([0x03]), target: makeFakeOtaTarget { _ in
      XCTFail("stalled write must not be submitted")
      return true
    }) { value in
      results.append(value)
    }
    clock.advance(by: 4.1)
    scheduler.runNext()

    let error = results.first as? FlutterError
    XCTAssertEqual(error?.code, "ota_write_stalled")
    let details = error?.details as? [String: Any]
    XCTAssertEqual(details?["endpoint"] as? String, "g2-left")
    XCTAssertEqual(details?["reason"] as? String, "canSend=false")
    XCTAssertEqual(details?["pending"] as? Int, 1)
    XCTAssertGreaterThanOrEqual(details?["wait"] as? TimeInterval ?? 0, 4.0)
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
}
