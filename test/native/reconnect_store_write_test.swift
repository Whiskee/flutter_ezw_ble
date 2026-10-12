import Foundation

// Only external model inputs and the peripheral boundary are substituted. The
// entire production Store/Gate/OTA registry and activation's arm method compile
// unchanged. This harness does not create a central or emulate a radio callback.
struct BleConfig {
    let name: String
    var autoReconnect = true
}
struct StoreTestPeripheral {
    let identifier: UUID
    let name: String?
}
struct BleConnectedDevice {
    let belongConfig: BleConfig
    let peripheral: StoreTestPeripheral
}
final class BleManager {
    let reconnectStore: BleReconnectStore
    let bleConfigs = [BleConfig(name: "g2"), BleConfig(name: "r1")]
    var reconnectTasks: [String: BleReconnectTask] = [:]
    let reconnectIdentityAliases = BleReconnectIdentityAliasIndex()
    let connectionAdmissionGate = BleConnectionAdmissionGate()
    init(store: BleReconnectStore) { reconnectStore = store }
    func loggerD(msg: @autoclosure () -> String) {}
    func loggerE(msg: String) {}
}

// Calls still reach a real isolated UserDefaults suite. Counts observe the API
// boundary; UserDefaults may coalesce physical disk writes asynchronously.
final class RecordingDefaults: UserDefaults {
    var sets: [String: Int] = [:]
    var removals: [String: Int] = [:]
    override func set(_ value: Any?, forKey defaultName: String) {
        sets[defaultName, default: 0] += 1
        super.set(value, forKey: defaultName)
    }
    override func removeObject(forKey defaultName: String) {
        removals[defaultName, default: 0] += 1
        super.removeObject(forKey: defaultName)
    }
    func resetCounts() { sets.removeAll(); removals.removeAll() }
}

@main
struct ReconnectStoreWriteTests {
    static let targetsKey = "flutter_ezw_ble.reconnect.targets"
    static let securityKey = "flutter_ezw_ble.reconnect.security_recovery"
    static let a = target(uuid: "11111111-1111-1111-1111-1111111111AA", name: "G2_LEFT", suffix: "11AA11")
    static let b = target(uuid: "22222222-2222-2222-2222-2222222222BB", name: "G2_RIGHT", suffix: "22BB22")
    static var checks = 0

    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        if !condition() { fputs("FAILED: \(message)\n", stderr); exit(1) }
    }
    static func target(config: String = "g2", uuid: String, name: String, suffix: String = "") -> BleReconnectTarget {
        BleReconnectTarget(belongConfig: config, uuid: uuid, name: name, expectedMacSuffix: suffix)
    }
    static func fixture(_ body: (RecordingDefaults, BleReconnectStore) -> Void) {
        let suite = "ezw.ble.reconnect.tests.\(UUID().uuidString)"
        let defaults = RecordingDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        body(defaults, BleReconnectStore(defaults: defaults))
    }
    static func writes(_ defaults: RecordingDefaults) -> Int { defaults.sets[targetsKey, default: 0] }
    static func raw(_ defaults: RecordingDefaults) -> [[String: String]] {
        defaults.array(forKey: targetsKey) as? [[String: String]] ?? []
    }

    static func main() {
        fixture { defaults, store in
            store.upsert(target: a)
            defaults.resetCounts()
            store.upsert(target: a)
            print("identical upsert additionalTargetsSetCalls=\(writes(defaults))")
            fflush(stdout)
            check(writes(defaults) == 0, "identical complete target unnecessarily calls UserDefaults.set")
            check(raw(defaults) == [a.raw], "identical upsert changes content")
        }

        // Both permutations are valid, unambiguous production target lists.
        // Activation arms each target through the real production method. Its
        // filter+append may rotate next, but persisted precedence must stay put.
        for seeded in [[a, b], [b, a]] {
            fixture { defaults, store in
                defaults.set(seeded.map(\.raw), forKey: targetsKey)
                defaults.resetCounts()
                let manager = BleManager(store: store)
                for generation in Int64(1)...6 {
                    let batch = generation.isMultiple(of: 2) ? [b, a] : [a, b]
                    for item in batch {
                        let owner = manager.armReconnectTarget(item, source: .autoReconnect, sessionGeneration: generation)
                        check(owner?.sessionGeneration == generation, "unchanged persistence blocked new activation session")
                        check(manager.reconnectTasks[manager.reconnectKey(uuid: item.uuid)]?.sessionGeneration == generation, "new owner was not installed")
                    }
                }
                check(writes(defaults) == 0, "different activation permutations rotate unchanged targets on disk")
                check(raw(defaults) == seeded.map(\.raw), "dedupe changed established list precedence")
                check(store.target(uuid: a.uuid, name: a.name)?.raw == a.raw, "exact lookup changed")
                check(store.target(uuid: "", name: b.name)?.raw == b.raw, "name canonical lookup changed")
                let older = manager.armReconnectTarget(a, source: .autoReconnect, sessionGeneration: 2)
                check(older?.sessionGeneration == 6, "late session regressed current owner")
                let temp = target(uuid: "temp-current", name: a.name, suffix: a.expectedMacSuffix)
                let canonical = manager.armReconnectTarget(temp, source: .autoReconnect, sessionGeneration: 7)
                check(canonical?.uuid == a.uuid && canonical?.sessionGeneration == 7, "persistence dedupe skipped canonical resolution")
                check(writes(defaults) == 0, "canonical unchanged owner still rewrote targets")
                print("activation permutation sessions=7 targetsSetCalls=\(writes(defaults)) owners=\(manager.reconnectTasks.count)")
            }
        }

        let changed = [
            target(config: "r1", uuid: a.uuid, name: a.name, suffix: a.expectedMacSuffix),
            target(uuid: b.uuid, name: a.name, suffix: a.expectedMacSuffix),
            target(uuid: a.uuid, name: "G2_RENAMED", suffix: a.expectedMacSuffix),
            target(uuid: a.uuid, name: a.name, suffix: "ABCDEF"),
            target(uuid: a.uuid.lowercased(), name: a.name, suffix: a.expectedMacSuffix),
            target(config: "G2", uuid: a.uuid, name: a.name, suffix: a.expectedMacSuffix),
            target(uuid: a.uuid, name: a.name.lowercased(), suffix: a.expectedMacSuffix),
            target(uuid: a.uuid, name: a.name, suffix: a.expectedMacSuffix.lowercased())
        ]
        for item in changed {
            fixture { defaults, store in
                store.upsert(target: a)
                store.upsertSecurityRecoveryRecord(belongConfig: a.belongConfig, name: a.name, uuid: a.uuid, failureCount: 4)
                defaults.resetCounts()
                store.upsert(target: item)
                check(writes(defaults) == 1 && raw(defaults) == [item.raw], "changed field or casing was swallowed")
                let sameStableIdentity = item.belongConfig.lowercased() == a.belongConfig && item.name.lowercased() == a.name.lowercased()
                check((store.securityRecoveryRecord(belongConfig: a.belongConfig, name: a.name) != nil) == sameStableIdentity, "necessary security replacement cleanup changed")
            }
        }

        fixture { defaults, store in
            store.upsert(target: a)
            defaults.resetCounts()
            let device = BleConnectedDevice(belongConfig: BleConfig(name: a.belongConfig), peripheral: StoreTestPeripheral(identifier: UUID(uuidString: a.uuid)!, name: a.name))
            store.upsert(device: device)
            check(writes(defaults) == 0 && raw(defaults) == [a.raw], "business-connected upsert lost suffix or rewrote same target")
            store.migrate(oldUuid: a.uuid, oldName: a.name, to: target(uuid: b.uuid, name: a.name, suffix: a.expectedMacSuffix))
            check(writes(defaults) == 1 && raw(defaults).count == 1 && raw(defaults)[0]["uuid"] == b.uuid, "UUID migration was not one atomic targets write")
            store.remove(uuid: b.uuid)
            check(writes(defaults) == 2 && store.targets().isEmpty, "explicit removal was deduplicated away")
            store.upsert(target: a)
            let removed = store.removeTargets(configNames: ["g2"])
            check(removed.count == 1 && store.targets().isEmpty, "config revocation did not remove target")
            store.upsert(target: a)
            defaults.resetCounts()
            store.clearTargets()
            check(defaults.object(forKey: targetsKey) == nil && defaults.removals[targetsKey] == 1, "reset did not remove targets key immediately")
        }

        // Compare against raw defaults, never decoded compactMap results: a
        // decoded equality must not hide legacy fields, foreign keys or damage.
        var legacy = a.raw
        legacy.removeValue(forKey: "expectedMacSuffix")
        var unknown = a.raw
        unknown["obsolete"] = "old"
        let badCaches: [Any] = [
            [a.raw, ["name": "missing-required-uuid"]],
            [legacy],
            [unknown],
            [["belongConfig": "g2", "uuid": 123, "name": a.name]],
            "wrong-container"
        ]
        for cache in badCaches {
            fixture { defaults, store in
                defaults.set(cache, forKey: targetsKey)
                defaults.resetCounts()
                store.upsert(target: a)
                check(writes(defaults) == 1 && raw(defaults) == [a.raw], "bad/legacy raw cache was falsely deemed equivalent")
                store.upsert(target: a)
                check(writes(defaults) == 1, "repaired canonical cache did not become idempotent")
            }
        }
        fixture { defaults, store in
            let conflicting = target(config: "r1", uuid: a.uuid, name: "OTHER_NAME")
            defaults.set([a.raw, conflicting.raw, b.raw], forKey: targetsKey)
            defaults.resetCounts()
            store.upsert(target: b)
            check(writes(defaults) == 1, "ambiguous duplicate UUID cache skipped required storage path")
            check(store.target(uuid: a.uuid)?.raw == a.raw, "ambiguous cache lost first-match precedence")
            store.upsert(target: a)
            check(writes(defaults) == 2 && store.targets().count == 2, "upsert did not converge matching duplicate UUIDs")
            store.upsert(target: a)
            check(writes(defaults) == 2, "converged duplicates kept rewriting")
        }
        fixture { defaults, store in
            let conflicting = target(config: "r1", uuid: b.uuid, name: a.name)
            defaults.set([a.raw, conflicting.raw], forKey: targetsKey)
            defaults.resetCounts()
            store.upsert(target: a)
            check(writes(defaults) == 1 && raw(defaults) == [a.raw], "duplicate name cleanup was swallowed")
        }

        fixture { defaults, store in
            store.upsert(target: a)
            defaults.resetCounts()
            for count in 1...5 {
                store.upsertSecurityRecoveryRecord(belongConfig: "g2", name: a.name, uuid: a.uuid, failureCount: count)
                check(store.securityRecoveryRecord(belongConfig: "g2", name: a.name)?.failureCount == count, "safety count was not durably updated")
            }
            check(defaults.sets[securityKey] == 5, "targets dedupe suppressed security safety writes")
            check(store.securityRecoveryRecord(belongConfig: "g2", name: a.name)?.exhausted == true, "fifth safety failure not latched")
            store.remove(uuid: a.uuid)
            let manager = BleManager(store: store)
            let denied = manager.armReconnectTarget(a, source: .autoReconnect, sessionGeneration: 10)
            check(denied == nil && manager.reconnectTasks.isEmpty && store.targets().isEmpty, "exhaustion resurrected an owner")
            check(writes(defaults) == 1, "denied automatic arm rewrote a target")
            store.clearSecurityRecoveryRecords()
            check(defaults.object(forKey: securityKey) == nil, "explicit safety reset was lost")
        }
        print("native reconnect store: all behavior checks passed checks=\(checks)")
    }
}
