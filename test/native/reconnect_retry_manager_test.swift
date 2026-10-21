import Foundation

/// This executes the actual production schedule/begin/defer/error registration
/// functions compiled against platform timer/clock/dispatch spies.
@main
struct ReconnectRetryManagerTests {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) { precondition(condition(), message) }
    /// A terminal manual attempt must only keep its own admission source. The
    /// durable owner becomes automatic before any shared retry gate reloads it.
    static func terminalSourceResetScenarios() {
        for scenario in ["immediate", "Code1", "expired escrow", "inactive", "Bluetooth off", "preserved manual"] {
            let manager = BleManager()
            let key = UUID().uuidString
            let peripheral = CBPeripheral(UUID(uuidString: key)!)
            var task = BleReconnectTask(belongConfig: "g2", uuid: key, name: "left")
            task.source = .manualReconnect
            task.sessionGeneration = 27
            manager.reconnectTasks[key] = task
            let admission = BleConnectionAdmission(endpointId: key, sessionId: 91, sessionGeneration: task.sessionGeneration, source: .manualReconnect)
            manager.admissions[key] = admission
            if scenario == "Code1" {
                manager.registerInvalidParametersFailure(peripheral: peripheral, error: NSError(domain: "CBErrorDomain", code: 1), sessionGeneration: task.sessionGeneration)
            }
            if scenario == "expired escrow" {
                var debt = BleInvalidParametersBackoff()
                debt.registerFailure(now: ProcessInfo.processInfo.systemUptime - 10)
                manager.restorationCoordinator.debt = debt
            }
            manager.inactiveWithoutObject = scenario == "inactive"
            manager.centralManager.state = scenario == "Bluetooth off" ? .poweredOff : .poweredOn
            let preserveManual = scenario == "preserved manual"
            let expectedSource: BleConnectSource = preserveManual ? .manualReconnect : .autoReconnect
            manager.scheduleReconnect(uuid: key, name: "left", state: .disconnectFromSys, preserveAttemptSource: preserveManual)
            let stored = manager.reconnectTasks[key]!
            require(stored.source == expectedSource, "\(scenario): terminal source reset lost before shared gate")
            require(stored.ownerToken == task.ownerToken && stored.sessionGeneration == 27, "\(scenario): source reset replaced the positive-session owner")
            require(manager.admissions[key] == admission && manager.admissions[key]!.source == .manualReconnect, "\(scenario): source reset rewrote the current physical admission")
            require(manager.directReconnectStarts.isEmpty, "\(scenario): dispatched before queue/deadline/defer handling")
            if scenario == "Code1" {
                require(stored.invalidParametersBackoff.failureCount == 1 && stored.timer != nil, "Code1: terminal source reset lost retry debt/job")
                ProcessInfo.processInfo.advance(0.999)
                require(manager.directReconnectStarts.isEmpty, "Code1: source reset bypassed deadline")
                ProcessInfo.processInfo.advance(0.002)
            } else if scenario == "inactive" {
                require(stored.deferredByAppInactivity, "inactive: automatic owner was not retained for later activation")
                manager.inactiveWithoutObject = false
                manager.beginReconnectAttempt(uuid: key)
            } else if scenario == "Bluetooth off" {
                require(stored.pausedByBluetoothOff && stored.recoveryEpoch == manager.currentTransportRecoveryEpoch, "Bluetooth off: source reset lost paused transport owner")
                DispatchQueue.main.drain()
                manager.beginReconnectAttempt(uuid: key)
                require(manager.directReconnectStarts.isEmpty, "Bluetooth off: paused source reset opened an attempt")
                continue
            } else {
                DispatchQueue.main.drain()
            }
            require(manager.directReconnectStarts.count == 1, "\(scenario): terminal retry did not reach one actual beginDirect call")
            let started = manager.directReconnectStarts[0]
            require(started.source == expectedSource && started.ownerToken == task.ownerToken && started.sessionGeneration == 27, "\(scenario): actual beginDirect received stale source or owner")
            require(manager.admissions[key] == admission, "\(scenario): next attempt scheduling mutated the previous admission")
            if scenario == "expired escrow" {
                require(started.invalidParametersBackoff.failureCount == 1, "expired escrow: source reset overwrote merged debt")
                manager.restorationCoordinator.debt = nil
                manager.registerInvalidParametersFailure(peripheral: peripheral, error: NSError(domain: "CBErrorDomain", code: 1), sessionGeneration: task.sessionGeneration)
                require(manager.reconnectTasks[key]!.invalidParametersBackoff.remaining(now: ProcessInfo.processInfo.systemUptime) == 2, "expired escrow: next Code1 did not retain its episode")
            }
        }
        print("PASS: terminal source reset survives immediate/Code1/expired escrow/inactive/off gates; explicit manual preservation and current admission source remain exact")
    }

    static func main() {
        terminalSourceResetScenarios()
        let manager = BleManager()
        let uuid = UUID()
        let key = uuid.uuidString
        let peripheral = CBPeripheral(uuid)
        var task = BleReconnectTask(belongConfig: "g2", uuid: key, name: "left")
        manager.reconnectTasks[key] = task
        var expectedStarts = 0
        for delay: TimeInterval in [1, 2, 4, 8, 16, 30, 30] {
            manager.registerInvalidParametersFailure(peripheral: peripheral, error: NSError(domain: "CBErrorDomain", code: 1), sessionGeneration: task.sessionGeneration)
            manager.scheduleReconnect(uuid: key, name: "left", state: .disconnectFromSys)
            for _ in 0..<50 { manager.beginReconnectAttempt(uuid: key) }
            require(manager.physicalStarts.count == expectedStarts, "production entry bypassed deadline")
            require(ProcessInfo.processInfo.timers.filter { !$0.cancelled }.count == 1, "multiple live jobs")
            ProcessInfo.processInfo.advance(delay - 0.001)
            require(manager.physicalStarts.count == expectedStarts, "production timer fired early")
            ProcessInfo.processInfo.advance(0.002)
            expectedStarts += 1
            require(manager.physicalStarts.count == expectedStarts, "production timer did not dispatch once")
        }
        task = manager.reconnectTasks[key]!
        let debt = task.invalidParametersBackoff.failureCount
        // A stale attempt cannot extend the new session's Code 1 episode.
        task.sessionGeneration += 1
        manager.reconnectTasks[key] = task
        manager.registerInvalidParametersFailure(peripheral: peripheral, error: NSError(domain: "CBErrorDomain", code: 1), sessionGeneration: task.sessionGeneration - 1)
        require(manager.reconnectTasks[key]!.invalidParametersBackoff.failureCount == debt, "stale attempt polluted new session")
        manager.registerInvalidParametersFailure(peripheral: peripheral, error: NSError(domain: "CBErrorDomain", code: 1), sessionGeneration: task.sessionGeneration)
        manager.beginReconnectAttempt(uuid: key)
        task = manager.reconnectTasks[key]!
        let oldJob = task.timer!
        // Same UUID and same session after cancel still represents a new owner.
        var replacement = BleReconnectTask(belongConfig: "g2", uuid: key, name: "left")
        replacement.sessionGeneration = task.sessionGeneration
        manager.reconnectTasks[key] = replacement
        oldJob.callback(oldJob)
        require(manager.physicalStarts.count == expectedStarts, "late cancelled timer drove replacement owner")
        manager.reconnectTasks[key] = task
        manager.beginReconnectAttempt(uuid: key)
        let beforeReset = manager.reconnectTasks[key]!.timer!
        manager.currentTransportRecoveryEpoch += 1
        beforeReset.callback(beforeReset)
        require(manager.physicalStarts.count == expectedStarts, "old epoch timer drove newer transport")
        manager.reconnectTasks.removeAll()
        beforeReset.callback(beforeReset)
        require(manager.physicalStarts.count == expectedStarts, "hard cancelled owner resurrected")
        // The timer may fire once to the deadline; no object means defer without
        // a new noDeviceFound timer or a physical attempt.
        manager.reconnectTasks[key] = task
        manager.inactiveWithoutObject = true
        manager.beginReconnectAttempt(uuid: key)
        ProcessInfo.processInfo.advance(31)
        require(manager.physicalStarts.count == expectedStarts, "inactive missing object connected")
        require(manager.reconnectTasks[key]!.deferredByAppInactivity, "inactive missing object not retained")
        require(ProcessInfo.processInfo.timers.filter { !$0.cancelled }.isEmpty, "inactive owner polled")
        // Foreground/queued paths may register request+admission before physical
        // dispatch. Deadline rejection must retire the exact untouched attempt.
        manager.inactiveWithoutObject = false
        task = BleReconnectTask(belongConfig: "g2", uuid: key, name: "left")
        manager.reconnectTasks[key] = task
        manager.registerInvalidParametersFailure(peripheral: peripheral, error: NSError(domain: "CBErrorDomain", code: 1), sessionGeneration: task.sessionGeneration)
        let admission = BleConnectionAdmission(endpointId: key, sessionId: 90, sessionGeneration: task.sessionGeneration)
        manager.admissions[key] = admission
        manager.peripheralConnectionSessions[90] = BlePeripheralConnectionSession(peripheral: peripheral, deviceName: "left")
        manager.drivePeripheralConnection(peripheral, expectedAdmission: admission, autoReconnect: true, remainingStateChecks: 10, reason: "foreground")
        require(manager.admissions[key] == nil && manager.removedRequests == 1, "rejected dispatch left phantom owner")
        require(manager.watchdogStarts == 0 && manager.centralManager.connectStarts == 0, "rejected dispatch started watchdog or connect")
        ProcessInfo.processInfo.advance(1.001)
        require(manager.physicalStarts.count == expectedStarts + 1, "retired attempt blocked later retry")
        // An old object's late cleanup must not remove the new exact owner.
        let replacementPeripheral = CBPeripheral(uuid)
        manager.admissions[key] = admission
        manager.peripheralConnectionSessions[90] = BlePeripheralConnectionSession(peripheral: replacementPeripheral, deviceName: "left")
        manager.retireUndispatchedReconnectAttempt(peripheral, deferredForObject: true)
        require(manager.admissions[key] != nil && manager.removedRequests == 1, "old cleanup removed replacement object owner")
        manager.peripheralValidity.observe(replacementPeripheral)
        manager.peripheralValidity.observeTransportState(rawValue: 1)
        manager.drivePeripheralConnection(replacementPeripheral, expectedAdmission: admission, autoReconnect: true, remainingStateChecks: 10, reason: "invalid object")
        require(manager.admissions[key] == nil && manager.reconnectTasks[key]!.deferredByAppInactivity, "invalid object did not retire/defer exact owner")
        require(manager.watchdogStarts == 0 && manager.centralManager.connectStarts == 0, "invalid object reached connect")
        // A valid advertisement is an identity-checked wake-up, not permission
        // to clear the endpoint's retry debt or the reset/session barrier.
        manager.peripheralValidity.observe(replacementPeripheral)
        var freshTask = manager.reconnectTasks[key]!
        freshTask.deferredByAppInactivity = true
        freshTask.recoveryEpoch = manager.currentTransportRecoveryEpoch
        freshTask.invalidParametersBackoff.businessConnected()
        freshTask.invalidParametersBackoff.registerFailure(now: ProcessInfo.processInfo.systemUptime)
        manager.reconnectTasks[key] = freshTask
        func advertise(_ target: CBPeripheral = replacementPeripheral, config: String = "g2", name: String = "left") {
            manager.resumeDeferredReconnectFromFreshAdvertisement(peripheral: target, advertisedName: name, belongConfig: config, sn: "SN", mac: "AABB", rssi: -50)
        }
        let beforeFresh = manager.physicalStarts.count
        advertise(config: "other"); advertise(name: "other"); advertise(CBPeripheral(UUID()))
        require(manager.scanResultTemp.isEmpty && manager.physicalStarts.count == beforeFresh, "fresh advertisement bypassed UUID/config/name")
        for variant in 0..<5 {
            var blocked = freshTask
            if variant == 0 { blocked.recoveryEpoch -= 1 }
            if variant == 1 { blocked.awaitingRecoveryActivation = true }
            if variant == 2 { blocked.pausedByBluetoothOff = true }
            if variant == 3 { blocked.deferredByAppInactivity = false }
            if variant == 4 { blocked.pairingRecoveryState = .awaitingFreshAdvertisement }
            manager.reconnectTasks[key] = blocked; advertise()
            require(manager.scanResultTemp.isEmpty, "fresh advertisement bypassed epoch/deferred/Code14 gate")
        }
        manager.reconnectTasks[key] = freshTask
        manager.scanResultTemp = [(BleDevice(belongConfig: "g2", name: "left", uuid: key, sn: "old", mac: "", rssi: 0), peripheral)]
        advertise()
        require(manager.scanResultTemp.count == 1 && manager.scanResultTemp[0].1 === replacementPeripheral, "fresh advertisement did not replace stale exact cache")
        require(manager.physicalStarts.count == beforeFresh, "fresh advertisement bypassed Code1 deadline")
        ProcessInfo.processInfo.advance(1.001)
        require(manager.physicalStarts.count == beforeFresh + 1, "fresh advertisement deadline did not dispatch once")

        // Execute the actual callback predicate and system-adoption body. Old A
        // cannot tear down/adopt over B, and fresh B retains pending semantics.
        manager.reconnectTasks[key] = freshTask
        manager.peripheralValidity.observeTransportState(rawValue: 5)
        manager.peripheralValidity.observeTransportState(rawValue: 1)
        manager.peripheralValidity.observe(replacementPeripheral)
        manager.admissions[key] = admission
        manager.peripheralConnectionSessions[90] = BlePeripheralConnectionSession(peripheral: replacementPeripheral, deviceName: "left")
        let priorWatchdogs = manager.watchdogStarts
        require(!manager.acceptsCurrentPeripheralCallback(peripheral), "old reset object accepted into modern callback")
        manager.adoptSystemAutoReconnect(peripheral, name: "left")
        require(manager.watchdogStarts == priorWatchdogs && manager.peripheralConnectionSessions[90]?.peripheral === replacementPeripheral, "old reset object adopted or disturbed B")
        manager.adoptSystemAutoReconnect(replacementPeripheral, name: "left")
        require(manager.watchdogStarts == priorWatchdogs + 1 && manager.centralManager.connectStarts == 0, "fresh B lost system pending owner semantics")
        let oldButStamped = CBPeripheral(uuid)
        manager.peripheralValidity.observe(oldButStamped)
        require(!manager.acceptsCurrentPeripheralCallback(oldButStamped), "same UUID stale object bypassed exact admission")
        manager.admissions.removeAll(); manager.peripheralConnectionSessions.removeAll()
        manager.connectedDevices = [BleConnectedDevice(peripheral: replacementPeripheral, isConnected: true)]
        require(!manager.acceptsCurrentPeripheralCallback(oldButStamped), "same UUID stale object bypassed committed owner")
        manager.connectedDevices.removeAll()
        manager.restorationCoordinator.peripherals = [replacementPeripheral]
        require(!manager.acceptsCurrentPeripheralCallback(oldButStamped), "same UUID stale object bypassed exact escrow")
        manager.restorationCoordinator.peripherals.removeAll()
        require(manager.acceptsCurrentPeripheralCallback(replacementPeripheral), "fresh ownerless system callback was lost")

        // A lifecycle/scan entry before explicit claim must inherit the escrow
        // deadline too, rather than waiting for a future Dart claim to carry it.
        var escrowDebt = BleInvalidParametersBackoff()
        escrowDebt.registerFailure(now: ProcessInfo.processInfo.systemUptime)
        manager.restorationCoordinator.debt = escrowDebt
        var debtlessOwner = freshTask
        debtlessOwner.invalidParametersBackoff.businessConnected()
        manager.reconnectTasks[key] = debtlessOwner
        let priorEscrowWake = manager.physicalStarts.count
        manager.beginReconnectAttempt(uuid: key)
        require(manager.physicalStarts.count == priorEscrowWake && manager.reconnectTasks[key]!.invalidParametersBackoff.failureCount == 1, "lifecycle entry bypassed unclaimed escrow Code1 debt")
        ProcessInfo.processInfo.advance(1.001)
        require(manager.physicalStarts.count == priorEscrowWake + 1, "escrow debt did not share single task scheduler")
        manager.restorationCoordinator.debt = nil

        // Expired escrow debt still advances the next failure, even if a
        // pre-merge snapshot is handed to UUID migration after begin returned.
        var elapsedDebt = BleInvalidParametersBackoff()
        elapsedDebt.registerFailure(now: ProcessInfo.processInfo.systemUptime - 10)
        manager.restorationCoordinator.debt = elapsedDebt
        var beforeMerge = freshTask
        beforeMerge.invalidParametersBackoff.businessConnected()
        manager.reconnectTasks[key] = beforeMerge
        manager.beginReconnectAttempt(uuid: key)
        require(manager.reconnectTasks[key]!.invalidParametersBackoff.failureCount == 1, "begin overwrote expired escrow count")
        let migratedPeripheral = CBPeripheral(UUID())
        let migrated = manager.migrateReconnectTaskIdentityIfNeeded(beforeMerge, to: migratedPeripheral)
        require(migrated.invalidParametersBackoff.failureCount == 1, "migration copied stale pre-merge debt")
        manager.restorationCoordinator.debt = nil
        manager.registerInvalidParametersFailure(peripheral: migratedPeripheral, error: NSError(domain: "CBErrorDomain", code: 1), sessionGeneration: migrated.sessionGeneration)
        require(manager.reconnectTasks[migrated.uuid]!.invalidParametersBackoff.remaining(now: ProcessInfo.processInfo.systemUptime) == 2, "next Code1 after expired-debt migration did not use 2 seconds")
        manager.reconnectTasks.removeAll()

        // SR claims must report deferred while debt owns the timer, without a
        // phantom request/admission/GATT. At deadline normal retry can continue.
        var restoredTask = freshTask
        restoredTask.invalidParametersBackoff.businessConnected()
        restoredTask.invalidParametersBackoff.registerFailure(now: ProcessInfo.processInfo.systemUptime)
        manager.reconnectTasks[key] = restoredTask
        let priorGate = manager.gateStarts
        let invalidClaim = BleStateRestorationEscrowClaim(peripheral: peripheral, state: .connected)
        let invalidOutcome = manager.activateClaimedStateRestoration(task: restoredTask, config: manager.bleConfigs[0], claim: invalidClaim)
        require(invalidOutcome.disposition == .deferred && manager.admissions.isEmpty && manager.activeRequests.isEmpty && manager.gateStarts == priorGate, "invalid SR object created owner/GATT instead of deferred ACK")
        let restoredClaim = BleStateRestorationEscrowClaim(peripheral: replacementPeripheral, state: .connected)
        replacementPeripheral.state = .connected
        let claimOutcome = manager.activateClaimedStateRestoration(task: restoredTask, config: manager.bleConfigs[0], claim: restoredClaim)
        require(claimOutcome.disposition == .deferred && manager.admissions.isEmpty && manager.activeRequests.isEmpty && manager.gateStarts == priorGate, "SR claim bypassed deadline or returned false created ACK")
        ProcessInfo.processInfo.advance(1.001)
        let connectedOutcome = manager.activateClaimedStateRestoration(task: manager.reconnectTasks[key]!, config: manager.bleConfigs[0], claim: restoredClaim)
        require(connectedOutcome.disposition == .created && manager.gateStarts == priorGate + 1, "fresh SR connected claim no longer reaches Gate after deadline")
        let isolated = BleManager()
        let leftId = UUID().uuidString
        let rightId = UUID().uuidString
        var leftTask = BleReconnectTask(belongConfig: "g2", uuid: leftId, name: "left")
        leftTask.invalidParametersBackoff.registerFailure(now: ProcessInfo.processInfo.systemUptime)
        isolated.reconnectTasks[leftId] = leftTask
        isolated.reconnectTasks[rightId] = BleReconnectTask(belongConfig: "g2", uuid: rightId, name: "right/R1")
        isolated.beginReconnectAttempt(uuid: leftId)
        isolated.beginReconnectAttempt(uuid: rightId)
        require(isolated.physicalStarts == [rightId], "one endpoint Code1 blocked an independent G2 leg/R1")
        print("PASS: actual fresh-advertisement UUID/config/name/epoch/deferred/Code14 validation, cache replacement and shared deadline; old A/fresh B callback/adoption and SR deferred claim")
        print("PASS: production physical dispatch retires exact unstarted owner before retry, rejects old-object cleanup and defers invalid objects")
        print("PASS: production schedule/begin exact Code 1 fake-clock retry, one live job, stale session/owner/epoch rejection and inactive no-object deferral")
    }
}
